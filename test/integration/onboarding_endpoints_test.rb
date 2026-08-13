# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

# [integration] Guard for the shared first-name onboarding step's SERVER half —
# the two writes (Studio::OnboardingController), the opt-in route draw, and the
# one rule every app agrees on (Studio.first_name_outstanding?).
#
# The partial that renders the step is covered by test/views/onboarding_first_name_test.rb.
# This file covers what only shows up once a real Rails app is booted.
#
# The load-bearing properties, each exercised rather than declared:
#
#   1. The endpoints are OFF by default, for the same hard reason /admin/emails
#      is — turf-monster owns both helper names TODAY.
#   2. Opted in, they draw at the paths the partial posts to by default, so a
#      host that wants only the name ask needs no further wiring.
#   3. The engine owns ONE STEP and the host owns the SEQUENCE: the `next` array
#      comes from Studio.onboarding_steps_resolver, whose default is empty.
#   4. first_name_outstanding? tolerates a host with NO first_name column
#      (mcritchie-industries, until its migration lands) instead of raising on
#      every signed-in request.
class OnboardingEndpointsTest < ActiveSupport::TestCase
  def routes
    Rails.application.routes.url_helpers
  end

  def teardown
    Studio.onboarding_steps_resolver = ->(_user, _session) { [] }
  end

  # A stand-in for the host's User. The dummy app has no users table — these
  # rules are pure, and testing them against a real record would only prove
  # ActiveRecord works.
  FakeUser = Struct.new(:first_name, :name)

  # --- 1. the collision guard -------------------------------------------------

  # REGRESSION GUARD, and the reason the endpoints are opt-in at all.
  #
  # turf-monster's routes.rb already contains:
  #   post "/onboarding/first_name",      as: :onboarding_first_name
  #   post "/onboarding/skip_first_name", as: :onboarding_skip_first_name
  #
  # Drawing these unconditionally raises `Invalid route name, already in use`
  # WHILE turf-monster's own routes load, which takes down every route in that
  # app — not just this pair. Consumer CI runs each consumer's `main`, so a host
  # cannot opt OUT of something that breaks it before its config is read.
  # Default-off is the only shape that works until turf's local copy is deleted.
  test "the onboarding endpoints are OFF by default" do
    # Read the SHIPPED default, not the live value — test/dummy/config/routes.rb
    # opts in the way a consuming app does, so the runtime value is true here.
    source = File.read(File.expand_path("../../lib/studio.rb", __dir__))
    default = source[/mattr_accessor :draw_onboarding_routes,\s*default: (\w+)/, 1]

    refute_nil default, "expected a draw_onboarding_routes accessor with an explicit default"
    assert_equal "false", default,
      "default-on collides with turf-monster's own onboarding routes and kills its entire route set"
  end

  # --- 2. the draw ------------------------------------------------------------

  test "a host that opts in gets both endpoints at the partial's default paths" do
    # Routes draw LAZILY, and the flag is set by test/dummy/config/routes.rb AS
    # IT DRAWS — so on a seed that runs this before any route-touching test, the
    # pre-draw default would be read. Force the draw first (same guard the
    # /admin/emails suite carries for this exact flake).
    Rails.application.reload_routes!

    assert Studio.draw_onboarding_routes, "the dummy opts in the way a consuming app does"

    assert_equal "/onboarding/first_name", routes.onboarding_first_name_path
    assert_equal "/onboarding/skip_first_name", routes.onboarding_skip_first_name_path
  end

  test "the drawn paths dispatch to the engine controller" do
    Rails.application.reload_routes!
    recognized = Rails.application.routes.recognize_path("/onboarding/first_name", method: :post)

    assert_equal "studio/onboarding", recognized[:controller]
    assert_equal "first_name", recognized[:action]
  end

  # The partial POSTs to these literal strings by default. If the route paths and
  # the partial's defaults ever drift, a host that opts in and writes no config
  # gets a modal that 404s on save — with no test failing anywhere else.
  test "the drawn paths match the partial's default submit and skip targets" do
    partial = File.read(File.expand_path(
      "../../app/views/studio/modals/onboarding/_first_name.html.erb", __dir__
    ))

    Rails.application.reload_routes!

    assert_includes partial, %(fetch(:submit_path, "#{routes.onboarding_first_name_path}"))
    assert_includes partial, %(fetch(:skip_path, "#{routes.onboarding_skip_first_name_path}"))
  end

  # --- 3. one step here, the sequence in the host -----------------------------

  test "the default resolver reports nothing further" do
    # Correct for an app whose only onboarding ask is the name — it must not have
    # to configure anything to get a working single-step flow.
    assert_equal [], Studio.onboarding_steps_resolver.call(FakeUser.new(nil, nil), {})
  end

  test "a host declares its own sequence and the controller stringifies it" do
    # turf walks welcome -> first name -> age -> wallet; a hub app asks nothing
    # else. The host resolver is the seam, and symbols are what a host flow
    # naturally returns, so the wire format must not depend on that choice.
    Studio.onboarding_steps_resolver = ->(_user, _session) { [:age, :wallet] }
    result = Array(Studio.onboarding_steps_resolver.call(FakeUser.new(nil, nil), {})).map(&:to_s)

    assert_equal %w[age wallet], result
  end

  test "the resolver receives the user and the session" do
    seen = nil
    Studio.onboarding_steps_resolver = ->(user, session) { seen = [user, session]; [] }
    user = FakeUser.new("Alex", "Alex")
    Studio.onboarding_steps_resolver.call(user, { foo: 1 })

    assert_equal [user, { foo: 1 }], seen,
      "a host flow needs both to decide what remains"
  end

  # --- 4. the shared rule -----------------------------------------------------

  test "an account with no first name still owes one" do
    assert Studio.first_name_outstanding?(FakeUser.new(nil, "alex@example.com"), {})
    assert Studio.first_name_outstanding?(FakeUser.new("", "alex@example.com"), {})
    assert Studio.first_name_outstanding?(FakeUser.new("   ", "alex@example.com"), {})
  end

  test "an account that has answered is never asked again" do
    refute Studio.first_name_outstanding?(FakeUser.new("Alex", "Alex"), {})
  end

  test "skipping is session-scoped, not permanent" do
    user = FakeUser.new(nil, nil)
    skipped = { Studio::FIRST_NAME_SKIP_SESSION_KEY => true }

    refute Studio.first_name_outstanding?(user, skipped),
      "not now means not now"
    assert Studio.first_name_outstanding?(user, {}),
      "a LATER session asks again — the field is still blank, which is why this is not a column"
  end

  test "a signed-out visitor owes nothing" do
    refute Studio.first_name_outstanding?(nil, {})
  end

  # mcritchie-industries has no users.first_name column today. Its adoption task
  # adds one — but the gem lands there first (an engine bump is its own PR), and
  # between those two the rule is evaluated on every signed-in request. It must
  # answer "nothing to ask", not raise.
  test "a host whose users table has no first_name column is simply never asked" do
    columnless = Object.new

    refute Studio.first_name_outstanding?(columnless, {}),
      "an app that has not run the migration must not raise on every request"
  end

  # --- the controller ---------------------------------------------------------

  test "the controller bounds the stored name" do
    ensure_application_controller!

    assert_equal 40, Studio::OnboardingController::MAX_FIRST_NAME,
      "the server stays the real bound — the input's maxlength is a courtesy"
  end

  test "the controller answers both endpoints" do
    ensure_application_controller!
    actions = Studio::OnboardingController.action_methods

    assert_includes actions, "first_name"
    assert_includes actions, "skip_first_name"
  end

  # The dummy app defines no ApplicationController (it stands in for a host, and
  # hosts own theirs). Same helper the /admin/emails suite uses.
  def ensure_application_controller!
    return if Object.const_defined?(:ApplicationController)

    Object.const_set(:ApplicationController, Class.new(ActionController::Base) {
      include Studio::ErrorHandling
    })
  end
end
