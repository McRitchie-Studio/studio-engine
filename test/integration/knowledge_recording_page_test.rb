# frozen_string_literal: true

# [integration] The document page for a meeting: its recording playing beside
# its transcript. Through the router and the engine's own admin gate, on a
# table that HAS the recording columns (added here by the migration the gem
# ships). The same page on a table without them is knowledge_preview_test.rb;
# the two schemas need a process each, because the model caches its columns.
#
# Object storage is the real Studio::S3 over an SDK client with stubbed
# responses, so the signed URLs asserted here are the ones a consumer on R2
# sends a browser.
#
# Every document, name and recording in this file is invented.
require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"
require "aws-sdk-s3"

# The booted app has NOT loaded this (the preview is lazy, which is the point);
# the test names its constants, so the test loads it.
abort "Studio::KnowledgePreview loaded at boot: the preview is meant to be lazy" if defined?(Studio::KnowledgePreview)
require "studio/knowledge_preview"

ActionDispatch::IntegrationTest.app = Rails.application
Mime::Type.register "text/vnd.turbo-stream.html", :turbo_stream unless Mime[:turbo_stream]

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :email
    t.string :name
    t.string :username
    t.string :role
    t.timestamps
  end

  create_table :error_logs, force: true do |t|
    t.string :slug
    t.text   :message
    t.text   :inspect
    t.text   :backtrace
    t.string :target_type
    t.bigint :target_id
    t.string :parent_type
    t.bigint :parent_id
    t.timestamps
  end

  create_table :studio_knowledge_docs, force: true do |t|
    t.string :title, null: false
    t.string :entity, null: false
    t.string :path, null: false, default: ""
    t.string :category
    t.string :mime_type
    t.date :document_date
    t.string :status, null: false, default: "inbox"
    t.json :access, null: false, default: {}
    t.json :tags, null: false, default: []
    t.text :summary
    t.string :source_note
    t.string :uploaded_by
    t.string :s3_key
    t.bigint :byte_size
    t.bigint :superseded_by_id
    t.timestamps
  end
end

# The columns come from the migration the gem ships, not a hand-written copy.
require_relative "../../db/migrate/20261008120000_add_recording_to_studio_knowledge_docs"
ActiveRecord::Migration.suppress_messages { AddRecordingToStudioKnowledgeDocs.new.migrate(:up) }

class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
end

class User < ApplicationRecord
  def admin? = role == "admin"
  def display_name = name.presence || email.to_s.split("@").first
end

class KnowledgeRecordingTestSessionsController < ApplicationController
  skip_before_action :require_authentication

  def create
    session[Studio.session_key] = params[:id].to_i
    head :ok
  end
end

Studio.draw_knowledge_routes = true
Rails.application.reload_routes!
Rails.application.routes.append do
  post "knowledge_recording_test_sign_in/:id", to: "knowledge_recording_test_sessions#create"
end
Rails.application.reload_routes!


