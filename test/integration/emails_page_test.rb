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
    Studio::EmailCatalog.reset!
    @stubs = []
  end

  def teardown
    @stubs.reverse_each { |mod, name, original| mod.define_singleton_method(name, original) }
    Studio::EmailCatalog.reset!
  end

  def stub_module(mod, name, &replacement)
    @stubs << [mod, name, mod.method(name)]
    mod.define_singleton_method(name, &replacement)
  end

  # --- 1. routes drawn into every host --------------------------------------

  # REGRESSION GUARD, and the reason the page is opt-in at all.
  #
  # turf-monster's routes.rb already contains, inside `namespace :admin`:
  #   get "emails", to: "emails#index", as: :emails      -> admin_emails_path
  #   get "emails/:key", to: "emails#show", as: :email   -> admin_email_path
  #
  # Drawing the engine's page unconditionally raised
  # `ArgumentError: Invalid route name, already in use: 'admin_emails'` WHILE
  # turf-monster's own routes were loading, which took down every route in the
  # app — admin_dashboard_path, admin_scoring_path, all of it. Consumer CI runs
  # each consumer's `main`, so a host cannot opt OUT of something that breaks it
  # before its config is read. Default-off is the only shape that works until
  # turf-monster's page is retired.
  test "the /admin/emails page is OFF by default" do
    # Read the SHIPPED default, not the live value — test/dummy/config/routes.rb
    # opts in the way a consuming app does, so the runtime value is true here.
    source = File.read(File.expand_path("../../lib/studio.rb", __dir__))
    default = source[/mattr_accessor :draw_admin_emails_routes,\s*default: (\w+)/, 1]

    refute_nil default, "expected a draw_admin_emails_routes accessor with an explicit default"
    assert_equal "false", default,
      "default-on collides with turf-monster's own admin_emails route and kills its entire route set"
  end

  test "a host opts in the way the dummy app does" do
    assert Studio.draw_admin_emails_routes,
      "test/dummy/config/routes.rb must opt in before Studio.routes, or this suite tests nothing"
  end

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

  # The legacy page is DEPRECATED but still SERVED for one release — deliberately
  # not a redirect and not deleted. consumer-ci.yml runs each consumer's
  # DEFAULT-BRANCH suite against this engine, and mcritchie-studio
  # (test/integration/studio_email_image_test.rb) and turf-monster
  # (test/integration/email_banner_test.rb) both GET this page and PATCH through
  # admin_email_image_path on `main` today. Retiring it here would redden their
  # lanes from the moment the PR opens, and no change inside the engine PR could
  # fix it — the consumer PRs would have to reach accepted -> release -> main in
  # BOTH apps first. So the retirement is staged across releases.
  test "the legacy email-images page is still SERVED (staged retirement, not a redirect)" do
    assert_equal "/admin/email_images", routes.admin_email_images_path
    assert_equal "/admin/email_images/magic_link", routes.admin_email_image_path("magic_link")

    route = Rails.application.routes.routes.find { |r| r.name == "admin_email_images" }
    refute_nil route, "the admin_email_images helper must keep resolving"
    assert_equal "studio/email_images", route.defaults[:controller],
      "it must still DISPATCH — a consumer suite on main asserts this page renders"

    patch_route = Rails.application.routes.routes.find { |r| r.name == "admin_email_image" }
    refute_nil patch_route, "admin_email_image_path is called by consumer tests on main"
    assert_equal "update", patch_route.defaults[:action]
  end

  # REGRESSION GUARD. The deprecated page links forward to /admin/emails — but
  # that page is OPT-IN, so on an app that has not drawn it the helper does not
  # exist and a bare call raises NameError, 500ing the very page the deprecation
  # window exists to keep working. Consumer CI caught this on mcritchie-studio:
  # "undefined local variable or method `admin_emails_path' for an instance of
  # Studio::EmailImagesController".
  test "the legacy page's forward link is guarded on the successor route existing" do
    controller_source = File.read(
      File.expand_path("../../app/controllers/studio/email_images_controller.rb", __dir__)
    )
    view_source = File.read(
      File.expand_path("../../app/views/studio/email_images/index.html.erb", __dir__)
    )

    assert_includes controller_source, "named_routes.key?(:admin_emails)",
      "successor_path must ask the router, not assume the opt-in route was drawn"
    assert_includes view_source, "<% if successor_path %>",
      "the forward-link banner must render only when there is a successor to link to"
  end

  test "successor_path returns nil when the opt-in page was never drawn" do
    ensure_application_controller!
    controller = Studio::EmailImagesController.new

    # Stand in a router with no admin_emails route — an app that did not opt in.
    # Hand-rolled singleton stub with ensure-restore; Minitest 6 dropped
    # minitest/mock, so there is no .stub here.
    app = Rails.application
    original = app.method(:routes)
    app.define_singleton_method(:routes) { ActionDispatch::Routing::RouteSet.new }

    assert_nil controller.send(:successor_path),
      "a page that 500s is worse than a page with no forward link"
  ensure
    app&.define_singleton_method(:routes, original) if original
  end

  # Even on its way out, the old page must not keep telling the operator the
  # WRONG thing — reading only the S3 override is the bug this work exists to
  # fix, and it lives in both views until the old one is deleted.
  test "the legacy page reports the live image, not just the override" do
    source = File.read(File.expand_path("../../app/views/studio/email_images/index.html.erb", __dir__))

    assert_includes source, "Studio::EmailCatalog.preview_url(variant)"
    refute_includes source, "Studio::EmailCatalog.url(variant)",
      "the legacy page's original bug was reading ONLY the override, so it claimed " \
      "'No image yet' about an email that was visibly sending a repo-asset banner"
  end

  # --- 2. the inherited defaults really ship in the gem ----------------------

  test "every standard email's default asset is a file that ships in the gem" do
    Studio::EmailCatalog::STANDARD.each do |attrs|
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

  # --- the banner's absolute URL, assembled for real ------------------------
  #
  # REGRESSION GUARD, end to end with ActionMailer booted. mailer_asset_host used
  # to take default_url_options[:host] and prefix "https://", dropping the port
  # and forcing TLS — so a worktree stack on {host: "localhost", port: 3001} got
  # https://localhost/... and the banner in every preview came back
  # ERR_CONNECTION_REFUSED. The engine suite was green throughout; opening the
  # page is what showed it.
  def with_default_url_options(options)
    previous = ActionMailer::Base.default_url_options
    ActionMailer::Base.default_url_options = options
    yield
  ensure
    ActionMailer::Base.default_url_options = previous
  end

  test "a local stack's port and scheme survive into the banner URL" do
    with_default_url_options(host: "localhost", port: 3001) do
      assert_equal "http://localhost:3001", Studio::EmailImage.mailer_asset_host
    end
  end

  test "a production host with no port resolves to https with no port" do
    with_default_url_options(host: "mcritchie.studio") do
      assert_equal "https://mcritchie.studio", Studio::EmailImage.mailer_asset_host
    end
  end

  test "the resolved banner URL is fetchable from the stack it was built on" do
    stub_module(Studio::EmailImage, :record) { |_key| nil }

    with_default_url_options(host: "localhost", port: 3001) do
      url = Studio::EmailImage.resolved_url("magic_link")

      assert url.start_with?("http://localhost:3001/"),
        "a banner URL that drops the port points at :443 and never loads (got #{url.inspect})"
      assert_includes url, "emails/magic-link"
    end
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
    view.assign(entries: Studio::EmailCatalog.entries, uploads_available: uploads_available)
    view.render(template: "studio/emails/index")
  end

  test "the view is a bare content wrapper (no host layout of its own)" do
    html = render_index
    refute_includes html, "<html", "a bare content wrapper must not emit its own <html> shell"
    refute_includes html, "<body", "a bare content wrapper must not emit its own <body> shell"
  end

  # REGRESSION GUARD. An ERB comment ends at its FIRST "%>", so a doc comment
  # containing an ERB example silently closes early and dumps the remainder of
  # itself onto the page as visible text. That shipped once, in the scoped
  # host's usage example, and showed up as raw `<%= render ... %>` under the
  # table. No amount of Nokogiri structure assertions caught it — only looking
  # at the page did. This looks.
  test "no raw ERB leaks into the rendered page" do
    [render_index, render_index(uploads_available: false)].each do |html|
      refute_match(/<%|%>/, html,
        "an ERB delimiter reached the browser — a doc comment almost certainly " \
        "closed early on a '%>' inside its own example")
    end
  end

  test "no raw ERB leaks out of the scoped host partial" do
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    html = view.render(partial: "studio/modals/scoped_host", locals: { store: "emailModals" })

    refute_match(/<%|%>/, html)
  end

  # REGRESSION GUARD. The outer `template x-if` unmounts one tick AFTER the
  # stack empties, so a registration written `current().id` throws
  # "Cannot read properties of null" on EVERY modal close.
  test "modal registrations guard current() with optional chaining" do
    html = render_index

    assert_includes html, "$store.emailModals.current()?.id === 'crop-photo'"
    refute_match(/current\(\)\.id/, html,
      "a bare current().id throws on close — use current()?.id")
  end

  test "the table shows the NAME and the LIVE IMAGE of every registered email" do
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |key| "/assets/#{key}.png" }

    doc = Nokogiri::HTML(render_index)
    rows = doc.css("tbody tr")

    assert_equal Studio::EmailCatalog.entries.size, rows.size, "one row per registered email"
    Studio::EmailCatalog.entries.each do |entry|
      row = rows.find { |r| r.text.include?(entry.label) }
      refute_nil row, "expected a row named #{entry.label}"
      refute_empty row.css("img"), "#{entry.key}'s row must show its live image, not just its name"
    end
  end

  test "a row says its image is the INHERITED default when the app uploaded nothing" do
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |_key| "/assets/emails/magic-link.png" }

    html = render_index
    assert_includes html, "Inherited default"
    refute_includes html, "No image yet",
      "the pre-registry copy claimed an email had no image while it was sending one"
  end

  test "a row says the image is APP-OWNED once this app uploaded its own" do
    row = Object.new
    row.define_singleton_method(:url) { "https://turf-monster-dev.s3.amazonaws.com/email_banners/magic_link-ab12.png" }
    stub_module(Studio::EmailCatalog, :record) { |key| key.to_s == "magic_link" ? row : nil }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |_key| "/assets/emails/default.png" }

    html = render_index
    assert_includes html, "#{Studio.app_name}&#39;s own"
    assert_includes html, "Inherited default",
      "the OTHER email is still inheriting — both states must be distinguishable on one page"
    assert_includes html, "Revert", "an app-owned image can be dropped back to the default"
  end

  test "an email with no image at all is labelled distinctly from an inherited one" do
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |_key| nil }

    html = render_index
    assert_includes html, "No image"
    refute_includes html, "Inherited default"
  end

  test "upload runs through the shared crop modal, never a bare file input" do
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |_key| "/assets/emails/magic-link.png" }

    html = render_index
    assert_includes html, "imageUploadHost(", "each row hosts the shared cropper uploader"
    assert_includes html, "crop-photo-confirmed", "the cropped blob feeds the row's hidden form"

    doc = Nokogiri::HTML(html)
    visible_file_inputs = doc.css('input[type="file"]').reject { |i| i["class"].to_s.include?("hidden") }
    assert_empty visible_file_inputs,
      "the old page's bare file_field_tag must be gone — uploads go through the crop modal"
  end

  test "the crop and saving modals mount on a PAGE-SCOPED store" do
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |_key| "/assets/emails/magic-link.png" }

    html = render_index
    # mcritchie-industries and moms-app render no shared modal host at all, so
    # the page has to bring its own rather than reach for $store.modals.
    assert_includes html, "emailModals",
      "the page must mount its own modal host so it works in an app with none"
    assert_includes html, "$store.emailModals.current()?.id === 'crop-photo'"
    assert_includes html, "$store.emailModals.current()?.id === 'saving'"
  end

  test "an app with no object storage renders read-only and explains why" do
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |_key| "/assets/emails/magic-link.png" }

    html = render_index(uploads_available: false)

    # It still SHOWS what is shipping — that is the honest part.
    assert_includes html, "Inherited default"
    assert_includes html, "s3_bucket_prefix", "say what is missing, in the operator's terms"
    refute_includes html, "imageUploadHost(",
      "an Edit button that cannot possibly work must not be offered"
  end

  # --- the page-scoped host -------------------------------------------------

  # REGRESSION GUARD. The first cut of this page rendered "studio/modals/host"
  # with a store: local. It worked in the dummy app and rendered NOTHING in
  # mcritchie-studio, because this is a NON-ISOLATED engine and both
  # mcritchie-studio and turf-monster ship their own
  # app/views/studio/modals/_host.html.erb — older forks that know no store:
  # local. The app fork shadows the engine's partial, so the page-scoped store
  # was never registered and the Upload button opened nothing.
  #
  # studio/modals/scoped_host is unforked in every app. If some page ever points
  # this page back at the forkable path, this test goes red.
  test "the page mounts its host from the UNFORKED scoped_host path" do
    source = File.read(File.expand_path("../../app/views/studio/emails/index.html.erb", __dir__))

    assert_includes source, %(render "studio/modals/scoped_host")
    refute_includes source, %(render "studio/modals/host"),
      "mcritchie-studio and turf-monster fork studio/modals/_host — their copy would " \
      "shadow the engine's and swallow the store: local, leaving the store unregistered"
  end

  test "the scoped host registers ONLY the store it was asked for" do
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    html = view.render(partial: "studio/modals/scoped_host", locals: { store: "emailModals" })

    assert_includes html, "var STORE_NAME    = 'emailModals';"
    assert_includes html, "$store.emailModals.current()"
    refute_includes html, "Alpine.store('modals'",
      "a page-scoped host must never touch the app's shared store"
  end

  test "the scoped host survives a Turbo visit" do
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    html = view.render(partial: "studio/modals/scoped_host", locals: { store: "emailModals" })

    # alpine:init fires once per full document load. A host living in a PAGE BODY
    # was absent for it, so a Turbo Drive visit needs the direct-call branch or
    # the store is undefined and every x-data on the page throws.
    assert_includes html, "if (window.Alpine) { registerScopedStore(); }"
    assert_includes html, "else { document.addEventListener('alpine:init', registerScopedStore); }"
  end

  test "the scoped host ships the API the crop and saving modals call" do
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    html = view.render(partial: "studio/modals/scoped_host", locals: { store: "emailModals" })

    # studio/modals/_crop_photo calls current()/close(); submitFormWithProgress
    # calls open(id, props, { replace: true }) to turn crop-photo into saving;
    # the backdrop binds cardClasses(). A missing one of these is a dead button.
    %w[current: close: open: cardClasses: closeAllDismissible:].each do |method|
      assert_includes html, method, "the scoped store must implement #{method.chomp(':')}()"
    end
  end

  test "the shared modal host was left exactly as every app already renders it" do
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    html = view.render(partial: "studio/modals/host")

    assert_includes html, "$store.modals.current()",
      "the shared host is rendered by shipped app layouts — it must not move"
  end
end
