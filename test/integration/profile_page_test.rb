# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

# [integration] The shared /profile page's SERVER half — the route draw, the
# controller's dispatch, and the two contracts it shares with code that lives
# elsewhere in the engine.
#
# The resolution rules are pure logic and covered in
# test/lib/studio/profile_sections_test.rb; the display helpers in
# test/lib/studio/user_profile_test.rb; the navbar's link in
# test/views/user_nav_test.rb. What only shows up once a real Rails app is
# booted is whether the routes actually draw and dispatch.
#
# The dummy app has NO users table (it stands in for a host, and hosts own
# theirs), so this file does not exercise a write. That boundary is why the
# controller's own invariants are asserted as source below rather than by
# driving a request — the same technique test/integration/standard_profile_columns_test.rb
# uses for the migration, and for the same reason.
class ProfilePageTest < ActiveSupport::TestCase
  CONTROLLER = File.expand_path("../../app/controllers/studio/profiles_controller.rb", __dir__)

  def routes
    Rails.application.routes.url_helpers
  end

  def controller_source
    @controller_source ||= File.read(CONTROLLER)
  end

  def ensure_application_controller!
    return if Object.const_defined?(:ApplicationController)

    Object.const_set(:ApplicationController, Class.new(ActionController::Base) {
      include Studio::ErrorHandling
    })
  end

  # --- the draw ---------------------------------------------------------------

  # ON BY DEFAULT, unlike every other opt-in page the engine ships — and that
  # difference is the entire reason the page is /profile and not /account.
  #
  # draw_admin_emails_routes and draw_onboarding_routes MUST default off because
  # turf-monster already owns those helper names, and drawing them raises
  # `Invalid route name, already in use` while that app's routes.rb loads, taking
  # down its whole route set. `profile` is claimed by no consumer (checked
  # 2026-08-14 across mcritchie-studio, mcritchie-industries, turf-monster,
  # moms-app and acquisition-studio), so this one can be on — which is what makes
  # a brand-new app's profile page work with an empty initializer.
  test "the profile routes are ON by default" do
    source = File.read(File.expand_path("../../lib/studio.rb", __dir__))
    default = source[/mattr_accessor :draw_profile_routes,\s*default: (\w+)/, 1]

    refute_nil default, "expected a draw_profile_routes accessor with an explicit default"
    assert_equal "true", default,
      "a new app must get a working profile page without configuring anything"
  end

  test "the page draws at /profile with its avatar route beside it" do
    # Routes draw lazily; force the draw rather than depending on seed order
    # (the same guard the /admin/emails and onboarding suites carry).
    Rails.application.reload_routes!

    assert_equal "/profile", routes.profile_path
    assert_equal "/profile/avatar", routes.profile_avatar_path
  end

  test "the unlink route draws as a DELETE and dispatches" do
    ensure_application_controller!
    Rails.application.reload_routes!

    assert_equal "/profile/google", routes.profile_unlink_google_path

    recognized = Rails.application.routes.recognize_path("/profile/google", method: :delete)
    assert_equal "studio/profiles", recognized[:controller]
    assert_equal "unlink_google", recognized[:action]
  end

  # Linking is OmniAuth's `/auth/:provider`, owned by the middleware — the engine
  # must NOT draw a link route of its own, or it shadows the strategy's.
  test "the engine draws no google LINK route of its own" do
    Rails.application.reload_routes!

    refute Rails.application.routes.url_helpers.respond_to?(:profile_link_google_path),
      "linking belongs to OmniAuth's /auth/:provider, not to this engine"
  end

  # THE ORPHAN GUARD AT THE ENDPOINT, not only in the view. The row disables the
  # button for a Google-only account, but a disabled button is a UI courtesy —
  # anyone can send the DELETE. The controller must refuse it on its own, through
  # the same predicate the view asks.
  test "the unlink action refuses an unlink that would orphan the account" do
    assert_includes controller_source, "Studio::OauthIdentity.unlink_orphans_account?",
      "a disabled button is not a guard — the endpoint must refuse it too"

    guard_index  = controller_source.index("unlink_orphans_account?")
    update_index = controller_source.index("current_user.update!(provider: nil, uid: nil)")

    refute_nil update_index, "expected the unlink write"
    assert guard_index < update_index,
      "the orphan check must run BEFORE the identity is cleared"
  end

  test "the drawn paths dispatch to the engine controller" do
    # recognize_path resolves the controller LAZILY, which loads
    # Studio::ProfilesController — and that inherits ::ApplicationController,
    # which the dummy does not define (hosts own theirs). Without this the result
    # depends on seed order.
    ensure_application_controller!
    Rails.application.reload_routes!

    show = Rails.application.routes.recognize_path("/profile", method: :get)
    assert_equal "studio/profiles", show[:controller]
    assert_equal "show", show[:action]

    update = Rails.application.routes.recognize_path("/profile", method: :patch)
    assert_equal "update", update[:action]

    avatar = Rails.application.routes.recognize_path("/profile/avatar", method: :patch)
    assert_equal "avatar", avatar[:action]
  end

  # --- the avatar's own route -------------------------------------------------

  # REGRESSION GUARD, and the reason the avatar is not just another field on
  # PATCH /profile: an attachment param submitted EMPTY purges the attachment.
  # A single form carrying both the name and the file would therefore delete
  # someone's photo every time they edited their name. turf-monster hit this and
  # branched inside its own #update; a separate route makes the trap unreachable
  # rather than merely avoided, and collapsing the two routes back together is
  # exactly the "simplification" this test exists to stop.
  test "the avatar write has a route of its own, separate from the field update" do
    Rails.application.reload_routes!

    refute_equal routes.profile_path, routes.profile_avatar_path,
      "one endpoint for both means an empty file field purges the avatar on every name save"

    assert_includes controller_source, "def avatar"
    assert_includes controller_source, "def update"
  end

  # --- contracts shared with code elsewhere -----------------------------------

  # The same users.first_name column is written from TWO surfaces (the onboarding
  # step, seconds after signup; this page, any time after) and rendered by a
  # third (the form's maxlength). They read ONE constant rather than agreeing by
  # discipline — this asserts the structure, not a coincidence of two numbers.
  test "both first-name surfaces read the one shared cap" do
    ensure_application_controller!

    assert_equal Studio::FIRST_NAME_MAX_LENGTH, Studio::ProfilesController::MAX_FIRST_NAME
    assert_equal Studio::FIRST_NAME_MAX_LENGTH, Studio::OnboardingController::MAX_FIRST_NAME

    form = File.read(File.expand_path(
      "../../app/views/studio/profiles/_first_name_section.html.erb", __dir__
    ))
    assert_includes form, "Studio::FIRST_NAME_MAX_LENGTH",
      "the form's maxlength must come from the shared constant, not a literal"
    refute_includes form, "ProfilesController",
      "a view reaching into a controller for a constant couples them for no reason"
  end

  # The page reads the current user on every row. Losing the guard would make
  # /profile a public page that raises NoMethodError on nil rather than
  # redirecting a signed-out visitor to login.
  test "the page requires authentication" do
    assert_includes controller_source, "before_action :require_authentication"
  end

  # The rows the page renders come from the registry, never from a hardcoded
  # list — that indirection IS the per-app customization seam.
  test "the page renders resolved sections rather than a fixed list" do
    assert_includes controller_source, "Studio.profile_sections_for",
      "hardcoding the rows removes the seam every consuming app extends through"
  end

  # A HIDDEN ROW IS NOT A GUARD, and this is the test that says so.
  #
  # ProfileSections drops a row the host cannot serve, so nobody SEES a
  # first-name form in an app without the column. The endpoint is still open to
  # anyone who posts to it, and Studio::ErrorHandling#rescue_and_log RE-RAISES —
  # so an unguarded write is a 500 plus an ErrorLog row. Three of the five
  # consumers have an avatar and no first_name column TODAY (mcritchie-industries,
  # moms-app, acquisition-studio), so this is the live shape of the ecosystem
  # rather than a defensive hypothetical.
  #
  # Both write actions must ask the SAME question the row asks, through the same
  # predicate, so the endpoint and the page cannot drift apart.
  # Asserts the PROPERTY — every write action refuses before it writes — rather
  # than a particular spelling of the guard. The earlier version of this test
  # regex-matched `unsupported(:x) unless serves?(:x)` and broke the moment a
  # guard legitimately checked two columns while naming one row, which is a test
  # failing on a reformat rather than on a defect.
  WRITE_ACTIONS = %w[update avatar unlink_google].freeze

  test "every write action refuses before it writes" do
    bodies = controller_source.split(/^    def /).to_h do |chunk|
      [chunk[/\A(\w+)/, 1], chunk]
    end

    WRITE_ACTIONS.each do |action|
      body = bodies[action]
      refute_nil body, "expected a #{action} action"

      guard_at = body.index("serves?(")
      write_at = body.index(/current_user\.(update|avatar\.attach)/)

      refute_nil guard_at, "#{action} must ask whether this host can serve the field"
      refute_nil write_at, "expected #{action} to write something"
      assert guard_at < write_at,
        "#{action} writes before it guards — the endpoint 500s where its row is merely hidden"
    end
  end

  # The guard delegates to the registry's predicate rather than re-deriving
  # respond_to? — one rule, unit-tested in test/lib/studio/profile_sections_test.rb.
  test "the guard reuses the registry's own predicate" do
    assert_includes controller_source, "Studio::ProfileSections.served_by?"

    ensure_application_controller!
    thin = Struct.new(:x).new(nil)
    full = Struct.new(:first_name).new("Pat")

    refute Studio::ProfileSections.served_by?(thin, :first_name)
    assert Studio::ProfileSections.served_by?(full, :first_name)
  end

  # --- the default page's partials actually exist -----------------------------

  # Studio::ProfileSections names two partials by path. A rename that missed one
  # would raise ActionView::MissingTemplate on a page the host cannot fix, and
  # nothing in the pure-Ruby unit suite can see it — that suite asserts keys, not
  # files.
  test "every default section names a partial that exists" do
    Studio::ProfileSections.defaults.each do |section|
      path = File.expand_path("../../app/views/#{File.dirname(section[:partial])}/_#{File.basename(section[:partial])}.html.erb", __dir__)

      assert File.exist?(path),
        "section #{section[:key].inspect} names #{section[:partial]}, which is not on disk at #{path}"
    end
  end
end