class KnowledgeRecordingPageTest < ActionDispatch::IntegrationTest
  Doc = Studio::KnowledgeDoc
  Preview = Studio::KnowledgePreview
  ENDPOINT = "https://acct123.r2.cloudflarestorage.com"
  SETTINGS = %i[s3_bucket_prefix s3_key_prefix s3_region s3_endpoint
                s3_access_key_id s3_secret_access_key s3_public_url].freeze

  TRANSCRIPT = <<~TEXT
    Weekly widget sync

    0:02 - Sam Sample (Example Co)
      Good morning, everyone.
    1:15 - Riley <b>Example</b>
      We ship the <script>alert(1)</script> widgets on Tuesday.
    1:02:05 - Sam Sample (Example Co)
      Agreed.
  TEXT

  setup do
    Doc.reset_column_information
    Doc.delete_all
    User.delete_all
    ErrorLog.delete_all
    @admin = User.create!(email: "admin@example.test", username: "boss", role: "admin")
    @member = User.create!(email: "pat@example.test", username: "pat")

    @previous = SETTINGS.to_h { |name| [name, Studio.public_send(name)] }
    Studio.s3_bucket_prefix = "acme-docs"
    Studio.s3_key_prefix = nil
    Studio.s3_region = "auto"
    Studio.s3_endpoint = ENDPOINT
    Studio.s3_public_url = nil
    @objects = {}
    @served = []
    @s3 = Aws::S3::Client.new(region: "auto", endpoint: ENDPOINT, stub_responses: true,
                              access_key_id: "x", secret_access_key: "y")
    @s3.stub_responses(:get_object, lambda { |context|
      @served << context.params
      body = @objects[context.params[:key]]
      next "NoSuchKey" if body.nil?

      range = context.params[:range]
      { body: range ? body.byteslice(0, range[/\Abytes=0-(\d+)\z/, 1].to_i + 1) : body }
    })
    Studio::S3.instance_variable_set(:@client, @s3)
  end

  teardown do
    @previous.each { |name, value| Studio.public_send("#{name}=", value) }
    Studio::S3.reset!
  end

  def sign_in(user)
    post "/knowledge_recording_test_sign_in/#{user.id}"
    assert_response :ok
  end

  RECORDING_KEY = "knowledge/acme/20310131090500-cd34ef56-recording-standup.mp4"

  # A filed document. `bytes` is its own file (nil for none); `recording` adds
  # a stored recording of that content type. No recording bytes exist anywhere:
  # nothing here may read them.
  def doc!(name, bytes, recording: nil, **attrs)
    row = { title: name, entity: "acme", status: "filed" }
    if bytes
      row[:s3_key] = "knowledge/acme/20310131090000-ab12cd34-#{name}"
      row[:byte_size] = bytes.bytesize
      @objects[row[:s3_key]] = bytes.b
    end
    row.merge!(recording_key: RECORDING_KEY, recording_mime_type: recording, recording_byte_size: 734_003_200) if recording
    Doc.create!(row.merge(attrs))
  end

  def show(doc) = get("/admin/knowledge/#{doc.id}")
  def preview(doc, headers: {}) = get("/admin/knowledge/#{doc.id}/preview", headers: headers)

  def player_tag = response.body[/<(?:video|audio)[^>]*data-knowledge-player[^>]*>/m]

  def signed_query(tag)
    uri = URI(CGI.unescapeHTML(tag[/src="([^"]+)"/, 1]))
    [uri, URI.decode_www_form(uri.query).to_h]
  end

  test "this table has the recording columns" do
    assert Doc.recording_columns?
  end

  # --- the gate ------------------------------------------------------------------

  test "a signed-out visitor and a non-admin get no player, no cue and no signed url" do
    doc = doc!("standup.txt", TRANSCRIPT, recording: "video/mp4")

    [-> {}, -> { sign_in @member }].each do |arrive|
      arrive.call
      [-> { show(doc) }, -> { preview(doc) }].each do |request|
        request.call
        assert_response :redirect
        refute_includes response.body, "X-Amz-Signature"
        refute_includes response.body, "Good morning"
        refute_includes response.body, "recording-standup"
      end
    end
    assert_empty @s3.api_requests, "the gate runs before anything is read or signed"
  end

  # --- the show page -------------------------------------------------------------

  test "the show page holds no signed recording url and reads nothing: the player arrives in the frame" do
    doc = doc!("standup.txt", TRANSCRIPT, recording: "video/mp4")
    sign_in @admin
    show(doc)

    assert_response :success
    assert_match(%r{<turbo-frame id="knowledge-preview" loading="lazy" src="/admin/knowledge/#{doc.id}/preview">}, response.body)
    refute_includes response.body, "X-Amz-Signature"
    refute_includes response.body, "recording-standup", "not even the recording's key is in the page"
    refute_includes response.body, "<video"
    refute_includes response.body, %(id="knowledge-recording-link")
    assert_empty @s3.api_requests
    assert_nil response.headers["Cache-Control"].to_s[/no-store/], "which is why the url may not sit in this page"
  end

  test "a document that is only a recording still gets a frame, under its own heading" do
    doc = doc!("Standup call", nil, recording: "video/mp4")
    sign_in @admin
    show(doc)

    assert_includes response.body, %(<h2 class="font-semibold mb-2">Recording</h2>)
    assert_includes response.body, %(<turbo-frame id="knowledge-preview" loading="lazy")
    refute_includes response.body, %(id="knowledge-download")

    preview(doc)
    assert_response :success
    assert_match(/<video[^>]*id="knowledge-player"/, response.body)
    refute_includes response.body, "No file is attached.", "there is no file to fall back from"
    refute_includes response.body, %(id="knowledge-preview-fallback")
    assert_empty @served
  end

  # --- the player ----------------------------------------------------------------

  test "the frame plays the recording from a six-hour signed url, in a no-store response, reading none of it" do
    doc = doc!("standup.txt", TRANSCRIPT, recording: "video/mp4")
    sign_in @admin
    preview(doc)

    assert_response :success
    assert_includes response.headers["Cache-Control"], "no-store"
    tag = player_tag
    assert tag.start_with?("<video"), tag
    assert_includes tag, " controls"
    assert_includes tag, %(preload="metadata")
    assert_includes tag, " playsinline"
    refute_includes tag, "autoplay"
    uri, query = signed_query(tag)
    assert_equal "https", uri.scheme
    assert_includes uri.host, "acct123.r2.cloudflarestorage.com"
    assert uri.path.end_with?("/#{RECORDING_KEY}"), uri.path
    assert_equal "21600", query["X-Amz-Expires"], "six hours: every seek is a new request on this url"
    assert query["X-Amz-Signature"].present?
    refute query.key?("response-content-type"), "a recording is served as the type it was stored under"
    assert_equal ["bytes=0-#{Preview::TEXT_HEAD_BYTES}"], @served.map { |read| read[:range] },
                 "the transcript's head is the only read; the recording is the browser's to stream"
    assert_equal [RECORDING_KEY], @s3.api_requests.map { |r| r[:params][:key] } - @served.map { |read| read[:key] },
                 "the recording is signed and never fetched"
  end

  test "an audio recording gets an audio player" do
    doc = doc!("standup.txt", TRANSCRIPT, recording: "audio/mpeg")
    sign_in @admin
    preview(doc)

    assert player_tag.start_with?("<audio"), player_tag
    assert_includes player_tag, " controls"
    refute_includes response.body, "<video"
  end

  # --- the transcript beside it ----------------------------------------------------

  test "with a recording each cue's time is a button and the wrapper names the controller once" do
    doc = doc!("standup.txt", TRANSCRIPT, recording: "video/mp4")
    sign_in @admin
    preview(doc)

    assert_includes response.body, %(<div class="knowledge-transcript knowledge-transcript-with-player" id="knowledge-transcript" data-studio-controller="knowledge-transcript">)
    assert_equal 1, response.body.scan(%(data-studio-controller=")).size
    assert_equal %w[2 75 3725], response.body.scan(/<li class="knowledge-cue" data-seconds="(\d+)">/).flatten
    assert_equal %w[0:02 1:15 1:02:05],
                 response.body.scan(%r{<button type="button" class="knowledge-cue-time">([^<]+)</button>}).flatten
    assert_includes response.body, %(data-knowledge-cues)
    refute_includes response.body, "data-studio-action", "one listener on the list serves every cue"
    refute_match(/\son[a-z]+=/, response.body[/<div id="knowledge-preview-body".*/m], "no inline handler anywhere")
    refute_includes response.body, "<script"

    wrapper = response.body.index(%(id="knowledge-transcript"))
    assert_operator response.body.index("data-knowledge-player"), :>, wrapper, "the player is inside the controller's element"
    assert_operator response.body.index("data-knowledge-cues"), :>, wrapper
  end

  test "beside a player a cue's speaker and text are still escaped" do
    doc = doc!("standup.txt", TRANSCRIPT, recording: "video/mp4", title: %(Call "<img src=x onerror=alert(1)>"))
    sign_in @admin
    preview(doc, headers: { "Turbo-Frame" => "knowledge-preview" })

    assert_includes response.body, %(<span class="knowledge-cue-speaker">Riley &lt;b&gt;Example&lt;/b&gt;</span>)
    assert_includes response.body, "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute_includes response.body, "<script>alert(1)</script>"
    refute_includes response.body, "<img src=x", "the title reaches the player's label escaped"
    assert_includes player_tag, %(aria-label="Call &quot;&lt;img src=x onerror=alert(1)&gt;&quot;")
  end

  test "a recording beside a document that is not a transcript plays above it, with no controller" do
    doc = doc!("agenda.md", "# Agenda\n\nWidgets, then gears.\n", recording: "video/mp4")
    sign_in @admin
    preview(doc)

    assert_includes response.body, %(<div class="knowledge-recording" id="knowledge-recording">)
    assert player_tag
    assert_includes response.body, %(data-preview-kind="text")
    assert_includes response.body, %(<pre class="knowledge-preview-text" id="knowledge-preview-text"># Agenda)
    assert_operator response.body.index(%(id="knowledge-recording")), :<, response.body.index(%(id="knowledge-preview-body"))
    refute_includes response.body, %(data-studio-controller=")
  end

  test "a recording beside a file with no preview still plays, and the file keeps its fallback" do
    doc = doc!("memo.docx", "PK-not-read", recording: "audio/mp4")
    sign_in @admin
    show(doc)
    assert_includes response.body, "<turbo-frame", "the recording earns the frame the file alone would not"

    preview(doc)
    assert player_tag.start_with?("<audio")
    assert_includes response.body, "There is no inline preview for .docx files."
    assert_empty @served
  end

  # --- when the url cannot be made ---------------------------------------------------

  test "a recording that cannot be signed leaves the transcript readable and is logged" do
    doc = doc!("standup.txt", TRANSCRIPT, recording: "video/mp4")
    sign_in @admin
    original = Studio::S3.method(:signed_url)
    Studio::S3.define_singleton_method(:signed_url) { |**| raise Studio::S3::Error, "signing is down" }
    begin
      preview(doc)
    ensure
      Studio::S3.define_singleton_method(:signed_url, original)
    end

    assert_response :success
    assert_includes response.body, %(id="knowledge-player-unavailable")
    refute_includes response.body, "<video"
    refute_includes response.body, "signing is down", "the operator's sentence carries no internals"
    assert_equal %w[0:02 1:15 1:02:05], response.body.scan(%r{<span class="knowledge-cue-time">([^<]+)</span>}).flatten,
                 "with nothing to seek, the times are text again"
    refute_includes response.body, %(data-studio-controller=")
    assert_equal 1, ErrorLog.count
  end

  test "a signed url that is not http never reaches a src" do
    doc = doc!("standup.txt", TRANSCRIPT, recording: "video/mp4")
    sign_in @admin
    original = Studio::S3.method(:signed_url)
    Studio::S3.define_singleton_method(:signed_url) { |**| "javascript:alert(document.domain)" }
    begin
      preview(doc)
    ensure
      Studio::S3.define_singleton_method(:signed_url, original)
    end

    assert_response :success
    refute_includes response.body, "javascript:"
    refute_match(/<(video|audio)/, response.body)
    assert_includes response.body, %(id="knowledge-player-unavailable")
  end

  # --- the external link ---------------------------------------------------------------

  test "with no recording stored, the page links the external recording in a new tab" do
    doc = doc!("standup.txt", TRANSCRIPT, recording_source_url: "https://notes.example.com/share/abc?t=1&u=2")
    sign_in @admin
    show(doc)

    link = response.body[%r{<a [^>]*id="knowledge-recording-open"[^>]*>}]
    assert_includes link, %(href="https://notes.example.com/share/abc?t=1&amp;u=2")
    assert_includes link, %(target="_blank")
    assert_includes link, %(rel="noopener noreferrer")
    assert_includes response.body, %(<h2 class="font-semibold mb-2">Preview</h2>)
    assert_includes response.body, "<turbo-frame", "the transcript still previews"

    preview(doc)
    refute_match(/<(video|audio)/, response.body)
    assert_equal 3, response.body.scan(%(<span class="knowledge-cue-time">)).size
  end

  test "a document with only an external link shows the link and no frame" do
    doc = doc!("Standup call", nil, recording_source_url: "https://notes.example.com/share/abc")
    sign_in @admin
    show(doc)

    assert_includes response.body, %(<h2 class="font-semibold mb-2">Recording</h2>)
    assert_includes response.body, %(id="knowledge-recording-open")
    refute_includes response.body, "<turbo-frame"
    refute_includes response.body, %(id="knowledge-preview-fallback")
  end

  test "a stored recording is played, not linked" do
    doc = doc!("standup.txt", TRANSCRIPT, recording: "video/mp4", recording_source_url: "https://notes.example.com/share/abc")
    sign_in @admin
    show(doc)
    refute_includes response.body, %(id="knowledge-recording-link")
  end

  test "a link that is not http(s) never reaches an href" do
    doc = doc!("standup.txt", TRANSCRIPT)
    # Written past the model's validation, as a row from before it, or one
    # edited by hand, would be.
    ["javascript:alert(1)", "data:text/html,<script>alert(1)</script>", "//notes.example.com/x",
     " JaVaScRiPt:alert(1)", "vbscript:x", "file:///etc/passwd"].each do |hostile|
      doc.update_column(:recording_source_url, hostile)
      sign_in @admin
      show(doc)

      assert_response :success
      refute_includes response.body, %(id="knowledge-recording-link"), hostile
      refute_match(/href="\s*(javascript|data|vbscript|file):/i, response.body, hostile)
      refute_includes response.body, "notes.example.com"
    end
  end

  test "a document with no recording and no link renders as it did before the columns" do
    doc = doc!("standup.txt", TRANSCRIPT)
    sign_in @admin
    show(doc)

    assert_includes response.body, %(<h2 class="font-semibold mb-2">Preview</h2>)
    refute_includes response.body, "knowledge-recording"
    preview(doc)
    refute_match(/<(video|audio)/, response.body)
    refute_includes response.body, %(data-studio-controller=")
  end
end
