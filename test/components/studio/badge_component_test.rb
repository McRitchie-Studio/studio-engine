# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "view_component/test_case"

# [unit] Studio::BadgeComponent renders every variant from its declared inputs:
# each status tone, each legacy scheme, the neutral default, an unknown scheme,
# the board-count hook, and the two inputs it refuses. The components/badge
# partial is held to the component too, so the wrapper renders what the partial
# rendered before it became one.
class Studio::BadgeComponentTest < ViewComponent::TestCase
  # render_inline returns the rendered fragment; the badge is its one span.
  def render_inline(component)
    @fragment = super
  end

  def badge
    spans = @fragment.css("span.badge")
    assert_equal 1, spans.size, "expected one span.badge in #{@fragment.to_html}"
    spans.first
  end

  def classes
    badge[:class].split
  end

  test "each status tone renders .badge, its whole class string, and the text" do
    Studio::BadgeComponent::TONES.each do |tone, tone_classes|
      render_inline(Studio::BadgeComponent.new(text: "Passed", tone: tone))

      assert_equal ["badge", *tone_classes.split], classes, tone.inspect
      assert_equal "Passed", badge.text
    end
  end

  test "a tone may be a string, as a status word arrives from a view" do
    render_inline(Studio::BadgeComponent.new(text: "x", tone: "danger"))

    assert_equal ["badge", *Studio::BadgeComponent::TONES[:danger].split], classes
  end

  # The hub's status_tone chip for each role, minus the `border` width .badge
  # already sets. Written out here, not read from the hub, so a change on
  # either side shows up as a diff someone has to agree to.
  test "the tones are the hub's status_tone chips" do
    hub_chips = {
      success: "bg-success/10 text-success-ink border border-success/40",
      warning: "bg-warning/10 text-warning-ink border border-warning/40",
      danger: "bg-danger/10 text-danger-ink border border-danger/40",
      primary: "bg-primary/10 text-heading border border-primary/40",
      muted: "bg-surface-alt text-muted border border-subtle"
    }
    assert_equal hub_chips.keys, Studio::BadgeComponent::TONES.keys
    hub_chips.each do |role, chip|
      assert_equal chip.split - ["border"], Studio::BadgeComponent::TONES.fetch(role).split, role.inspect
    end
  end

  test "each scheme renders its classes" do
    Studio::BadgeComponent::SCHEMES.each do |scheme, scheme_classes|
      render_inline(Studio::BadgeComponent.new(text: scheme, scheme: scheme))

      assert_equal ["badge", *scheme_classes.split], classes, scheme
    end
  end

  test "no tone and no scheme renders the neutral scheme" do
    render_inline(Studio::BadgeComponent.new(text: "plain"))

    assert_equal ["badge", *Studio::BadgeComponent::SCHEMES["neutral"].split], classes
  end

  test "an unknown scheme renders the fallback, as the partial did" do
    render_inline(Studio::BadgeComponent.new(text: "?", scheme: "chartreuse"))

    assert_equal ["badge", *Studio::BadgeComponent::FALLBACK.split], classes
  end

  test "data_board_count wires the studio/board count target, and only when given" do
    render_inline(Studio::BadgeComponent.new(text: "4", scheme: "stage-fresh", data_board_count: "designed"))
    assert_equal "designed", badge["data-board-count"]

    render_inline(Studio::BadgeComponent.new(text: "4"))
    assert_nil badge["data-board-count"]
  end

  test "the text is escaped" do
    render_inline(Studio::BadgeComponent.new(text: "<b>x</b>"))

    assert_equal "<b>x</b>", badge.text
    assert_empty @fragment.css("span.badge b")
  end

  test "tone and scheme together is refused" do
    error = assert_raises(ArgumentError) { Studio::BadgeComponent.new(text: "x", tone: :success, scheme: "success") }
    assert_match(/not both/, error.message)
  end

  test "an unknown tone is refused, naming the five" do
    error = assert_raises(ArgumentError) { Studio::BadgeComponent.new(text: "x", tone: :mint) }
    assert_match(/success, warning, danger, primary, muted/, error.message)
  end

  test "text is required" do
    assert_raises(ArgumentError) { Studio::BadgeComponent.new(tone: :success) }
  end

  # --- the partial, now a wrapper ----------------------------------------------

  # What the partial rendered before it became a wrapper, for each of its
  # callers' shapes. The markup is fixed here so the wrapper is held to it.
  PARTIAL_BEFORE = {
    { text: "3", scheme: "violet" } =>
      %(<span class="badge bg-violet/10 text-violet border-violet/30">3</span>),
    { text: "studio-engine" } =>
      %(<span class="badge bg-surface-alt text-secondary border-subtle">studio-engine</span>),
    { text: "7", scheme: "stage-closed", data_board_count: "closed" } =>
      %(<span class="badge bg-gray-500/10 text-gray-400 border-gray-500/30" data-board-count="closed">7</span>),
    { text: "?", scheme: "nope" } =>
      %(<span class="badge bg-surface-alt text-body border-subtle">?</span>)
  }.freeze

  test "the components/badge partial renders what it rendered before" do
    PARTIAL_BEFORE.each do |locals, before|
      html = ActionController::Base.render(partial: "components/badge", locals: locals)

      assert_equal before, html.strip, locals.inspect
    end
  end

  test "the partial still refuses an unknown local" do
    assert_raises(ActionView::Template::Error) do
      ActionController::Base.render(partial: "components/badge", locals: { text: "x", tone: :success })
    end
  end
end
