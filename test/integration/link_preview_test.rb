# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"
require "rack/test"
require "base64"

# Studio::ErrorHandling#require_authentication answers turbo_stream among its
# formats; every real host has turbo-rails, the dummy registers the type.
Mime::Type.register "text/vnd.turbo-stream.html", :turbo_stream unless Mime[:turbo_stream]

# The engine's controllers inherit the HOST's ApplicationController, so define
# the minimal base a host provides (the same stand-in geo_gate_test uses).
class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
end

class User < ApplicationRecord
  def admin? = role == "admin"
end

# [integration] The link-preview primitive, end to end, through the stack a
# consuming app has: the engine's real head partial in a host layout, the
# /admin/link_preview page an operator uses, Active Storage for the default
# image, and Studio::LinkPreviewBots serving preview fetchers the slim page.
#
#   1. every page emits default tags with no app code (once the table exists)
#   2. the operator sets the default image, title and description
#   3. the admin page draws a live card of that default
#   4. a page overrides through `link_preview`, and a missing image falls back
#   5. a preview bot gets a slim, head-only page under 1 MiB; a person does not
class LinkPreviewTest < ActionDispatch::IntegrationTest
  ActionDispatch::IntegrationTest.app = Rails.application

  IMESSAGE_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_1) AppleWebKit/601.2.4 (KHTML, like Gecko) " \
                "Version/9.0.1 Safari/601.2.4 facebookexternalhit/1.1 Facebot Twitterbot/1.0"
  SAFARI_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 " \
              "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

  # A real 1x1 PNG, so Active Storage stores genuine image bytes.
  PNG = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")

  STATIC_PNG = Rails.public_path.join("og.png")

  def self.ensure_schema!
    return if @schema_ready

    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
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

      create_table :users, force: true do |t|
        t.string :email, null: false
        t.string :name
        t.string :role
        t.timestamps
      end
    end

    # Active Storage's own tables, from the gem's own install migration — what
    # every consumer already has.
    as_migration = File.join(Gem.loaded_specs.fetch("activestorage").full_gem_path,
                             "db/migrate/20170806125915_create_active_storage_tables.rb")
    require as_migration
    ActiveRecord::Migration.suppress_messages { CreateActiveStorageTables.new.migrate(:up) }
    @schema_ready = true
  end

  # The engine's REAL migration — the one a host installs — rather than a
  # hand-written table that could drift from it.
  def install_link_preview_table!
    return if ActiveRecord::Base.connection.table_exists?(:studio_link_preview_settings)

    require_relative "../../db/migrate/20260930120000_create_studio_link_preview_settings"
    ActiveRecord::Migration.suppress_messages { CreateStudioLinkPreviewSettings.new.migrate(:up) }
    Studio::LinkPreviewSetting.reset_column_information
  end

  def drop_link_preview_table!
    return unless ActiveRecord::Base.connection.table_exists?(:studio_link_preview_settings)

    ActiveRecord::Base.connection.drop_table(:studio_link_preview_settings)
    ActiveRecord::Base.connection.schema_cache.clear!
  end

  def setup
    self.class.ensure_schema!
    @queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @config = [Studio.link_preview_tags, Studio.link_preview_fallback_image,
               Studio.link_preview_default_title, Studio.link_preview_default_description]
    install_link_preview_table!
    Studio::LinkPreviewSetting.delete_all
    Studio::LinkPreviewSetting.bust_cache!
    User.delete_all
    FileUtils.mkdir_p(STATIC_PNG.dirname)
    File.binwrite(STATIC_PNG, PNG)
    Studio::LinkPreviewHelper.reset_static_files!
  end

  def teardown
    ActiveJob::Base.queue_adapter = @queue_adapter
    Studio.link_preview_tags, Studio.link_preview_fallback_image,
      Studio.link_preview_default_title, Studio.link_preview_default_description = @config
    Studio::LinkPreviewSetting.bust_cache!
    FileUtils.rm_f(STATIC_PNG)
    Studio::LinkPreviewHelper.reset_static_files!
  end

  # --- helpers ---------------------------------------------------------------

  def sign_in_admin
    admin = User.create!(email: "admin@example.test", name: "Admin", role: "admin")
    post "/lab/sign_in", params: { user_id: admin.id }
  end

  def meta(property, body = response.body)
    tag = body[/<meta (?:property|name)="#{Regexp.escape(property)}" content="([^"]*)">/, 1]
    tag && CGI.unescapeHTML(tag)
  end

  def upload(bytes = PNG, type: "image/png", name: "card.png")
    Rack::Test::UploadedFile.new(StringIO.new(bytes), type, true, original_filename: name)
  end

  def upload_default_image
    sign_in_admin
    patch "/admin/link_preview", params: { link_preview_setting: { image: upload } }
    assert_response :see_other
  end

  # --- 1. default tags, no app code ---------------------------------------

  test "every page emits default tags from the head once the table exists" do
    get "/lab/link_preview"

    assert_response :success
    assert_equal "Studio", meta("og:site_name")
    assert_equal "Studio", meta("og:title"), "a page that names nothing unfurls as the app"
    assert_equal "http://www.example.com/og.png", meta("og:image"), "the static public/og.png is the last image rung"
    assert_equal "http://www.example.com/lab/link_preview", meta("og:url")
    assert_equal "summary_large_image", meta("twitter:card")
    assert_nil meta("og:description"), "no description rung means no tag, never an empty one"
  end

  # DUPLICATE-SAFE BY DEFAULT: an app that owns its own og tags and has not
  # installed the table (turf-monster, cyvasse today) gets no second set.
  test "an app without the table emits no engine tags under auto" do
    drop_link_preview_table!

    get "/lab/link_preview"

    assert_response :success
    assert_nil meta("og:title")
    assert_nil meta("og:image")
  ensure
    install_link_preview_table!
  end

  test "the tags switch is honoured both ways" do
    Studio.link_preview_tags = false
    get "/lab/link_preview"
    assert_nil meta("og:title"), "false keeps the head silent even with the table"

    drop_link_preview_table!
    Studio.link_preview_tags = true
    get "/lab/link_preview"
    assert_equal "Studio", meta("og:title"), "true emits even before the table"
    assert_equal "http://www.example.com/og.png", meta("og:image")
  ensure
    install_link_preview_table!
  end

  test "no static file and no upload means no og image tag rather than a broken one" do
    FileUtils.rm_f(STATIC_PNG)
    Studio::LinkPreviewHelper.reset_static_files!

    get "/lab/link_preview"

    assert_nil meta("og:image")
    assert_equal "summary", meta("twitter:card")
  end

  # --- 2. the operator sets the default -------------------------------------

  test "admin uploads a default image and every page's tags carry it" do
    upload_default_image
    follow_redirect!
    assert_match(/Default link-preview image updated/, flash[:notice].to_s)

    setting = Studio::LinkPreviewSetting.current
    assert setting.image_attached?

    get "/lab/link_preview"
    image = meta("og:image")
    assert_match %r{\Ahttp://www\.example\.com/rails/active_storage/blobs/proxy/}, image,
                 "a private service is served through the PERMANENT proxy URL, never a signed expiring one"
    assert_equal image, meta("twitter:image")

    # The URL an unfurler caches really serves the picture.
    get image.delete_prefix("http://www.example.com")
    assert_response :success
    assert_equal PNG.b, response.body.b
  end

  test "admin sets the default title and description through the page's own fields" do
    sign_in_admin
    get "/admin/link_preview"
    assert_match(/name="link_preview_setting\[title\]"/, response.body)
    assert_match(/name="link_preview_setting\[description\]"/, response.body)
    refute_match(/name="studio_link_preview_setting\[/, response.body, "the namespaced key is read by nobody")

    patch "/admin/link_preview", params: { link_preview_setting: { title: "Pick'em & win", description: "Skill contests." } }
    assert_response :see_other

    get "/lab/link_preview/override"
    assert_equal "Pick'em & win", meta("og:title"), "the operator's title under a page that names none"
    assert_equal "Skill contests.", meta("og:description")
  end

  test "a text save leaves the uploaded image alone, and removing it falls back to static" do
    upload_default_image
    patch "/admin/link_preview", params: { link_preview_setting: { title: "New words" } }
    assert Studio::LinkPreviewSetting.current.image_attached?, "a words-only post must not drop the picture"

    delete "/admin/link_preview/image"
    assert_response :see_other
    refute Studio::LinkPreviewSetting.current.image_attached?

    get "/lab/link_preview"
    assert_equal "http://www.example.com/og.png", meta("og:image")
  end

  test "a non-image upload is refused and nothing is attached" do
    sign_in_admin
    patch "/admin/link_preview", params: { link_preview_setting: { image: upload("%PDF-1.4", type: "application/pdf", name: "x.pdf") } }

    assert_response :see_other
    follow_redirect!
    assert_match(/PNG, JPG, WebP or GIF/, flash[:alert].to_s)
    refute Studio::LinkPreviewSetting.current.image_attached?
  end

  test "the page is admin only" do
    get "/admin/link_preview"
    assert_redirected_to "/login"

    member = User.create!(email: "member@example.test", name: "Member", role: "member")
    post "/lab/sign_in", params: { user_id: member.id }
    get "/admin/link_preview"
    assert_redirected_to "/"

    patch "/admin/link_preview", params: { link_preview_setting: { title: "hijack" } }
    assert_redirected_to "/"
    assert_nil Studio::LinkPreviewSetting.current.title
  end

  # --- 3. the live card -----------------------------------------------------

  test "the admin page draws the card an unfurl draws" do
    upload_default_image
    patch "/admin/link_preview", params: { link_preview_setting: { title: "Turf Monster", description: "Pick'em." } }

    get "/admin/link_preview"

    assert_response :success
    card = response.body[/<div class="lp-card" data-link-preview-card>.*?<\/div>\s*<\/div>\s*<\/div>/m]
    assert card, "the preview card renders"
    assert_match %r{<img src="http://www\.example\.com/rails/active_storage/blobs/proxy/}, card
    assert_match %r{data-link-preview-card-domain>www\.example\.com<}, card
    assert_match %r{data-link-preview-card-title>Turf Monster<}, card
    assert_match %r{data-link-preview-card-description>Pick&#39;em\.<}, card
    assert_match(/data-link-preview-input="title"/, response.body, "the title field repaints the card live")
    assert_match(/imageUploadHost\(/, response.body, "the upload goes through the shared crop modal")
  end

  test "the admin page explains itself before the table is installed" do
    drop_link_preview_table!
    sign_in_admin

    get "/admin/link_preview"

    assert_response :success
    assert_match(/data-link-preview-not-installed/, response.body)
    assert_match(/studio_engine:install:migrations/, response.body)
  ensure
    install_link_preview_table!
  end

  # --- 4. the page override -------------------------------------------------

  test "a page overrides image, title and description through link_preview" do
    upload_default_image

    get "/lab/link_preview/override", params: { title: "World Cup Contest", description: "Six picks.",
                                                image: "/banners/contest.png" }

    assert_equal "World Cup Contest", meta("og:title")
    assert_equal "Six picks.", meta("og:description")
    assert_equal "http://www.example.com/banners/contest.png", meta("og:image"), "the page's image wins, made absolute"
  end

  test "an override with no image falls back to the default image" do
    upload_default_image

    get "/lab/link_preview/override", params: { title: "alex" }

    assert_equal "alex", meta("og:title"), "the page still names itself"
    assert_match %r{/rails/active_storage/blobs/proxy/}, meta("og:image"), "but the picture is the operator's default"
  end

  test "an override image that is an attachment with nothing attached is a blank rung" do
    view = ActionView::Base.empty
    view.extend(Studio::LinkPreviewHelper)
    unattached = Studio::LinkPreviewSetting.new.image

    view.link_preview(image: unattached)

    assert_equal :static, view.studio_link_preview[:image_source]
  end

  test "link_preview refuses a key it does not know" do
    view = ActionView::Base.empty
    view.extend(Studio::LinkPreviewHelper)

    assert_raises(ArgumentError) { view.link_preview(imagee: "/x.png") }
  end

  # The public-service half of the URL rule (turf-monster's amazon_public): the
  # service's OWN url, which is permanent, instead of the proxy.
  test "a public service answers its own url and a mirror asks its primary" do
    public_service = Struct.new(:public?).new(true)
    blob = Struct.new(:service, :url).new(public_service, "https://cdn.example.test/og/abc.png")
    assert_equal({ url: "https://cdn.example.test/og/abc.png" }, Studio::LinkPreviewSetting.image_location(blob))

    mirror = Struct.new(:primary, :public?).new(public_service, false)
    assert Studio::LinkPreviewSetting.public_service?(mirror)
  end

  # --- 5. preview bots ------------------------------------------------------

  test "a preview bot gets a slim head-only page under 1 MiB" do
    get "/lab/link_preview/heavy", headers: { "User-Agent" => SAFARI_UA }
    full = response.body
    assert_operator full.bytesize, :>, Studio::LinkPreview::MAX_DOCUMENT_BYTES,
                    "the fixture must really be over the iMessage limit, or this proves nothing"

    get "/lab/link_preview/heavy", headers: { "User-Agent" => IMESSAGE_UA }

    assert_response :success
    assert_operator response.body.bytesize, :<, Studio::LinkPreview::MAX_DOCUMENT_BYTES
    assert_operator response.body.bytesize, :<, 10_000
    refute_match(/<script/i, response.body)
    refute_match(/<template/i, response.body)
    assert_equal "Heavy contest", meta("og:title"), "the page's override survives into the slim page"
    assert_equal "A page past the iMessage limit", meta("og:description")
    assert_equal "http://www.example.com/og.png", meta("og:image")
    assert_equal "slim", response.headers["X-Studio-Link-Preview"]
    assert_includes response.headers["Vary"].to_s, "User-Agent", "a shared cache must never hand the slim page to a person"
  end

  test "a person gets the full page" do
    get "/lab/link_preview/heavy", headers: { "User-Agent" => SAFARI_UA }

    assert_response :success
    assert_match(/window\.__heavy/, response.body)
    assert_nil response.headers["X-Studio-Link-Preview"]
  end

  test "a blank user agent gets the full page" do
    get "/lab/link_preview", headers: { "User-Agent" => "" }

    assert_match(/data-lab-page="plain"/, response.body)
  end
end
