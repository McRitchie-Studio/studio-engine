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

Mime::Type.register "text/vnd.turbo-stream.html", :turbo_stream unless Mime[:turbo_stream]

# The host's base controller, in the shape the strictest adopters have it:
# Studio::ErrorHandling (which gates EVERY controller behind
# require_authentication, as mcritchie-industries and cyvasse do), the preview
# bot concern, and a layout that renders the engine's real head partial.
class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
  include Studio::LinkPreviewBots

  helper E2eLabController::AssetDelivery
  layout "link_preview_lab"
end

# A host User with every private field the page must NOT show: a full name, a
# first name, an email and a wallet (turf-monster's truncated_solana shape).
class User < ApplicationRecord
  include Studio::UserProfile

  has_one_attached :avatar

  def admin? = role == "admin"
  def truncated_solana = solana_address && "#{solana_address[0, 4]}...#{solana_address[-4..]}"
  def public_profile_visible? = !hidden
end

# [unit + integration] The public user page, /u/:username.
#
#   1. the lookup and link helpers (unit)
#   2. the page renders avatar + username and no private field
#   3. an unknown username is a friendly 404 that says nothing about why
#   4. preview bots get the avatar as og:image; no avatar gets the site default
#   5. the route is opt-in
class PublicUserPageTest < ActionDispatch::IntegrationTest
  ActionDispatch::IntegrationTest.app = Rails.application

  IMESSAGE_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_1) AppleWebKit/601.2.4 (KHTML, like Gecko) " \
                "Version/9.0.1 Safari/601.2.4 facebookexternalhit/1.1 Facebot Twitterbot/1.0"

  PNG = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
  STATIC_PNG = Rails.public_path.join("og.png")

  WALLET = "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU"

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
        t.string  :email, null: false
        t.string  :name
        t.string  :first_name
        t.string  :username
        t.string  :solana_address
        t.string  :role
        t.boolean :hidden, default: false, null: false
        t.timestamps
      end
    end

    as_migration = File.join(Gem.loaded_specs.fetch("activestorage").full_gem_path,
                             "db/migrate/20170806125915_create_active_storage_tables.rb")
    require as_migration
    ActiveRecord::Migration.suppress_messages { CreateActiveStorageTables.new.migrate(:up) }

    require_relative "../../db/migrate/20260930120000_create_studio_site_identities"
    ActiveRecord::Migration.suppress_messages { CreateStudioSiteIdentities.new.migrate(:up) }
    Studio::SiteIdentity.reset_column_information
    User.reset_column_information
    @schema_ready = true
  end

  def setup
    self.class.ensure_schema!
    @queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @draw = Studio.draw_public_user_routes
    Studio.draw_public_user_routes = true
    Rails.application.reload_routes!

    Studio::SiteIdentity.delete_all
    Studio::SiteIdentity.bust_cache!
    User.delete_all
    FileUtils.mkdir_p(STATIC_PNG.dirname)
    File.binwrite(STATIC_PNG, PNG)
    Studio::SiteIdentity.reset_static_image!

    @alex = User.create!(email: "alex.secret@example.test", name: "Alex McPrivate", first_name: "Alexander",
                         username: "Alex-Otter", solana_address: WALLET)
  end

  def teardown
    ActiveJob::Base.queue_adapter = @queue_adapter
    Studio.draw_public_user_routes = @draw
    Rails.application.reload_routes!
    Studio::SiteIdentity.bust_cache!
    FileUtils.rm_f(STATIC_PNG)
    Studio::SiteIdentity.reset_static_image!
  end

  # --- helpers ---------------------------------------------------------------

  def meta(property, body = response.body)
    tag = body[/<meta (?:property|name)="#{Regexp.escape(property)}" content="([^"]*)">/, 1]
    tag && CGI.unescapeHTML(tag)
  end

  def attach_avatar(user)
    user.avatar.attach(io: StringIO.new(PNG), filename: "me.png", content_type: "image/png")
    user.reload
  end

  def view
    controller = ApplicationController.new
    controller.request = ActionDispatch::TestRequest.create
    controller.view_context
  end

  def assert_no_private_fields(body)
    refute_includes body, "alex.secret", "the email must never appear"
    refute_includes body, "McPrivate", "the full name must never appear"
    refute_includes body, "Alexander", "the first name must never appear"
    refute_includes body, WALLET[0, 4], "no wallet, not even truncated"
  end

  # --- 1. lookup and link helpers (unit) -------------------------------------

  test "the lookup is case-insensitive and prefers the exact spelling" do
    assert_equal @alex, Studio::PublicUser.find("alex-otter")
    assert_equal @alex, Studio::PublicUser.find("ALEX-OTTER")
    assert_equal @alex, Studio::PublicUser.find(" Alex-Otter ")

    twin = User.create!(email: "twin@example.test", username: "alex-otter")
    assert_equal twin, Studio::PublicUser.find("alex-otter"), "an exact match beats a case-folded one"
    assert_equal @alex, Studio::PublicUser.find("Alex-Otter")
  end

  test "the lookup never reads the email and honours a host's hidden accounts" do
    assert_nil Studio::PublicUser.find("alex.secret@example.test")
    assert_nil Studio::PublicUser.find("alex.secret")
    assert_nil Studio::PublicUser.find("")
    assert_nil Studio::PublicUser.find(nil)

    @alex.update!(hidden: true)
    assert_nil Studio::PublicUser.find("Alex-Otter"), "public_profile_visible? false is a plain miss"
  end

  test "an app whose users have no username column serves no pages" do
    no_username = Class.new { def self.column_names = %w[id email slug] }

    refute Studio::PublicUser.supported?(no_username)
    assert_nil Studio::PublicUser.find("anyone", user_class: no_username)
  end

  test "studio_user_profile_path links a user by username, and answers nil without one" do
    assert_equal "/u/Alex-Otter", view.studio_user_profile_path(@alex)
    assert_equal "/u/Alex-Otter", view.studio_user_profile_path("Alex-Otter")
    assert_equal "http://test.host/u/Alex-Otter", view.studio_user_profile_url(@alex)
    assert_equal "/u/first.last", view.studio_user_profile_path("first.last"), "a dot is part of the name"

    nameless = User.create!(email: "nameless@example.test", name: "No Handle")
    assert_nil view.studio_user_profile_path(nameless)
  end

  test "link_to_user_profile links when there is a page and renders plain text when not" do
    html = view.link_to_user_profile(@alex, class: "font-semibold")
    assert_match %r{\A<a [^>]*href="/u/Alex-Otter">Alex-Otter</a>\z}, html, "the text defaults to display_name"
    assert_includes html, 'class="font-semibold"'
    assert_includes html, 'data-public-user-link=""'

    assert_match %r{href="/u/Alex-Otter">@Alex-Otter</a>}, view.link_to_user_profile(@alex, "@Alex-Otter")
    assert_match %r{href="/u/Alex-Otter"><b>A</b></a>}, view.link_to_user_profile(@alex) { "<b>A</b>".html_safe }

    nameless = User.create!(email: "nameless@example.test", name: "No Handle")
    assert_equal '<span class="x">No Handle</span>', view.link_to_user_profile(nameless, class: "x")
  end

  test "the helpers answer nil when the app has not drawn the route" do
    Studio.draw_public_user_routes = false
    Rails.application.reload_routes!

    assert_nil view.studio_user_profile_path(@alex)
    assert_equal "<span>Alex-Otter</span>", view.link_to_user_profile(@alex)
  end

  test "the page's preview uses the avatar when set and the site default when not" do
    page = view
    page.link_preview(image: @alex.avatar, title: "Alex-Otter")
    assert_equal :static, page.studio_link_preview[:image_source], "no avatar is a blank rung"

    attach_avatar(@alex)
    page = view
    page.link_preview(image: @alex.avatar, title: "Alex-Otter")
    preview = page.studio_link_preview
    assert_equal :page, preview[:image_source]
    assert_match %r{\Ahttp://test\.host/rails/active_storage/blobs/proxy/}, preview[:image]
  end

  # --- 2. the page -----------------------------------------------------------

  test "the page shows the avatar and the username to a signed-out visitor, and nothing private" do
    get "/u/alex-otter"

    assert_response :success, "public: the host's require_authentication is skipped"
    assert_match %r{<h1[^>]*data-public-user-username>Alex-Otter</h1>}, response.body
    assert_match(/w-28 h-28[^"]*rounded-full/, response.body, "the initials circle stands in for a missing avatar")
    assert_equal "Alex-Otter", response.body[%r{<title>([^<]*)</title>}, 1]
    assert_no_private_fields(response.body)
  end

  test "an attached avatar is drawn with the username as its alt text" do
    attach_avatar(@alex)

    get "/u/Alex-Otter"

    assert_response :success
    assert_match %r{<img[^>]+alt="Alex-Otter"}, response.body
    assert_no_private_fields(response.body)
  end

  # --- 3. the friendly 404 ---------------------------------------------------

  test "an unknown username gets a friendly page with a 404 status" do
    get "/u/nobody-here"

    assert_response :not_found
    assert_match(/data-public-user-not-found/, response.body)
    assert_match(/nobody-here/, response.body)
    assert_match(/href="\/"/, response.body)
  end

  test "an email, a hidden account and an unknown name all get the same 404" do
    @alex.update!(hidden: true)
    bodies = ["/u/alex.secret@example.test", "/u/Alex-Otter", "/u/nobody"].map do |path|
      get path
      assert_response :not_found
      card = response.body[%r{<div[^>]*data-public-user-not-found>.*?</div>\s*</div>}m]
      assert card, "the friendly card renders"
      card.gsub(/alex\.secret@example\.test|Alex-Otter|nobody/, "NAME")
    end

    assert_equal 1, bodies.uniq.size, "a miss must not say why it missed"
  end

  # --- 4. preview bots -------------------------------------------------------

  test "a preview bot gets the slim page carrying the avatar as og:image" do
    attach_avatar(@alex)

    get "/u/alex-otter", headers: { "User-Agent" => IMESSAGE_UA }

    assert_response :success
    assert_equal "slim", response.headers["X-Studio-Link-Preview"]
    image = meta("og:image")
    assert_match %r{\Ahttp://www\.example\.com/rails/active_storage/blobs/proxy/}, image,
                 "the avatar through the PERMANENT proxy URL, never a signed expiring one"
    refute_match(/X-Amz-|expires/i, image)
    assert_equal image, meta("twitter:image")
    assert_equal "Alex-Otter", meta("og:title")
    assert_no_private_fields(response.body)

    get image.delete_prefix("http://www.example.com")
    assert_response :success
    assert_equal PNG.b, response.body.b, "the URL an unfurler caches serves the avatar"
  end

  test "a preview bot for a user with no avatar gets the site default image" do
    get "/u/Alex-Otter", headers: { "User-Agent" => IMESSAGE_UA }
    assert_equal "slim", response.headers["X-Studio-Link-Preview"]
    assert_equal "http://www.example.com/og.png", meta("og:image"), "the static last rung"

    Studio::SiteIdentity.current.tap do |identity|
      identity.image.attach(io: StringIO.new(PNG), filename: "site.png", content_type: "image/png")
      identity.save!
    end
    Studio::SiteIdentity.bust_cache!

    get "/u/Alex-Otter", headers: { "User-Agent" => IMESSAGE_UA }
    site_image = meta("og:image")
    assert_match %r{/rails/active_storage/blobs/proxy/}, site_image, "the operator's site image"
    refute_includes site_image, "me.png"
  end

  # --- 5. opt-in -------------------------------------------------------------

  test "the route is opt-in: off by default, drawn only when the app sets the flag" do
    Studio.draw_public_user_routes = false
    routes = ActionDispatch::Routing::RouteSet.new
    routes.draw { Studio.routes(self) }
    refute routes.named_routes.key?(:studio_public_user), "an app that owns /u keeps it"

    Studio.draw_public_user_routes = true
    routes = ActionDispatch::Routing::RouteSet.new
    routes.draw { Studio.routes(self) }
    assert routes.named_routes.key?(:studio_public_user)
  end

  test "the flag defaults to off" do
    assert_equal false, @draw, "setup read the flag before this suite turned it on"
  end
end
