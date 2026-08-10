# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"

# [integration] Guard for /admin/emails — the standard transactional-email page
# every Studio app gets, and the piece of it that only shows up once a real Rails
# app is booted: the routes, the admin gate, and the rendered table.
#
# The load-bearing properties, each exercised rather than declared:
#
#   1. Studio.routes draws admin_emails_path -> studio/emails#index plus the
#      per-email PATCH/DELETE, AND keeps the legacy admin_email_images_path
#      helper resolving as a redirect (mcritchie-studio's link tree and
#      turf-monster's admin hub both link the old helper TODAY — they must not
#      404 between this gem release and each app's adoption).
#   2. The engine's default banners are real files that ship in the gem, and the
#      asset initializer enumerates them for a sprockets host.
#   3. The controller gates every action with require_admin, and gates the two
#      WRITE actions a second time on uploads_available? — an app with no bucket
#      degrades to read-only instead of 500ing.
#   4. The table renders NAME + IMAGE per row and says, in words, whether that
#      image is inherited or app-owned — the bug this work fixes was a page that
#      reported "No image yet" for an email that was visibly sending a banner.
#   5. Upload goes through the shared crop modal on a PAGE-SCOPED store, not a
#      bare file input — so the page works in a host app that renders no shared
#      modal host at all (mcritchie-industries, moms-app).
class EmailsPageTest < ActiveSupport::TestCase
  def routes
    Rails.application.routes.url_helpers
  end

  def setup
    Studio::EmailImage.reset!
    @stubs = []
  end

  def teardown
    @stubs.reverse_each { |mod, name, original| mod.define_singleton_method(name, original) }
    Studio::EmailImage.reset!
  end

  def stub_module(mod, name, &replacement)
    @stubs << [mod, name, mod.method(name)]
    mod.define_singleton_method(name, &replacement)
  end

  # --- 1. routes drawn into every host --------------------------------------

  test "Studio.routes draws /admin/emails -> studio/emails#index" do
    assert_equal "/admin/emails", routes.admin_emails_path

    route = Rails.application.routes.routes.find { |r| r.name == "admin_emails" }
    refute_nil route, "expected a named admin_emails route"
    assert_equal "studio/emails", route.defaults[:controller]
    assert_equal "index", route.defaults[:action]
  end

  test "the per-email write routes are drawn for PATCH and DELETE" do
    assert_equal "/admin/emails/magic_link", routes.admin_email_path("magic_link")

    verbs = Rails.application.routes.routes
                 .select { |r| r.path.spec.to_s.start_with?("/admin/emails/:key") }
                 .map { |r| r.verb.to_s }
    assert_includes verbs, "PATCH", "an app must be able to store its own override"
    assert_includes verbs, "DELETE", "an app must be able to revert to the inherited default"
  end

  test "the legacy admin_email_images helper survives as a redirect to /admin/emails" do
    # mcritchie-studio's link_tree_helper and turf-monster's admin hub link this
    # helper on the shipped gem. It must resolve through the adoption gap.
    assert_equal "/admin/email_images", routes.admin_email_images_path

    route = Rails.application.routes.routes.find { |r| r.name == "admin_email_images" }
    refute_nil route, "the admin_email_images helper must survive the move"

    endpoint = route.app
    endpoint = endpoint.app while endpoint.respond_to?(:app) &&
                                 !endpoint.is_a?(ActionDispatch::Routing::Redirect)
    assert endpoint.is_a?(ActionDispatch::Routing::Redirect),
      "admin_email_images must redirect to /admin/emails, not dispatch a controller"
  end

  # --- 2. the inherited defaults really ship in the gem ----------------------

  test "every standard email's default asset is a file that ships in the gem" do
    Studio::EmailImage::STANDARD.each do |attrs|
      asset = attrs[:default_asset]
      path = File.expand_path("../../app/assets/images/#{asset}", __dir__)
      assert File.file?(path),
        "#{attrs[:key]} declares #{asset}, but no such file ships in app/assets/images"
    end
  end

  test "the gemspec's app/** glob carries the default banners into the built gem" do
    # spec.files is Dir["app/**/*"], so a default asset is included by
    # construction — assert the directory it globs is where the files live.
    root = File.expand_path("../..", __dir__)
    shipped = Dir[File.join(root, "app/assets/images/emails/*")]
    refute_empty shipped, "the engine must ship at least one default email banner"
  end

  test "the asset initializer enumerates the default banners for a sprockets host" do
    paths = Studio::Engine.default_email_banner_logical_paths

    assert_includes paths, "emails/magic-link.png"
    assert_includes paths, "emails/email-change-confirmation.png"
    assert_includes Rails.application.config.assets.precompile, "emails/magic-link.png",
      "a sprockets host (mcritchie-studio, turf-monster) needs the explicit precompile entry"
  end

  # --- 3. the gates ---------------------------------------------------------

  test "EmailsController gates every action with require_admin" do
    ensure_application_controller!

    filters = Studio::EmailsController._process_action_callbacks.map(&:filter)
    assert_includes filters, :require_admin,
      "the page is admin-only in every host"
    assert_includes filters, :require_uploads,
      "the WRITE actions must be gated on this app having object storage"
  end

  test "the upload gate is scoped to the write actions only" do
    ensure_application_controller!

    callback = Studio::EmailsController._process_action_callbacks
                                       .find { |c| c.filter == :require_uploads }
    refute_nil callback

    # Rails compiles `only:` into an ActionFilter carrying the action set.
    filter = callback.instance_variable_get(:@if)
                     .find { |cond| cond.is_a?(AbstractController::Callbacks::ActionFilter) }
    refute_nil filter, "require_uploads must be scoped with only:"

    actions = filter.instance_variable_get(:@actions).to_a
    assert_equal %w[update destroy].sort, actions.sort
    refute_includes actions, "index",
      "index must stay reachable on an app with no bucket — degrading honestly is the point"
  end

  def ensure_application_controller!
    return if Object.const_defined?(:ApplicationController)

    Object.const_set(:ApplicationController, Class.new(ActionController::Base) {
      include Studio::ErrorHandling
    })
  end

  # --- 4 + 5. the rendered table --------------------------------------------

  # Render the page the way the style-guide test does: a bare content wrapper,
  # no host layout. `entries` / `uploads_available` are what the controller
  # assigns.
  def render_index(uploads_available: true)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    # The rows link admin_email_path; a bare ActionView::Base carries no route
    # helpers, so mix the app's in rather than stubbing the URLs away.
    view.singleton_class.include(Rails.application.routes.url_helpers)
    view.assign(entries: Studio::EmailImage.entries, uploads_available: uploads_available)
    view.render(template: "studio/emails/index")
  end

  test "the view is a bare content wrapper (no host layout of its own)" do
    html = render_index
    refute_includes html, "<html", "a bare content wrapper must not emit its own <html> shell"
    refute_includes html, "<body", "a bare content wrapper must not emit its own <body> shell"
  end

  test "the table shows the NAME and the LIVE IMAGE of every registered email" do
    stub_module(Studio::EmailImage, :record) { |_key| nil }
    stub_module(Studio::EmailImage, :default_asset_path) { |key| "/assets/#{key}.png" }

    doc = Nokogiri::HTML(render_index)
    rows = doc.css("tbody tr")

    assert_equal Studio::EmailImage.entries.size, rows.size, "one row per registered email"
    Studio::EmailImage.entries.each do |entry|
      row = rows.find { |r| r.text.include?(entry.label) }
      refute_nil row, "expected a row named #{entry.label}"
      refute_empty row.css("img"), "#{entry.key}'s row must show its live image, not just its name"
    end
  end

  test "a row says its image is the INHERITED default when the app uploaded nothing" do
    stub_module(Studio::EmailImage, :record) { |_key| nil }
    stub_module(Studio::EmailImage, :default_asset_path) { |_key| "/assets/emails/magic-link.png" }

    html = render_index
    assert_includes html, "Inherited default"
    refute_includes html, "No image yet",
      "the pre-registry copy claimed an email had no image while it was sending one"
  end

  test "a row says the image is APP-OWNED once this app uploaded its own" do
    row = Object.new
    row.define_singleton_method(:url) { "https://turf-monster-dev.s3.amazonaws.com/email_banners/magic_link-ab12.png" }
    stub_module(Studio::EmailImage, :record) { |key| key.to_s == "magic_link" ? row : nil }
    stub_module(Studio::EmailImage, :default_asset_path) { |_key| "/assets/emails/default.png" }

    html = render_index
    assert_includes html, "#{Studio.app_name}&#39;s own"
    assert_includes html, "Inherited default",
      "the OTHER email is still inheriting — both states must be distinguishable on one page"
    assert_includes html, "Revert", "an app-owned image can be dropped back to the default"
  end

  test "an email with no image at all is labelled distinctly from an inherited one" do
    stub_module(Studio::EmailImage, :record) { |_key| nil }
    stub_module(Studio::EmailImage, :default_asset_path) { |_key| nil }

    html = render_index
    assert_includes html, "No image"
    refute_includes html, "Inherited default"
  end

  test "upload runs through the shared crop modal, never a bare file input" do
    stub_module(Studio::EmailImage, :record) { |_key| nil }
    stub_module(Studio::EmailImage, :default_asset_path) { |_key| "/assets/emails/magic-link.png" }

    html = render_index
    assert_includes html, "imageUploadHost(", "each row hosts the shared cropper uploader"
    assert_includes html, "crop-photo-confirmed", "the cropped blob feeds the row's hidden form"

    doc = Nokogiri::HTML(html)
    visible_file_inputs = doc.css('input[type="file"]').reject { |i| i["class"].to_s.include?("hidden") }
    assert_empty visible_file_inputs,
      "the old page's bare file_field_tag must be gone — uploads go through the crop modal"
  end

  test "the crop and saving modals mount on a PAGE-SCOPED store" do
    stub_module(Studio::EmailImage, :record) { |_key| nil }
    stub_module(Studio::EmailImage, :default_asset_path) { |_key| "/assets/emails/magic-link.png" }

    html = render_index
    # mcritchie-industries and moms-app render no shared modal host at all, so
    # the page has to bring its own rather than reach for $store.modals.
    assert_includes html, "emailModals",
      "the page must mount its own modal host so it works in an app with none"
    assert_includes html, "$store.emailModals.current().id === 'crop-photo'"
    assert_includes html, "$store.emailModals.current().id === 'saving'"
  end

  test "an app with no object storage renders read-only and explains why" do
    stub_module(Studio::EmailImage, :record) { |_key| nil }
    stub_module(Studio::EmailImage, :default_asset_path) { |_key| "/assets/emails/magic-link.png" }

    html = render_index(uploads_available: false)

    # It still SHOWS what is shipping — that is the honest part.
    assert_includes html, "Inherited default"
    assert_includes html, "s3_bucket_prefix", "say what is missing, in the operator's terms"
    refute_includes html, "imageUploadHost(",
      "an Edit button that cannot possibly work must not be offered"
  end

  # --- the shared modal host stayed backwards compatible ---------------------

  test "the modal host still defaults to the shared 'modals' store" do
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    html = view.render(partial: "studio/modals/host")

    assert_includes html, "$store.modals.current()",
      "every shipped host renders this partial with no store: local — it must not move"
    assert_includes html, "var STORE_NAME = 'modals';"
  end

  test "the modal host mounts a page-scoped store when asked" do
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    html = view.render(partial: "studio/modals/host", locals: { store: "emailModals" })

    assert_includes html, "var STORE_NAME = 'emailModals';"
    assert_includes html, "$store.emailModals.current()"
    refute_includes html, "$store.modals.current()?._closing",
      "a page-scoped host must not bind the shared store's backdrop"
  end
end
