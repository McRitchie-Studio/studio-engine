# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

ActionDispatch::IntegrationTest.app = Rails.application

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :email
    t.string :name
    t.string :username
    t.string :role
    t.string :session_token
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

# Signs a user in the way the engine does: the id under Studio.session_key and
# the user's session token beside it. `token:` overrides the cookie's token to
# model a session the server has since rotated.
class GalleryTestSessionsController < ApplicationController
  skip_before_action :require_authentication

  def create
    user = User.find(params[:id])
    session[Studio.session_key] = user.id
    session[:session_token] = params.key?(:token) ? params[:token] : user.session_token
    head :ok
  end
end

Rails.application.routes.append do
  post "gallery_test_sign_in/:id", to: "gallery_test_sessions#create"
end
Rails.application.reload_routes!

# [integration] The component gallery (Lookbook at /admin/style/components) in
# a host that draws Studio.routes:
#
#   1. an admin gets the gallery, the badge preview in it, its rendered states,
#      and /admin/style lists it;
#   2. a visitor, a non-admin, and an admin whose session token was rotated all
#      get 404 from the gallery, from ViewComponent's own preview pages and from
#      Lookbook's UI assets;
#   3. the gallery shows output only: no Source or Params panel, no preview
#      Ruby, no embeds;
#   4. Lookbook's public Rack::Static is gone from the middleware stack.
class ComponentGalleryTest < ActionDispatch::IntegrationTest
  GALLERY = Studio::ComponentGallery::MOUNT_PATH

  setup do
    User.delete_all
    @admin = User.create!(email: "admin@example.test", username: "boss", role: "admin", session_token: "tok-admin")
    @member = User.create!(email: "pat@example.test", username: "pat", session_token: "tok-pat")
  end

  def sign_in(user, **params)
    post "/gallery_test_sign_in/#{user.id}", params: params
    assert_response :ok
  end

  # A 404 either way a browser can get one: no route matched (the router's
  # constraint refused the request; the dummy raises rather than renders, and
  # Rails answers that exception 404), or the preview controller's own gate.
  def assert_not_found(path)
    get path
    assert_response :not_found, "#{path} answered #{response.status}"
    refute_includes response.body, "Lookbook", "#{path}'s 404 names Lookbook"
  rescue ActionController::RoutingError
    assert_equal 404, ActionDispatch::ExceptionWrapper.status_code_for_exception("ActionController::RoutingError")
  end

  # Every path a visitor might try: the gallery, a preview's page, its rendered
  # frame, ViewComponent's own preview pages, and Lookbook's assets.
  def gallery_paths
    [
      GALLERY,
      "#{GALLERY}/inspect/studio/badge/tones",
      "#{GALLERY}/preview/studio/badge/tones",
      Studio::ComponentGallery::PREVIEWS_ROUTE,
      "#{Studio::ComponentGallery::PREVIEWS_ROUTE}/studio/badge_component/tones",
      "#{Studio::ComponentGallery::ASSETS_PATH}/css/lookbook.css"
    ]
  end

  # --- 1. an admin -------------------------------------------------------------

  test "an admin opens the gallery and finds the badge preview" do
    sign_in @admin
    get GALLERY

    assert_response :success
    assert_includes response.body, "studio/badge"
  end

  test "the badge preview renders every tone through the component" do
    sign_in @admin
    get "#{GALLERY}/preview/studio/badge/tones"

    assert_response :success
    Studio::BadgeComponent::TONES.each do |tone, classes|
      assert_includes response.body, %(<span class="badge #{classes}">#{tone}</span>)
    end
    # The preview layout carries the host's stylesheet, so the badge is styled.
    assert_includes response.body, "tailwind"
  end

  test "an admin gets ViewComponent's own preview pages and Lookbook's assets" do
    sign_in @admin

    get "#{Studio::ComponentGallery::PREVIEWS_ROUTE}/studio/badge_component/default"
    assert_response :success
    assert_includes response.body, %(<span class="badge bg-surface-alt text-secondary border-subtle">neutral</span>)

    asset = Dir[File.join(Studio::ComponentGallery.lookbook_assets_root, "css/*.css")].first
    refute_nil asset, "Lookbook ships no CSS under #{Studio::ComponentGallery.lookbook_assets_root}"
    get "#{Studio::ComponentGallery::ASSETS_PATH}/css/#{File.basename(asset)}"
    assert_response :success
  end

  test "/admin/style lists the badge preview and links each state into the gallery" do
    sign_in @admin
    get "/admin/style"

    assert_response :success
    html = Nokogiri::HTML(response.body)
    nav = html.at_css("nav[aria-label='Style guide sections']")
    assert nav.at_css("a[href='#components']"), "the section nav has no Components pill"

    preview = html.at_css("#components [data-component-preview='studio/badge']")
    refute_nil preview, "the Components section does not list the badge preview"
    hrefs = preview.css("a").map { |a| a["href"] }
    %w[tones schemes default board_count].each do |state|
      assert_includes hrefs, "#{GALLERY}/inspect/studio/badge/#{state}"
    end
  end

  # --- 2. everyone else --------------------------------------------------------

  test "a visitor gets 404 from every gallery path" do
    gallery_paths.each { |path| assert_not_found(path) }
  end

  test "a signed-in non-admin gets 404 from every gallery path" do
    sign_in @member
    gallery_paths.each { |path| assert_not_found(path) }
  end

  test "an admin whose session token was rotated gets 404" do
    sign_in @admin, token: "stale"
    gallery_paths.each { |path| assert_not_found(path) }
  end

  # The control: the same session reaches the gallery once its token is live
  # again, so the 404s above are the gate and not a broken mount.
  test "control: the same admin with a live token gets through" do
    sign_in @admin, token: "stale"
    assert_not_found(GALLERY)

    sign_in @admin
    get GALLERY
    assert_response :success
  end

  # --- 3. output only ----------------------------------------------------------

  test "the inspector shows the rendered badge but no Source or Params panel" do
    sign_in @admin
    get "#{GALLERY}/inspect/studio/badge/default"

    assert_response :success
    refute_match(/>\s*Source\s*</, response.body, "the Source panel is on")
    refute_match(/>\s*Params\s*</, response.body, "the Params panel is on")
    refute_includes response.body, "Studio::BadgeComponent.new", "the preview's Ruby reached the page"
  end

  test "the gallery is configured for output only" do
    inspector = Lookbook.config.preview_inspector
    assert_equal %i[preview output], inspector.main_panels.map(&:to_sym)
    assert_equal %i[notes], inspector.drawer_panels.map(&:to_sym)
    refute Lookbook.config.preview_embeds.enabled
    assert_empty Lookbook.config.page_paths
    refute Rails.application.routes.routes.any? { |route| route.path.spec.to_s.include?("embed") },
           "an embed route is drawn"
  end

  # --- 4. the middleware -------------------------------------------------------

  test "Lookbook's public Rack::Static is not on the middleware stack" do
    refute Rails.application.middleware.any? { |middleware| middleware.klass == Rack::Static },
           "Lookbook's Rack::Static serves /lookbook-assets to everyone"
  end
end
