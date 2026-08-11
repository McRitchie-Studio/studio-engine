# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"

# [component] The bar stack — bars render as the navbar's SIBLING, and the LAYOUT
# reserves their space. Nothing measures anything.
#
# WHAT THIS TIER CAN AND CANNOT PROVE — read before trusting a green run.
# The defect these tests were rewritten for (fix-navbar-offset-jump) was a
# PAINT-TIME one: the header rendered correctly and then MOVED, because its
# sticky `top` was a custom property published twice — once as a server-side
# estimate, once by a ResizeObserver measuring the real height — and the two
# disagreed. The previous version of this file asserted "exactly one pinned
# header" and was CORRECT: one header is rendered. A markup assertion cannot see
# a position that changes after first paint, which is why the bug reached a
# human's eye instead of CI.
#
# This is still a markup tier. It cannot observe a paint, a reflow, a webfont
# swap, or a view transition — the engine has no browser tier to run one in.
# What it CAN do is assert the PROPERTY that makes the jump unreachable: the
# header's sticky offset is a static value that only CSS sets, and the stack
# ships no runtime code that could ever change it. A test that pins a spelling
# would not survive a rename; these pin the structure — no script element, no
# style element, no positioned stack, an offset with no var()/calc() in it.
# Verified separately in a real Chromium (headless, 390x780): with the bar's
# height changed under a PINNED header, the old markup moved the header 8px and
# its computed top went 41px→49px; the new markup moved it 0px with a computed
# top constant at 0px.
#
# The contract, in the order it matters:
#   A. The header's sticky offset is STATIC. No custom property, no measurement,
#      nothing a script can rewrite between two paints.
#   B. The stack contributes MARKUP ONLY — no script, no style, no published
#      property — and sits in normal flow above the header, which is what
#      reserves the space.
#   C. No bars → nothing renders, and the navbar behaves exactly as `top-0`
#      always did. An app that hasn't adopted is unaffected.
#   D. EXACTLY ONE vt-pinned-header per page. A duplicate view-transition-name
#      silently disables every transition on the page — this codebase has been
#      bitten by it, so it is asserted rather than hoped. (Necessary, and — see
#      above — nowhere near sufficient on its own.)
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

  # ── A. the header's sticky offset is STATIC ──────────────────
  #
  # This is the whole fix. A `top` that only a stylesheet can set cannot differ
  # between two paints, so there is no frame in which the header is in the wrong
  # place — no estimate-then-measurement, no webfont reflow moving pinned chrome,
  # and no view transition compositing an outgoing and an incoming header at two
  # different tops (which is what drew the navbar TWICE in the bug report).

  test "the pinned header declares a sticky offset at all" do
    header = header_element(render_navbar)

    assert_includes header["class"].to_s.split, "sticky",
                    "the header must pin; the scroll-collapse behaviour depends on it"
    refute_nil declared_top(header),
               "position:sticky with no top offset NEVER pins — the header would " \
               "scroll away entirely. Deleting the offset is a silent regression, " \
               "so the presence of one is asserted separately from its value."
  end

  test "the header's sticky offset is a constant no runtime code can rewrite" do
    offset = declared_top(header_element(render_navbar))

    # The property, not the spelling: whatever expresses the offset, it must not
    # be able to resolve to two different values across two paints.
    refute_match(/var\(|calc\(|env\(|attr\(/, offset,
                 "the header's sticky top must be a CONSTANT. A custom property " \
                 "is exactly the defect: --studio-bars-h painted at a server " \
                 "estimate, then moved when a ResizeObserver measured the real " \
                 "bar height, and moved again on a webfont swap.")
    assert_match(/\A(top-)?0(px|rem|em|%)?\z/, offset,
                 "the offset must be ZERO. The bars are the header's sibling in " \
                 "normal flow, so they already occupy their own height above it " \
                 "and there is nothing left to offset by.")
  end

  test "the whole rendered chrome publishes no offset property" do
    chrome = render_stack + render_navbar

    # The consumer contract by name: mcritchie-studio's hand-written header in
    # app/views/layouts/application.html.erb still spells
    # `top:var(--studio-bars-h, 0px)`. Because nothing publishes the property any
    # more, that resolves to its 0px fallback — which is precisely the position
    # this layout wants. The host needs no coordinated change; it self-heals.
    refute_includes chrome, "--studio-bars-h",
                    "publishing this again re-arms the jump for every app whose " \
                    "header still reads it"
    refute_includes chrome, "--studio-bar-unit",
                    "the estimate token is the server half of the two disagreeing " \
                    "sources; it has no consumer left"
  end

  # ── B. the stack is markup, and only markup ──────────────────

  test "the stack ships no runtime code that could move the header" do
    html = render_stack
    frag = Nokogiri::HTML5.fragment(html)

    # Structural, so a rename cannot smuggle a publisher back in: any script that
    # republishes a height needs a script element to live in.
    assert_equal 0, frag.css("script").length,
                 "the stack must contribute markup only — a script here is how the " \
                 "header's position became a moving target"
    assert_equal 0, frag.css("style").length,
                 "a <style> here is the server-side ESTIMATE returning; it is the " \
                 "half of the old design that was wrong on first paint"
    refute_match(/documentElement\.style/, html,
                 "nothing in the stack may write to the root element's inline style")
    refute_match(/ResizeObserver|getBoundingClientRect/, html,
                 "measuring the stack is what produced a second, disagreeing value")
  end

  test "the stack sits in normal flow, which is what reserves the space" do
    stack = Nokogiri::HTML5.fragment(render_stack).at_css("[data-studio-bar-stack]")

    refute_nil stack, "the stack must render a real element carrying the hook attribute"
    classes = stack["class"].to_s.split

    # A pinned stack is the offset variable coming back: two pinned siblings of
    # unknown height cannot stack in CSS alone, so one would have to MEASURE the
    # other. Normal flow is the entire reason no measurement is needed.
    %w[sticky fixed absolute].each do |positioning|
      refute_includes classes, positioning,
                      "a #{positioning} stack stops reserving layout space, and the " \
                      "navbar would need a measured offset again"
    end
    refute(classes.any? { |c| c.start_with?("top-") },
           "a top offset on a normal-flow stack does nothing but signal a pin")
    refute(classes.any? { |c| c.start_with?("z-") },
           "the stack must not outrank the pinned header: it scrolls up BEHIND it")
  end

  test "the bars render above the header, not below it" do
    combined = Nokogiri::HTML5.fragment(render_stack + render_navbar)
    order = combined.css("[data-studio-bar-stack], header").map(&:name)

    # Normal flow only reserves space for what comes FIRST. Rendered after the
    # header, the same bars would push the page content down and leave the header
    # overlapping them.
    assert_equal %w[div header], order,
                 "the stack must precede the header in document order"
  end

  test "every rendered bar is inside the stack element" do
    html = render_stack(impersonated_user: StubUser.new, admin_user: StubUser.new,
                        stop_path: "/impersonation")
    stack = Nokogiri::HTML5.fragment(html).at_css("[data-studio-bar-stack]")

    # The stack's own height IS the reservation now, so a bar rendered outside it
    # would still take room but would not be part of the block the layout counts
    # on — and nothing would be measuring to catch the discrepancy.
    assert_includes stack.text, "Test Environment"
    assert_includes stack.text, "admin impersonation"
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

  # ── C. the navbar stays ignorant of which bars rendered ──────

  test "the navbar never learns which bars rendered" do
    nav = render_navbar

    # It must not branch on which bars exist — that is the coupling this replaces.
    refute_includes nav, "studio/banners/environment"
    refute_includes nav, "impersonation"
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

  def header_element(html)
    header = Nokogiri::HTML5.fragment(html).at_css("header")
    refute_nil header, "the navbar must render a header element"
    header
  end

  # Whatever the header uses to express its sticky offset, normalised to one
  # string — an inline `top:` declaration if there is one, otherwise the Tailwind
  # `top-*` class. Deliberately NOT a grep for a known spelling: the assertions
  # above are about what the offset can RESOLVE to, so they need the real source
  # of the value wherever the markup happens to put it. Returns nil when the
  # header declares no offset at all, which is itself a failure worth naming
  # (position:sticky with top:auto never pins).
  def declared_top(header)
    inline = header["style"].to_s[/(?:\A|;)\s*top\s*:\s*([^;]+)/, 1]
    return inline.strip if inline.present?

    header["class"].to_s.split.find { |token| token.match?(/\Atop-/) }
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
