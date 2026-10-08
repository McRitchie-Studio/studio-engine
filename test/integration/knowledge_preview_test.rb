# frozen_string_literal: true

# [integration] The document preview, through the router and the engine's own
# admin gate: GET /admin/knowledge/:id/preview for every kind, the show page's
# lazy frame, and each fallback. Object storage is the real Studio::S3 over an
# SDK client with stubbed responses, pointed at an S3-compatible endpoint, so
# the ranged reads and the signed URLs asserted here are the ones a consumer
# on R2 sends.
#
# Every document in this file is invented.
require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"
require "aws-sdk-s3"
require_relative "../support/xlsx_builder"

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

class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
end

class User < ApplicationRecord
  def admin? = role == "admin"
  def display_name = name.presence || email.to_s.split("@").first
end

class KnowledgeTestSessionsController < ApplicationController
  skip_before_action :require_authentication

  def create
    session[Studio.session_key] = params[:id].to_i
    head :ok
  end
end

Studio.draw_knowledge_routes = true
Rails.application.reload_routes!
Rails.application.routes.append do
  post "knowledge_test_sign_in/:id", to: "knowledge_test_sessions#create"
end
Rails.application.reload_routes!

class KnowledgePreviewRequestTest < ActionDispatch::IntegrationTest
  Doc = Studio::KnowledgeDoc
  Preview = Studio::KnowledgePreview
  ENDPOINT = "https://acct123.r2.cloudflarestorage.com"
  SETTINGS = %i[s3_bucket_prefix s3_key_prefix s3_region s3_endpoint
                s3_access_key_id s3_secret_access_key s3_public_url].freeze

  setup do
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
    # Requests the bucket actually ANSWERED. The SDK's own api_requests log
    # also lists every presign, which sends nothing.
    @served = []
    @s3 = Aws::S3::Client.new(region: "auto", endpoint: ENDPOINT, stub_responses: true,
                              access_key_id: "x", secret_access_key: "y")
    @s3.stub_responses(:get_object, lambda { |context|
      @served << context.params
      body = @objects[context.params[:key]]
      next "NoSuchKey" if body.nil?

      if (range = context.params[:range])
        last = range[/\Abytes=0-(\d+)\z/, 1].to_i
        next "InvalidRange" if body.empty?

        body = body.byteslice(0, last + 1)
      end
      { body: body }
    })
    Studio::S3.instance_variable_set(:@client, @s3)
  end

  teardown do
    @previous.each { |name, value| Studio.public_send("#{name}=", value) }
    Studio::S3.reset!
  end

  def sign_in(user)
    post "/knowledge_test_sign_in/#{user.id}"
    assert_response :ok
  end

  # A filed document whose object holds `bytes`.
  def doc!(name, bytes, **attrs)
    key = "knowledge/acme/20310131090000-ab12cd34-#{name}"
    @objects[key] = bytes.b
    Doc.create!({ title: name, entity: "acme", status: "filed", s3_key: key, byte_size: bytes.bytesize }.merge(attrs))
  end

  def reads
    @served
  end

  def preview(doc, headers: {})
    get "/admin/knowledge/#{doc.id}/preview", headers: headers
  end

  def ledger
    XlsxBuilder.workbook(
      { "Income" => %(<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>) +
                    %(<row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2" s="1"><f>SUM(B5:B9)</f><v>-48250.5</v></c></row>) +
                    %(<row r="3"><c r="A3" t="s"><v>3</v></c><c r="B3" s="2"><v>0.125</v></c></row>) +
                    %(<row r="4"><c r="A4" t="s"><v>4</v></c><c r="B4" s="3"><v>47880</v></c></row>),
        "Notes & <caveats>" => XlsxBuilder.rows([["<script>alert(1)</script>"]]) },
      shared: ["Line", "Amount", "Net widgets", "Margin", "As of"],
      formats: ['"$"#,##0.00;("$"#,##0.00)', "0.0%", "mmm d, yyyy"]
    )
  end

  # --- the gate ------------------------------------------------------------------

  test "a signed-out visitor and a non-admin get no preview and cause no read" do
    doc = doc!("ledger.xlsx", ledger)

    preview(doc)
    assert_response :redirect
    refute_includes response.body, "Net widgets"

    sign_in @member
    preview(doc)
    assert_redirected_to "/"
    refute_includes response.body, "Net widgets"
    assert_empty reads, "the gate runs before anything touches the bucket"
  end

  # --- the show page -------------------------------------------------------------

  test "the show page lazy-loads the preview and reads nothing itself" do
    doc = doc!("ledger.xlsx", ledger)
    sign_in @admin
    get "/admin/knowledge/#{doc.id}"

    assert_response :success
    assert_includes response.body, %(id="knowledge-preview-section")
    assert_match(%r{<turbo-frame id="knowledge-preview" loading="lazy" src="/admin/knowledge/#{doc.id}/preview">}, response.body)
    assert_includes response.body, %(id="knowledge-preview-open"), "without Turbo the link is the way in"
    refute_includes response.body, "Net widgets", "the document's contents are not in the page itself"
    assert_empty @s3.api_requests, "the show page must not wait on the bucket, nor sign anything"
  end

  test "the show page says at once when a kind has no preview" do
    doc = doc!("memo.docx", "PK-not-read")
    sign_in @admin
    get "/admin/knowledge/#{doc.id}"

    assert_response :success
    refute_includes response.body, "<turbo-frame"
    assert_includes response.body, %(id="knowledge-preview-fallback")
    assert_includes response.body, %(id="knowledge-preview-download")
  end

  test "a metadata-only document shows no preview section" do
    doc = Doc.create!(title: "A note", entity: "acme")
    sign_in @admin
    get "/admin/knowledge/#{doc.id}"

    assert_response :success
    refute_includes response.body, "knowledge-preview-section"
  end

  # --- spreadsheets --------------------------------------------------------------

  test "a workbook renders as tables, one tab per sheet, with formatted values" do
    doc = doc!("ledger.xlsx", ledger)
    sign_in @admin
    preview(doc)

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_includes response.body, %(<turbo-frame id="knowledge-preview">)
    assert_includes response.body, %(data-preview-kind="table")

    assert_equal 2, response.body.scan(%r{<label class="knowledge-sheet-tab"}).size
    assert_includes response.body, %(for="knowledge-sheet-radio-0">Income</label>)
    assert_includes response.body, %(id="knowledge-sheet-panel-1")
    assert_equal 1, response.body.scan(/class="knowledge-sheet-radio"[^>]*checked/m).size, "the first sheet opens"

    assert_includes response.body, "<td>Net widgets</td>"
    assert_includes response.body, %(<td class="knowledge-cell-number">($48,250.50)</td>), "a formula's cached value, as currency"
    assert_includes response.body, %(<td class="knowledge-cell-number">12.5%</td>)
    assert_includes response.body, %(<td class="knowledge-cell-number">Feb 1, 2031</td>)
    refute_includes response.body, "SUM(", "a formula's text is never shown"
    assert_includes response.body, %(<th scope="col">B</th>)
    refute_includes response.body, "data-preview-truncated"
  end

  test "sheet names and cells are escaped, never rendered" do
    doc = doc!("ledger.xlsx", ledger)
    sign_in @admin
    preview(doc)

    assert_includes response.body, "Notes &amp; &lt;caveats&gt;"
    assert_includes response.body, "<td>&lt;script&gt;alert(1)&lt;/script&gt;</td>"
    refute_includes response.body, "<script>alert(1)</script>"
    refute_includes response.body, "<caveats>"
  end

  test "a long sheet shows the first rows and says so" do
    values = (1..(Preview::MAX_ROWS + 40)).map { |n| ["entry #{n}", n] }
    doc = doc!("long.xlsx", XlsxBuilder.workbook({ "Entries" => XlsxBuilder.rows(values) }))
    sign_in @admin
    preview(doc)

    assert_response :success
    notice = response.body[%r{<p class="knowledge-preview-note" data-preview-truncated>.*?</p>}m]
    assert_match(/Showing the first\s+500 rows;/, notice)
    assert_includes notice, %(href="/admin/knowledge/#{doc.id}/download")
    assert_includes notice, "for the full file"
    assert_includes response.body, "<td>entry #{Preview::MAX_ROWS}</td>"
    refute_includes response.body, "<td>entry #{Preview::MAX_ROWS + 1}</td>"
  end

  test "a workbook over the byte cap falls back to the download link without a read" do
    doc = doc!("huge.xlsx", "x", byte_size: Preview::SPREADSHEET_MAX_BYTES + 1)
    sign_in @admin
    preview(doc)

    assert_response :success
    assert_includes response.body, %(data-preview-kind="fallback")
    assert_match(/too large to preview: it is 20 MB and previews of this kind stop at 20 MB/, response.body)
    assert_includes response.body, %(id="knowledge-preview-download")
    assert_includes response.body, %(href="/admin/knowledge/#{doc.id}/download")
    assert_empty reads
    assert_equal 0, ErrorLog.count
  end

  test "a workbook that will not parse falls back with a reason and no error" do
    doc = doc!("broken.xlsx", "PK\x03\x04 this was never a workbook")
    sign_in @admin
    preview(doc)

    assert_response :success
    assert_includes response.body, "This file could not be previewed: it is not a zip archive."
    assert_includes response.body, %(id="knowledge-preview-download")
    assert_equal 0, ErrorLog.count, "a bad file is not an incident"
  end

  test "a storage failure still renders the page and is logged" do
    doc = doc!("ledger.xlsx", ledger)
    @objects.clear
    sign_in @admin
    preview(doc)

    assert_response :success
    assert_includes response.body, "The preview could not be built."
    assert_includes response.body, %(id="knowledge-preview-download")
    assert_equal 1, ErrorLog.count
    refute_includes response.body, "NoSuchKey", "the page carries no storage internals"
  end

  # --- csv -----------------------------------------------------------------------

  test "a csv renders as a table" do
    doc = doc!("export.csv", %(Part,Qty,Note\n"Bracket, steel",12,"<b>bold?</b>"\n))
    sign_in @admin
    preview(doc)

    assert_response :success
    assert_includes response.body, %(data-preview-kind="table")
    assert_includes response.body, "<td>Bracket, steel</td>"
    assert_includes response.body, %(<td class="knowledge-cell-number">12</td>)
    assert_includes response.body, "<td>&lt;b&gt;bold?&lt;/b&gt;</td>"
    refute_includes response.body, "knowledge-sheet-tab\"", "one table needs no tabs"
    assert_equal "bytes=0-#{Preview::DELIMITED_HEAD_BYTES}", reads.first[:range]
  end

  test "a long csv shows the first rows and says so" do
    doc = doc!("export.csv", (1..(Preview::MAX_ROWS + 10)).map { |n| "row #{n},#{n}" }.join("\n"))
    sign_in @admin
    preview(doc)

    assert_match(/Showing the first\s+500 rows;/, response.body)
    refute_includes response.body, "<td>row #{Preview::MAX_ROWS + 1}</td>"
  end

  test "an empty csv falls back instead of failing on the ranged read" do
    doc = doc!("empty.csv", "")
    sign_in @admin
    preview(doc)

    assert_response :success
    assert_includes response.body, "This file could not be previewed: it is empty."
    assert_equal 0, ErrorLog.count
  end

  # --- text ----------------------------------------------------------------------

  test "text and markdown display as escaped preformatted text" do
    doc = doc!("call-notes.md", "# Heading\n\nSpeaker A: <script>alert(1)</script> & more\n")
    sign_in @admin
    preview(doc)

    assert_response :success
    assert_includes response.body, %(<pre class="knowledge-preview-text" id="knowledge-preview-text"># Heading)
    assert_includes response.body, "&lt;script&gt;alert(1)&lt;/script&gt; &amp; more"
    refute_includes response.body, "<script>alert(1)</script>"
    refute_includes response.body, "<h1>", "markdown is shown, not rendered"
    refute_includes response.body, "data-preview-truncated"
  end

  test "a long text file shows its start and says so" do
    doc = doc!("transcript.txt", "Speaker B: a line of talk\n" * 20_000)
    sign_in @admin
    preview(doc)

    assert_includes response.body, "Showing the start of this file;"
    assert_equal "bytes=0-#{Preview::TEXT_HEAD_BYTES}", reads.first[:range]
  end

  # --- pdf and image -------------------------------------------------------------

  test "a pdf is framed from a signed inline url and its bytes are never read here" do
    doc = doc!("letter.pdf", "%PDF-1.7 invented", mime_type: "text/html")
    sign_in @admin
    preview(doc)

    assert_response :success
    src = CGI.unescapeHTML(response.body[/<iframe[^>]*id="knowledge-preview-pdf"[^>]*src="([^"]+)"/m, 1].to_s)
    uri = URI(src)
    query = URI.decode_www_form(uri.query).to_h
    assert_includes uri.host, "acct123.r2.cloudflarestorage.com"
    assert_equal "inline", query["response-content-disposition"]
    assert_equal "application/pdf", query["response-content-type"], "served as a PDF whatever was stored"
    assert query["X-Amz-Signature"].present?, "the url is signed"
    assert_equal "900", query["X-Amz-Expires"]
    assert_includes query["X-Amz-SignedHeaders"], "host"
    assert_empty reads
  end

  test "an image is shown from a signed inline url" do
    doc = doc!("scan.png", "\x89PNG invented".b)
    sign_in @admin
    preview(doc)

    src = CGI.unescapeHTML(response.body[/<img[^>]*id="knowledge-preview-image"[^>]*src="([^"]+)"/m, 1].to_s)
    query = URI.decode_www_form(URI(src).query).to_h
    assert_equal "inline", query["response-content-disposition"]
    assert_equal "image/png", query["response-content-type"]
    assert query["X-Amz-Signature"].present?
    assert_empty reads
  end

  test "the download link is unchanged: signed, with no inline override" do
    doc = doc!("letter.pdf", "%PDF-1.7 invented")
    sign_in @admin
    get "/admin/knowledge/#{doc.id}/download"

    assert_response :redirect
    query = URI.decode_www_form(URI(response.location).query).to_h
    assert query["X-Amz-Signature"].present?
    refute query.key?("response-content-disposition")
    refute query.key?("response-content-type")
  end

  # --- everything else -------------------------------------------------------------

  test "a kind with no preview falls back with one plain sentence" do
    doc = doc!("legacy.xls", "\xD0\xCF\x11\xE0".b)
    sign_in @admin
    preview(doc)

    assert_response :success
    assert_includes response.body, "There is no inline preview for .xls files."
    assert_includes response.body, %(id="knowledge-preview-download")
    assert_empty reads
  end

  test "inside a frame the body stands alone; opened directly it links back" do
    doc = doc!("call.txt", "hello")
    sign_in @admin

    preview(doc, headers: { "Turbo-Frame" => "knowledge-preview" })
    refute_includes response.body, %(href="/admin/knowledge/#{doc.id}">)

    preview(doc)
    assert_includes response.body, %(href="/admin/knowledge/#{doc.id}">)
  end

  test "an unknown document is not found, not a preview" do
    sign_in @admin
    assert_raises(ActiveRecord::RecordNotFound) { get "/admin/knowledge/999999/preview" }
  end
end
