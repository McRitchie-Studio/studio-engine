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
    # Routes draw LAZILY. The flag this reads is set by test/dummy/config/routes.rb
    # AS IT DRAWS, so on a seed that happened to run this test before any
    # route-touching one, it read the pre-draw default and failed. Measured on an
    # untouched `accepted` checkout: red at --seed 3, green at 1, 2, 4, 5 and 6 — a
    # roughly 1-in-6 flake that has nothing to do with whatever branch trips it.
    # Force the draw, then assert what the message actually claims.
    Rails.application.reload_routes!

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

  # --- 1b. a layered email is not "no image" --------------------------------

  # THE ORIGINAL BUG, SECOND DOOR. The page it replaced said "No image yet"
  # about an email that was visibly sending a banner. This is the same failure
  # reached differently: a layered-native email registers no flat `default_asset`
  # (it never renders one), so a preview that reads only that field drew an empty
  # box and a "This email sends without a banner" badge for an email that was at
  # that moment sending a banner. Reported by the page, disproved by the inbox.
  test "a layered email previews its background rather than reporting no image" do
    entry = Studio::EmailCatalog.entry("newsletter_subscribed")
    assert_nil entry.default_asset, "this guard is meaningless if the entry gains a flat asset"

    path = Studio::EmailCatalog.preview_url("newsletter_subscribed")

    refute_nil path, "the manager would draw an empty box for an email that sends artwork"
    assert_includes path, "newsletter-subscribed-background"
  end

  test "a layered email's provenance is the engine's artwork, not none" do
    assert_equal :engine_default, Studio::EmailCatalog.source("newsletter_subscribed"),
      "':none' renders the 'sends without a banner' badge, which is false here"
  end

  # An email with genuinely no artwork must still say so — the fix above must not
  # turn the honest answer into a lie in the other direction.
  test "an email with no artwork at all still reports none" do
    Studio::EmailCatalog.register("bare_email", label: "Bare")

    assert_nil Studio::EmailCatalog.preview_url("bare_email")
    assert_equal :none, Studio::EmailCatalog.source("bare_email")
  ensure
    Studio::EmailCatalog.reset!
  end

  # THE THIRD DOOR onto the same bug, and the one that shipped: magic_link
  # registers BOTH — the old banner with "Your Magic Link" baked into the picture,
  # and the artwork the layered banner draws live text over. Previewing the flat
  # one put a picture on the manager that no inbox receives, and it looked right
  # precisely because baked-in words look like a real banner.
  test "an email with both kinds of artwork previews the layered one" do
    path = Studio::EmailCatalog.preview_url("magic_link")

    assert_includes path, "background",
      "a layered mailer sends the background with live text on it; preview what ships"
  end

  # The flat asset is still the right preview for a host on the engine's own
  # unlayered UserMailer — there the baked-text banner IS what arrives.
  test "an email with only flat artwork previews that" do
    Studio::EmailCatalog.register("legacy_email", label: "Legacy",
                                  default_asset: "emails/magic-link.gif")

    path = Studio::EmailCatalog.preview_url("legacy_email")

    assert_includes path, "magic-link"
    refute_includes path, "background"
  ensure
    Studio::EmailCatalog.reset!
  end

  # The <img> fallback resolves the OTHER way — it is the flat path, so the flat
  # asset wins there even though the preview prefers the background.
  test "the flat fallback still prefers the flat asset" do
    assert_includes Studio::EmailCatalog.resolved_url("magic_link").to_s, "magic-link"
    refute_includes Studio::EmailCatalog.resolved_url("magic_link").to_s, "background"
  end

  # --- 1c. an uploaded GIF stays a GIF --------------------------------------

  # Animated banners bypass the cropper — it paints onto a canvas and calls
  # toBlob(..., "image/png"), which keeps frame one and discards the animation
  # silently, leaving a perfectly good-looking still behind. So the bytes are
  # stored whole, and the key has to say what they are: a GIF written to a
  # ".png" key still PLAYS (S3 serves the Content-Type it was given) but tells
  # every CDN, proxy and human reading the bucket the wrong thing.
  test "an uploaded gif is stored under a gif key" do
    key = Studio::EmailCatalog.send(:ext_for, "image/gif")

    assert_equal ".gif", key, "a gif stored as .png misreports itself to anything reading the URL"
  end

  test "the other upload types keep their own extensions" do
    { "image/png" => ".png", "image/jpeg" => ".jpg", "image/webp" => ".webp" }.each do |type, ext|
      assert_equal ext, Studio::EmailCatalog.send(:ext_for, type), "#{type} lost its extension"
    end
  end

  # --- an upload whose email left the registry ------------------------------

  # The standard set can change. An email that leaves it takes its page with it,
  # and a host that had uploaded artwork was left holding a live ImageCache row
  # and a paid-for S3 object with no revert button — the only control that could
  # remove either lived on the page that now 404s.
  test "a key with an upload stays reachable after it leaves the registry" do
    row = Struct.new(:url, :s3_key).new("https://cdn.test/orphan.gif", "email_banners/orphan.gif")
    stub_module(Studio::EmailCatalog, :record) { |key| key.to_s == "gone_away" ? row : nil }

    refute Studio::EmailCatalog.known?("gone_away"), "this guard is meaningless if the key is registered"
    refute_nil Studio::EmailCatalog.record("gone_away"),
      "an orphan is exactly: unregistered, but this app still stores an image for it"
  end

  test "an unregistered key with NO upload is still a 404" do
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }

    assert_nil Studio::EmailCatalog.record("never_existed")
    refute Studio::EmailCatalog.known?("never_existed"),
      "keeping every unknown key reachable would turn a typo into a page"
  end

  # --- an operator-typed logo url -------------------------------------------

  test "a logo url is only accepted when it can be fetched as an image" do
    assert_equal "https://cdn.test/logo.png", Studio::Banner.safe_image_url("https://cdn.test/logo.png")
    assert_equal "/assets/emails/logo.png", Studio::Banner.safe_image_url("/assets/emails/logo.png")

    ["javascript:alert(1)", "data:text/html;base64,AAAA", "ftp://x/y.png", "  "].each do |value|
      assert_nil Studio::Banner.safe_image_url(value), "#{value.inspect} reached an img src"
    end
  end

  # --- 2. the inherited defaults really ship in the gem ----------------------

  # Whichever artwork an entry declares — the flat fallback, the layered
  # background, or both — must be a file in the gem. A layered-native entry
  # declares no default_asset at all, and that is not a missing file.
  test "every standard email's declared artwork is a file that ships in the gem" do
    Studio::EmailCatalog::STANDARD.each do |attrs|
      declared = { default_asset: attrs[:default_asset], background: attrs[:background] }.compact

      refute_empty declared, "#{attrs[:key]} declares no artwork at all"

      declared.each do |role, asset|
        path = File.expand_path("../../app/assets/images/#{asset}", __dir__)
        assert File.file?(path),
          "#{attrs[:key]} declares #{role} #{asset}, but no such file ships in app/assets/images"
      end
    end
  end

  test "the gemspec's app/** glob carries the default banners into the built gem" do
    # spec.files is Dir["app/**/*"], so a default asset is included by
    # construction — assert the directory it globs is where the files live.
    root = File.expand_path("../..", __dir__)
    shipped = Dir[File.join(root, "app/assets/images/emails/*")]
    refute_empty shipped, "the engine must ship at least one default email banner"
  end

  # Every frame each banner is supposed to carry, pinned by number.
  #
  # Pinned rather than "more than one" because "keeping every frame" IS the
  # decision — frame-dropping was measured (half the frames: 3.1 MB against
  # 3.5 MB) and rejected, so a file that quietly comes back at 60 frames has
  # lost the thing that was chosen, not merely thinned. Re-encoding on purpose
  # means editing this number, and then the diff says what it cost.
  BANNER_FRAMES = {
    "emails/magic-link.gif" => 120,
    "emails/magic-link-background.gif" => 72,
    "emails/newsletter-subscribed-background.gif" => 72
  }.freeze

  # Flat assets are 3:1 at 1800 wide; layered BACKGROUNDS are 3:1 at 1200. Both
  # shapes are legitimate, so the guard asserts each artwork against the size its
  # ROLE calls for rather than one global number.
  BANNER_SIZES = {
    "emails/magic-link.gif" => [1800, 600],
    "emails/magic-link-background.gif" => [1200, 600],
    "emails/newsletter-subscribed-background.gif" => [1200, 600]
  }.freeze

  # A GIF frame is introduced by a Graphic Control Extension: the block
  # terminator closing the previous block, then 0x21 (extension introducer),
  # 0xF9 (graphic-control label), 0x04 (block size).
  GRAPHIC_CONTROL_EXTENSION = "\x00\x21\xF9\x04".b.freeze

  # The artwork itself, asserted as a FILE. A default_asset naming a file that
  # moved, got flattened, or lost its frames renders wrong in real email while
  # every other assertion on this page still passes.
  #
  # The FRAMES are asserted, not inferred from the header. "GIF89a" is a FORMAT
  # VERSION, not proof of animation: flatten these to a single frame and the
  # magic bytes and the logical-screen size are both untouched, so every other
  # assertion here still passes while every inbox loses the motion Mr. McRitchie
  # chose over a 24 KB static frame. At 5.5 MB these files INVITE exactly that
  # optimisation, which is why the property is checked instead of a proxy for it.
  test "the standard banners are the real artwork, animated and full size" do
    # BOTH roles, because a standard entry may ship either or both: `default_asset`
    # is the flat <img> fallback, `background` is the layered artwork. Iterating
    # only default_asset (as this did) left every layered background — the thing
    # actually rendered in the inbox now — with no guard on it at all.
    assets = Studio::EmailCatalog::STANDARD.flat_map { |attrs| [attrs[:default_asset], attrs[:background]] }.compact.uniq

    refute_empty assets, "the standard entries must ship artwork"

    assets.each do |asset|
      path = File.expand_path("../../app/assets/images/#{asset}", __dir__)
      assert File.file?(path), "missing #{asset}"

      data = File.binread(path)

      assert_equal "GIF89a", data[0, 6],
        "#{asset} must stay an animated GIF — Mr. McRitchie chose animation over a 24KB static frame"

      # GIF logical-screen size, little-endian, bytes 6..9.
      width, height = data[6, 4].unpack("v2")
      expected_width, expected_height = BANNER_SIZES.fetch(asset)
      assert_equal expected_width,  width,  "#{asset} lost its width"
      assert_equal expected_height, height, "#{asset} lost its height"

      assert_equal BANNER_FRAMES.fetch(asset), data.scan(GRAPHIC_CONTROL_EXTENSION).size,
        "#{asset} lost frames — a flattened or thinned banner still passes every " \
        "other assertion here, and still reads as GIF89a at the right size"

      # The looping application extension. Without it a mail client that DOES
      # animate plays the waves once and stops on the last frame.
      assert_includes data, "NETSCAPE2.0",
        "#{asset} lost its loop extension — the animation would play once and stop"
    end
  end

  # The two maps above are hand-maintained, and a new banner that nobody adds to
  # them would sail past the loop with `fetch` never called on it.
  test "every standard banner is pinned in both maps" do
    assets = Studio::EmailCatalog::STANDARD.flat_map { |a| [a[:default_asset], a[:background]] }.compact.uniq

    assets.each do |asset|
      assert BANNER_FRAMES.key?(asset), "#{asset} ships unpinned — add its frame count to BANNER_FRAMES"
      assert BANNER_SIZES.key?(asset),  "#{asset} ships unpinned — add its size to BANNER_SIZES"
    end
  end

  # REGRESSION GUARD. The artwork is 3:1 but the shared default is 2:1, and
  # turf-monster's eight banners ARE 2:1. A single global constant would either
  # letterbox this artwork or crop turf-monster's on every upload, so the ratio
  # is per-entry.
  test "each email carries its own banner shape" do
    assert_equal 2.0, Studio::EmailCatalog.ratio("magic_link")
    assert_equal 2.0, Studio::EmailCatalog.ratio("newsletter_subscribed")

    Studio::EmailCatalog.register("winnings", default_asset: "emails/winnings.jpg")
    assert_equal Studio::EmailCatalog::ASPECT_RATIO, Studio::EmailCatalog.ratio("winnings"),
      "an app that states no ratio keeps the shared default — turf-monster depends on this"

    Studio::EmailCatalog.register("wide", default_asset: "emails/wide.jpg", aspect_ratio: 4.0)
    assert_equal 4.0, Studio::EmailCatalog.ratio("wide")
  end

  test "the crop modal enforces each email's own ratio, not one page-wide value" do
    Studio::EmailCatalog.register("winnings", label: "Contest winnings",
                                  default_asset: "emails/winnings.jpg")
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |key| "/assets/emails/#{key}.gif" }

    # Per-page now, because the cropper is mounted on the email being edited
    # rather than once per row. The property is unchanged: each email crops to
    # ITS OWN shape, not to one page-wide value.
    assert_includes render_show("magic_link"), "aspectRatio: 2.0",
      "the standard emails must crop to the shape of their own 3:1 artwork"
    assert_includes render_show("winnings"), "aspectRatio: #{Studio::EmailCatalog::ASPECT_RATIO}",
      "an email on the shared default ratio must still crop at that ratio"
  end

  test "the asset initializer enumerates the default banners for a sprockets host" do
    paths = Studio::Engine.default_email_banner_logical_paths

    assert_includes paths, "emails/magic-link.gif"
    assert_includes paths, "emails/newsletter-subscribed-background.gif"
    assert_includes Rails.application.config.assets.precompile, "emails/magic-link.gif",
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
      assert_equal "http://localhost:3001", Studio::EmailCatalog.mailer_asset_host
    end
  end

  test "a production host with no port resolves to https with no port" do
    with_default_url_options(host: "mcritchie.studio") do
      assert_equal "https://mcritchie.studio", Studio::EmailCatalog.mailer_asset_host
    end
  end

  test "the resolved banner URL is fetchable from the stack it was built on" do
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }

    with_default_url_options(host: "localhost", port: 3001) do
      url = Studio::EmailCatalog.resolved_url("magic_link")

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
    # Every action that WRITES AN IMAGE, and only those. `logo` is here for the
    # same reason as `update`: it uploads to the app's bucket, so an app without
    # one must be told rather than 500. The read paths and the copy/settings
    # writes stay reachable — none of them touch storage.
    assert_equal %w[update destroy logo].sort, actions.sort
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

  # The SHOW page, rendered the same bare way. It did not exist as a helper here,
  # and that gap is the whole reason the leak below shipped: the guard was real,
  # the assertion was right, and it only ever looked at the index.
  def render_show(key = "magic_link", uploads_available: true)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.singleton_class.include(Rails.application.routes.url_helpers)
    targets = Studio::EmailPreviewTarget.all
    view.assign(entry: Studio::EmailCatalog.entry(key), subject: "Sample subject",
                preview_error: nil, uploads_available: uploads_available, preview_name: "Alex",
                targets: targets, target: targets.first,
                banner: Studio::Banner.for(key, name: "Alex"))
    view.render(template: "studio/emails/show")
  end

  # THE BUG: the recipient picker renders ENTIRELY from a JSON payload the view
  # builds, and that payload was hand-listed. Studio::EmailPreviewTarget grew
  # avatar fields; the list did not. The result was a grey circle with no letter
  # in it, beside a navbar showing the same person's initials in their own
  # colour — and every avatar assertion in the browser lane passed, because the
  # lab page supplies its own payload.
  # THE LIST IS TWO REAL PEOPLE: the operator admin and an ordinary member.
  #
  # A third, SYNTHETIC "No name on file" entry used to be appended so the
  # name-free fallback header could be previewed. Mr. McRitchie asked for just
  # the two, knowing the cost — so this asserts the DECISION, and the test below
  # keeps the guarantee that actually matters.
  # RUN AGAINST A POPULATED MODEL, which this test did not do and which is why it
  # could not fail. The engine's dummy app has no User model, so `all` returned
  # ["sample-admin"] alone — one entry, no member — and a test whose NAME
  # promises "the admin and the member" was asserting over a list that had
  # neither. Reverting its assertion to the old defective proxy left the suite
  # green, because there was no member present for the proxy to misjudge.
  #
  # ASSERTS SYNTHETIC, not "has no name". Those are not the same thing: the first
  # version used a missing name as a PROXY for synthetic, so a real member who
  # genuinely has no name on file would have failed it — punishing the exact
  # person the name-free fallback header exists to serve.
  test "the example list offers the admin and the member, and nothing synthetic" do
    targets = with_seeded_users { Studio::EmailPreviewTarget.all }

    assert_equal 2, targets.length, "the admin and the member, and nothing else"
    assert_equal %w[alex@example.test mack@example.test], targets.map(&:email).sort
    refute_stray_synthetic targets
  end

  # The two people every McRitchie app seeds, as the host model would hand them
  # over. Shared so both tests below exercise the SAME populated world.
  def with_seeded_users(rows = nil)
    row = Struct.new(:id, :email, :name, :admin) do
      def try(method, *) = respond_to?(method) ? public_send(method) : nil
      def admin? = admin
    end
    rows ||= [ row.new(1, "alex@example.test", "Alex McRitchie", true),
               row.new(2, "mack@example.test", "Mack McRitchie", false) ]
    fake = Class.new do
      class << self
        attr_accessor :rows
        def column_names = %w[id email name]
        def limit(_n) = rows
        def all = rows
        def respond_to?(m, priv = false) = %i[all column_names limit].include?(m.to_sym) || super
      end
    end
    fake.rows = rows

    target = Studio::EmailPreviewTarget
    original = target.method(:user_model)
    target.define_singleton_method(:user_model) { fake }
    yield
  ensure
    target&.define_singleton_method(:user_model, original) if original
  end

  def nameless_member_row
    Struct.new(:id, :email, :name, :admin) do
      def try(method, *) = respond_to?(method) ? public_send(method) : nil
      def admin? = admin
    end
  end

  # THE INVARIANT, in one place because BOTH tests must share it. Carl proved the
  # cost of not sharing: the regression test below repeated the expression, so
  # reverting the guard here alone left the whole suite green — the regression
  # pinned a COPY of the guard rather than the guard.
  #
  # And `id == "sample-member"` was the wrong property anyway. Against four
  # mutants — re-add same id / re-add renamed / re-add with a name / pristine —
  # only this one kills all of them:
  #
  #   id == "sample-member"   MISSES a rename
  #   sample? && name.nil?    MISSES one re-added with a name
  #   sample? && !admin?      catches all three
  #
  # It is also the honest statement of the rule: the ONLY synthetic the picker
  # may offer is the admin backstop, which an app with no User model still needs.
  def refute_stray_synthetic(targets)
    stray = targets.select { |t| t.sample? && !t.admin? }

    assert_empty stray.map(&:id),
      "the synthetic nameless entry was removed deliberately; the only stand-in the " \
      "picker may offer is the admin backstop. Do not re-add a synthetic member here."
  end

  # THE REGRESSION CARL FOUND, pinned. The guard above once used "has no name" as
  # a stand-in for "is synthetic". A REAL member with no name on file is the
  # person the fallback header exists to serve, and the old assertion failed on
  # them — so the natural fix would have been to give them a name. This proves
  # the guard now tolerates exactly that person.
  test "a real member with no name on file does not trip the synthetic guard" do
    row = nameless_member_row
    rows = [ row.new(1, "alex@example.test", "Alex McRitchie", true),
             row.new(2, "mack@example.test", nil, false) ] # no name on file

    targets = with_seeded_users(rows) { Studio::EmailPreviewTarget.all }
    nameless = targets.find { |t| t.name.nil? }

    refute_nil nameless, "the member has no name on file — that is the case under test"
    refute nameless.sample?, "they are a real record, not a stand-in"
    refute_stray_synthetic targets # the SAME expression the guard uses, not a copy
  end

  # THE NO-USER-MODEL WORLD, unstubbed — the shape the deleted builder served,
  # and the one mutant every other test here is blind to. The two tests above
  # stub a POPULATED model, so `find_member` never reaches its `record.nil?`
  # branch; the two below never call `all` at all. Restore the deleted builder as
  # that nil fallback and, without this test, the whole suite stays green — while
  # the suite this one replaced caught it. That is a kill worth keeping.
  test "an app with no User model is offered the admin backstop alone" do
    assert_nil Studio::EmailPreviewTarget.send(:user_model),
      "precondition: the engine's dummy app defines no User model"

    targets = Studio::EmailPreviewTarget.all

    assert_equal %w[sample-admin], targets.map(&:id), "the backstop, and nothing beside it"
    refute_stray_synthetic targets
  end

  # THE INVARIANT ITSELF, exercised directly — because both tests above run
  # against a picker that currently offers no synthetic member, so neither can
  # tell `sample? && !admin?` apart from a check on one hard-coded id. That
  # difference is the whole point: an id check misses the same entry re-added
  # under any other name, which is exactly how this defect would return.
  test "a synthetic member is rejected whatever id it is given" do
    admin_backstop = Studio::EmailPreviewTarget.new(
      id: "sample-admin", label: "Admin (sample)", admin: true,
      name: "Alex McRitchie", email: "alex@example.test"
    )
    stray = Studio::EmailPreviewTarget.new(
      id: "sample-anything-at-all", label: "No name on file", admin: false,
      name: nil, email: "someone@example.test"
    )

    # The backstop alone is legitimate — an app with no User model needs it, and
    # forbidding every sample would leave that app an empty picker.
    assert_nothing_raised { refute_stray_synthetic [ admin_backstop ] }

    assert_raises(Minitest::Assertion, "a synthetic member must be rejected on its own terms") do
      refute_stray_synthetic [ admin_backstop, stray ]
    end
  end

  # A synthetic member that HAS a name is still synthetic. Pins the third mutant:
  # `sample? && name.nil?` would wave this one through.
  test "a synthetic member with a name is still rejected" do
    named_stray = Studio::EmailPreviewTarget.new(
      id: "sample-someone", label: "Someone", admin: false,
      name: "Someone", email: "someone@example.test"
    )

    assert_raises(Minitest::Assertion) { refute_stray_synthetic [ named_stray ] }
  end

  # THE FALLBACK HEADER STILL SHIPS, and that is the part worth protecting. It
  # is what a magic link sends to anyone without an account — the case nobody
  # checks, because whoever is previewing has a name on file. Removing the
  # dropdown entry removed the way to LOOK at it, not the behaviour, so this
  # exercises the banner directly instead of through a preview target.
  test "a recipient with no name still gets the fallback header" do
    header = Studio::Banner.for(:magic_link, name: nil).header

    assert_equal "Your Magic Link", header
    refute_includes header, "Welcome !", "this is the exact failure the fallback exists to prevent"
  end

  # --- who the two are ------------------------------------------------------

  # WHOEVER SORTS FIRST IS NOT THE ANSWER. Without a preference this offered
  # McRitchie Studio's team@ account instead of alex@, and turf-monster's
  # jordan@ test-fixture row instead of Mack.
  test "the admin and member prefer the house standard over first-found" do
    row = Struct.new(:id, :email, :name, :admin) do
      def try(method, *) = respond_to?(method) ? public_send(method) : nil
      def admin? = admin
    end
    rows = [
      row.new(1, "team@example.test",   "Team",           true),
      row.new(2, "jordan@example.test", "Jordan",         false),
      row.new(3, "alex@example.test",   "Alex McRitchie", true),
      row.new(4, "mack@example.test",   "Mack McRitchie", false)
    ]
    fake = Class.new do
      class << self
        attr_accessor :rows
        def column_names = %w[id email name]
        def limit(_n) = rows
        def all = rows
        def respond_to?(m, priv = false) = %i[all column_names limit].include?(m.to_sym) || super
      end
    end
    fake.rows = rows

    # Hand-rolled singleton stub with ensure-restore; Minitest 6 dropped
    # minitest/mock, so there is no .stub here.
    target = Studio::EmailPreviewTarget
    original = target.method(:user_model)
    target.define_singleton_method(:user_model) { fake }

    emails = target.all.map(&:email)

    assert_includes emails, "alex@example.test", "the admin should be Alex, not whoever sorts first"
    assert_includes emails, "mack@example.test", "the member should be Mack, not a fixture row"
    refute_includes emails, "team@example.test"
    refute_includes emails, "jordan@example.test"
  ensure
    target&.define_singleton_method(:user_model, original) if original
  end

  # A "member" whose name is synthesised from their email address is not a
  # nameless member, and the nameless case is the entire reason that option is
  # offered. MS's display_name turns member@… into "Member", so asking for a
  # display name previewed somebody with a name and the fallback header never
  # rendered.
  test "a record with no name reports no name, not a synthesised one" do
    record = Struct.new(:id, :email, :name, :admin) do
      def display_name = "Member"   # the host's presentation fallback
      def try(method, *) = respond_to?(method) ? public_send(method) : nil
    end.new(7, "member@example.test", nil, false)

    target = Studio::EmailPreviewTarget.send(:from_record, record,
                                             id_prefix: "member", label: "Member", admin: false)

    assert_nil target.name, "a blank name is the honest answer to 'do we hold a name'"
  end

  test "the recipient payload carries everything the picker draws" do
    # PARSED, not string-matched: the payload is JSON inside an HTML attribute,
    # so every quote arrives as &quot; and a naive assert_includes on '"initials"'
    # fails against a page that is perfectly correct.
    config = editor_config_from(render_show)

    refute_empty config["targets"], "the picker has nobody to draw"
    config["targets"].each do |target|
      %w[avatar_url avatar_color initials].each do |field|
        assert target.key?(field),
          "the picker draws #{field}; omitting it renders a grey circle with no letter in it"
      end
      refute_nil target["initials"], "an avatar with no initials identifies nobody"
      refute_nil target["avatar_color"]
    end
  end

  # The x-data attribute is `emailBannerEditor({...})`; Nokogiri unescapes the
  # entities, leaving the JSON the browser actually receives.
  def editor_config_from(html)
    attribute = Nokogiri::HTML(html).at_css("[x-data^='emailBannerEditor']")["x-data"]
    JSON.parse(attribute[/emailBannerEditor\((.*)\)\z/m, 1])
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
    # render_show included, because the index-only version of this guard passed
    # while the show page was displaying half a code comment above the banner.
    [render_index, render_index(uploads_available: false), render_show].each do |html|
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
    # By MARKER, not by "tbody tr". Each row now renders the real layered banner,
    # which is an email <table> with rows of its own nested inside the cell — so
    # a descendant selector counts the email's markup as list rows and reports
    # three times as many emails as exist.
    rows = doc.css("tr[data-email-row]")

    assert_equal Studio::EmailCatalog.entries.size, rows.size, "one row per registered email"
    Studio::EmailCatalog.entries.each do |entry|
      row = rows.find { |r| r.text.include?(entry.label) }
      refute_nil row, "expected a row named #{entry.label}"
      # An img for flat artwork, an iframe for a layered banner — the property is
      # that the row SHOWS the email, not which element carries it.
      refute_empty row.css("img, iframe"),
        "#{entry.key}'s row must show its live banner, not just its name"
    end
  end

  # A consumer whose emails are all flat (turf-monster's nine) must keep the
  # markup it had. The layered banner is a <table>, so rendering one in a list
  # row nests rows inside rows — every consumer asserting "one row per email"
  # counted three times as many, and each of those consumers was ALSO being shown
  # a layered banner its mailers never send.
  # THE CONSUMER CONTRACT. A list row must not nest an email <table>: the layered
  # banner is one, and rendering it here made every host's "one row per email"
  # assertion count three rows per layered email. Two consumer suites went red on
  # exactly that. The rendered banner lives on the email's own page instead.
  # THE CONSUMER CONTRACT. The banner is the email's own <table>; nesting one in a
  # list row puts rows inside rows, and every host asserting "one row per email"
  # counted three per layered email. Rendering it through an iframe's srcdoc keeps
  # the markup in a separate document, so the row itself stays one row.
  test "a layered row renders its banner without nesting email markup" do
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }

    row = Nokogiri::HTML.fragment(render_row("magic_link"))

    assert_equal 1, row.css("tr").length, "the row must contain no nested rows"
    assert_empty row.css("table"), "the email's table belongs in the iframe document, not the row"
    refute_empty row.css("iframe[data-email-banner-preview]"), "the banner should still render"
  end

  test "a flat row shows its artwork as a plain image" do
    Studio::EmailCatalog.register("flat_only", label: "Flat only",
                                  default_asset: "emails/magic-link.gif")
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }

    row = Nokogiri::HTML.fragment(render_row("flat_only"))

    assert_empty row.css("iframe"), "an email whose artwork is flat has no layered banner to show"
    refute_empty row.css("img")
  ensure
    Studio::EmailCatalog.reset!
  end

  # ONE row, rendered alone, so an assertion about a row cannot pick up its
  # neighbour's markup.
  def render_row(key)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.singleton_class.include(Rails.application.routes.url_helpers)
    view.render(partial: "studio/emails/row",
                locals: { entry: Studio::EmailCatalog.entry(key), uploads_available: true,
                          max_width: Studio::EmailCatalog::MAX_WIDTH, preview_name: "Alex" })
  end

  test "a row says its image is the SHARED default when the app uploaded nothing" do
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |_key| "/assets/emails/magic-link.gif" }

    html = render_show
    # magic_link + newsletter_subscribed are the engine's OWN standard two,
    # so on an app that registered no artwork of its own this really is the
    # Studio default.
    assert_includes html, "Studio default"
    refute_includes html, "No image yet",
      "the pre-registry copy claimed an email had no image while it was sending one"
  end

  test "a row says the image is APP-OWNED once this app uploaded its own" do
    row = Object.new
    row.define_singleton_method(:url) { "https://turf-monster-dev.s3.amazonaws.com/email_banners/magic_link-ab12.png" }
    stub_module(Studio::EmailCatalog, :record) { |key| key.to_s == "magic_link" ? row : nil }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |_key| "/assets/emails/default.png" }

    # One page per email now, so the two states are compared ACROSS pages rather
    # than down a column. Same property: an upload and an inherited default must
    # not read the same.
    uploaded = render_show("magic_link")
    inherited = render_show("newsletter_subscribed")

    assert_includes uploaded, "Uploaded here"
    assert_includes inherited, "Studio default",
      "an email still on the shared artwork must say so, not inherit the neighbour's label"
    assert_includes uploaded, "Revert", "an uploaded image can be dropped back to the default"
    refute_includes inherited, "Revert", "there is nothing to revert to when nothing was uploaded"
  end

  # REGRESSION GUARD, at the level the operator actually reads.
  #
  # The row's copy is the whole product of this column. It used to print
  # "Shared Studio artwork, shipped with the engine" for ANY registered asset,
  # so turf-monster's own eight committed banners were announced as the
  # engine's. Asserting source() alone would not have caught it — the wrong
  # answer was in the view.
  test "a host's own registered artwork is never called the engine's" do
    Studio::EmailCatalog.register("winnings", label: "Contest winnings",
                                  default_asset: "emails/winnings-banner.jpg")
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |key| "/assets/emails/#{key}.jpg" }

    html = render_show("winnings")

    assert_includes html, ERB::Util.html_escape("#{Studio.app_name}'s artwork")
    refute_includes html, "ships with the engine",
      "an app's committed artwork must not be described as the engine's"
  end

  test "the engine's own standard artwork is still called the Studio default" do
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |_key| "/assets/emails/magic-link.gif" }

    html = render_show

    assert_includes html, "Studio default"
    assert_includes html, "ships with the engine"
  end

  test "the summary line counts the app's own artwork, however it got there" do
    Studio::EmailCatalog.entries.each do |entry|
      Studio::EmailCatalog.register(entry.key, default_asset: "emails/#{entry.key}.jpg")
    end
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |key| "/assets/emails/#{key}.jpg" }

    html = render_index

    assert_includes html, ERB::Util.html_escape("all on #{Studio.app_name}'s own artwork")
    refute_includes html, "all inheriting the default artwork",
      "an app whose banners all ship from its own repo is not inheriting anything"
  end

  test "an email with no image at all is labelled distinctly from an inherited one" do
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |_key| nil }

    html = render_show
    assert_includes html, "No image"
    refute_includes html, "Inherited default"
  end

  test "upload runs through the shared crop modal, never a bare file input" do
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |_key| "/assets/emails/magic-link.gif" }

    html = render_show
    assert_includes html, "imageUploadHost(", "each row hosts the shared cropper uploader"
    assert_includes html, "crop-photo-confirmed", "the cropped blob feeds the row's hidden form"

    doc = Nokogiri::HTML(html)
    visible_file_inputs = doc.css('input[type="file"]').reject { |i| i["class"].to_s.include?("hidden") }
    assert_empty visible_file_inputs,
      "the old page's bare file_field_tag must be gone — uploads go through the crop modal"
  end


  # THE FAN-OUT, pinned as a PROPERTY rather than a spelling.
  #
  # `crop-photo-confirmed` is a WINDOW event and this page mounts one
  # imageUploadHost PER ROW, so every row hears every confirm. Before the owner
  # guard, one confirmed crop PATCHed EVERY row's banner with the same image —
  # destroying any app-owned banner already there — and since the engine
  # pre-registers two emails, the FIRST upload any consumer admin performed hit it.
  #
  # The old assertion (`assert_includes html, "crop-photo-confirmed"`) passes with
  # one listener or twenty, which is exactly why it never saw this. These assert the
  # effect: every listener is ownership-guarded, and the unguarded form appears
  # NOWHERE on a page that renders more than one row.
  test "no row applies a crop unconditionally — every listener is ownership-guarded" do
    stub_module(Studio::EmailImage, :record) { |_key| nil }
    stub_module(Studio::EmailImage, :default_asset_path) { |_key| "/assets/emails/magic-link.gif" }

    html = render_show

    # Counted on the RAW markup, deliberately. Nokogiri's HTML parser DROPS Alpine
    # attributes (`@crop-photo-confirmed.window` is not a legal attribute name), so a
    # DOM assertion cannot see the handler at all — which is very likely why the
    # original test settled for a page-wide substring that passes with one listener
    # or twenty.
    hosts = html.scan("imageUploadHost(").size
    guarded = html.scan("onCropConfirmed($event.detail)").size

    assert_operator hosts, :>, 1,
      "precondition: the page must mount MORE THAN ONE uploader host, or this proves nothing"
    assert_equal hosts, guarded,
      "every uploader host must route the window confirm through the ownership guard — " \
      "one unguarded host is the fan-out that PATCHes every row's banner with one image"
    refute_includes html, "applyCrop($event.detail.blob)",
      "the UNGUARDED form must not survive on a multi-row page — that IS the fan-out"
  end

  # WHAT THIS TIER CANNOT PROVE, said plainly so nobody mistakes green for safe.
  # The test above asserts the WIRING (every host routes through the guard) and
  # mutation-reddens when a row is re-wired to apply blindly. It CANNOT prove the
  # guard's logic works: neutering the `detail.owner !== ownerId` comparison inside
  # imageUploadHost leaves this suite green, because nothing here executes
  # JavaScript. Proving the behaviour needs a browser tier that dispatches
  # `crop-photo-confirmed` with a foreign owner on a two-row page and asserts
  # exactly ONE form submits. Filed rather than faked — a markup assertion dressed
  # up as a behavioural one is how a suite starts lying.

  test "the crop and saving modals mount on a PAGE-SCOPED store" do
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |_key| "/assets/emails/magic-link.gif" }

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
    stub_module(Studio::EmailCatalog, :default_asset_path) { |_key| "/assets/emails/magic-link.gif" }

    # The EXPLANATION stays on the list, where an operator lands first; the
    # missing UPLOADER is a property of the email's own page, where the button
    # would otherwise be. Both halves of "degrade honestly" are asserted.
    index = render_index(uploads_available: false)
    show = render_show(uploads_available: false)

    assert_includes index, "s3_bucket_prefix", "say what is missing, in the operator's terms"
    assert_includes show, "Studio default", "it still SHOWS what is shipping — that is the honest part"
    refute_includes show, "imageUploadHost(",
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

  # --- 6. the preview cannot take the page down (the REAL mailer shape) ------

  # REGRESSION GUARD, and the reason it needs a booted Rails rather than a
  # stand-in. The unit suite's fake mail is EAGER, so it cannot reproduce this:
  # the idiom this feature documents — `preview: -> { SomeMailer.action(...) }` —
  # returns an ActionMailer::MessageDelivery, a LAZY proxy whose mailer action
  # has not run at `call` time. The catalog used to hand that proxy straight
  # back, record no error, and let the mailer finally raise at #preview_subject,
  # outside every rescue — a 500 on /admin/emails/:key through the host's
  # rescue_from. One preview cost the whole manager.
  #
  # turf-monster's catalog on main — the prior art this work folds in — is eight
  # builders, every one a mailer call. So this is the FIRST adopter's shape, not
  # an exotic one.
  class PreviewProbeMailer < ActionMailer::Base
    def explodes
      raise ArgumentError, "sample data is gone"
    end

    def works
      mail(to: "someone@example.com", subject: "Your magic link", body: "<p>hi</p>",
           content_type: "text/html")
    end
  end

  test "a REAL lazy mailer delivery that fails is contained, not propagated" do
    Studio::EmailCatalog.register("probe_boom", preview: -> { PreviewProbeMailer.explodes })

    assert_instance_of ActionMailer::MessageDelivery, PreviewProbeMailer.explodes,
      "guard the guard: if this stops being lazy, this test stops testing anything"

    assert_nil Studio::EmailCatalog.preview_mail("probe_boom")
    assert_nil Studio::EmailCatalog.preview_subject("probe_boom"),
      "preview_subject is the FIRST thing #show calls — it must never propagate"
    assert_nil Studio::EmailCatalog.preview_html("probe_boom")
    assert_includes Studio::EmailCatalog.preview_error("probe_boom"), "ArgumentError"
  end

  test "a REAL lazy mailer delivery that works renders its subject and body" do
    Studio::EmailCatalog.register("probe_ok", preview: -> { PreviewProbeMailer.works })

    assert_equal "Your magic link", Studio::EmailCatalog.preview_subject("probe_ok")
    assert_includes Studio::EmailCatalog.preview_html("probe_ok"), "<p>hi</p>"
    assert_nil Studio::EmailCatalog.preview_error("probe_ok")
  end

  # The user-visible half: the page still RENDERS, and says why, instead of
  # handing the host's error handler a 500.
  test "the show page renders the failure reason instead of losing the page" do
    Studio::EmailCatalog.register("probe_boom", preview: -> { PreviewProbeMailer.explodes })
    Studio::EmailCatalog.preview_mail("probe_boom")

    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.singleton_class.include(Rails.application.routes.url_helpers)
    view.assign(entry: Studio::EmailCatalog.entry("probe_boom"),
                subject: Studio::EmailCatalog.preview_subject("probe_boom"),
                preview_error: Studio::EmailCatalog.preview_error("probe_boom"),
                uploads_available: false)

    html = view.render(template: "studio/emails/show")
    assert_includes html, "ArgumentError", "the page must say WHY the preview is missing"
    assert_includes html, "Probe boom", "the rest of the page must survive one dead preview"
  end
end
