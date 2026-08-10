# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"

# [component] The bar stack — bars render as the navbar's SIBLING, and the navbar
# offsets itself by however many rendered.
#
# The contract, in the order it matters:
#   A. The stack publishes a height the navbar can read, and that height tracks
#      the number of bars actually rendered — not a constant.
#   B. The navbar consumes it and never learns WHICH bars rendered.
#   C. No bars → nothing published, and the navbar is byte-identical to its
#      pre-stack behaviour (top:0). An app that hasn't adopted is unaffected.
#   D. EXACTLY ONE vt-pinned-header per page. A duplicate view-transition-name
#      silently disables every transition on the page — this codebase has been
#      bitten by it, so it is asserted rather than hoped.
class BarStackTest < ActiveSupport::TestCase
  ENGINE_ROOT = File.expand_path("../..", __dir__)

  class StubUser
    def display_name = "Ada"
    def id = 1
  end

  class StubRequest
    def local? = true
  end

  setup do
    @original_qa = ENV["QA_ENV"]
    ENV.delete("QA_ENV")
  end

  teardown do
    ENV["QA_ENV"] = @original_qa
    ENV.delete("QA_ENV") if @original_qa.nil?
  end

  # ── A. the height tracks what actually rendered ──────────────
  #
  # The server value is a FIRST-PAINT ESTIMATE. The truth comes from the
  # ResizeObserver below, which is what lets a taller bar — or a third one —
  # work without touching a single consuming app.

  test "the stack ships an observer that publishes its measured height" do
    html = render_stack

    assert_includes html, "data-studio-bar-stack"
    assert_includes html, "ResizeObserver"
    assert_includes html, "--studio-bars-h"
    # Re-bound on Turbo nav: a stale observer on a detached node stops updating
    # silently, and the navbar would then sit at yesterday's offset.
    assert_includes html, "turbo:load"
  end


  test "one bar publishes a one-unit height" do
    html = render_stack

    assert_includes html, "--studio-bars-h:calc(1 * var(--studio-bar-unit"
    assert_includes html, "Test Environment"
  end

  test "two bars publish a two-unit height" do
    html = render_stack(impersonated_user: StubUser.new, admin_user: StubUser.new,
                        stop_path: "/impersonation")

    assert_includes html, "--studio-bars-h:calc(2 * var(--studio-bar-unit"
    assert_includes html, "Test Environment"
    assert_includes html, "admin impersonation"
  end

  # The count is the point: a hardcoded offset would be wrong the moment an admin
  # impersonates, which is exactly why this is a stack and not a nested banner.
  test "the published height differs between one bar and two" do
    one = render_stack
    two = render_stack(impersonated_user: StubUser.new, admin_user: StubUser.new,
                       stop_path: "/impersonation")

    refute_equal published_height(one), published_height(two)
  end

  # ── C. no bars → nothing published ───────────────────────────

  test "renders nothing at all in real production" do
    html = with_rails_env("production") { render_stack }

    assert_equal "", html.strip
  end

  test "a preview render publishes no height and no bars" do
    html = render_stack(preview: true)

    assert_equal "", html.strip
  end

  # ── B + C. the navbar consumes the offset, and degrades to top:0 ──

  test "the navbar offsets by the published property, not by a bar name" do
    nav = render_navbar

    assert_includes nav, "top:var(--studio-bars-h, 0px)"
    # It must not branch on which bars exist — that is the coupling this replaces.
    refute_includes nav, "studio/banners/environment"
    refute_includes nav, "impersonation"
  end

  test "an app with no stack is unaffected — the fallback is zero" do
    nav = render_navbar

    # With no :root property published, var(...) resolves to the 0px fallback,
    # which is what `top-0` did before. Adoption is opt-in, not forced.
    assert_includes nav, "0px"
  end

  # ── D. exactly one pinned header ─────────────────────────────

  # The invariant is NEVER MORE THAN ONE. Zero is legitimate — the pin only
  # renders when the app opts into Studio.smooth_load — so asserting "exactly 1"
  # unconditionally was the test being wrong, not the code.
  test "the stack adds no pinned header of its own" do
    combined = render_stack + render_navbar

    assert_equal 0, combined.scan("vt-pinned-header").length,
                 "smooth_load is off here, so nothing should be pinned"
  end

  test "with smooth_load on, the page still has exactly one pinned header" do
    combined = with_smooth_load { render_stack + render_navbar }

    assert_equal 1, combined.scan("vt-pinned-header").length,
                 "exactly one vt-pinned-header per page — a duplicate silently " \
                 "disables every view transition on that page"
    # And it is the NAVBAR that carries it, not the stack: the stack must never
    # become a second candidate as bars are added.
    assert_equal 0, with_smooth_load { render_stack }.scan("vt-pinned-header").length
  end

  private

  def with_smooth_load
    original = Studio.smooth_load
    Studio.smooth_load = true
    yield
  ensure
    Studio.smooth_load = original
  end

  def published_height(html)
    html[/--studio-bars-h:[^}]+/]
  end

  def with_rails_env(name)
    original = Studio.method(:rails_env_name)
    Studio.define_singleton_method(:rails_env_name) { name }
    yield
  ensure
    Studio.define_singleton_method(:rails_env_name, original)
  end

  def view
    v = ActionView::Base.with_empty_template_cache.with_view_paths(
      [File.join(ENGINE_ROOT, "app/views")]
    )
    v.extend(StudioEmailDeliveryHelper)
    req = StubRequest.new
    v.define_singleton_method(:request) { req }
    v
  end

  def render_stack(**locals)
    view.render(partial: "studio/banners/stack", locals: locals).to_s
  end

  def render_navbar
    v = view
    user = StubUser.new
    v.define_singleton_method(:logged_in?) { false }
    v.define_singleton_method(:current_user) { user }
    %i[logout_path login_path signup_path root_path].each do |m|
      v.define_singleton_method(m) { "/" }
    end
    v.render(partial: "layouts/navbar").to_s
  end
end
