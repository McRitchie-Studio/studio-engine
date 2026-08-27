# frozen_string_literal: true

require_relative "../test_helper"

# [unit] The shared layer scale — the ONE stacking order every Studio app gets
# from this gem (engine.css, `-- Layer scale`).
#
# THE DEFECT THIS PINS. On a QA phone, turf-monster's docked "Hold to Confirm"
# bar painted OVER an open sign-in modal, and the DEV MODE banner dimmed behind
# the same backdrop. Neither was a bug in either component: the bar carried an
# inline `z-index:9999`, the modal host carried `z-[120]`, and nothing anywhere
# said which should win. An audit of the two repos found 21 distinct levels,
# three layers tied at 130, two tied at 10000, and 9,798 unclaimed values
# between the modal and the bar.
#
# So the scale is a CONTRACT, and this test is what makes it one. It asserts the
# two things a reviewer cannot see by reading a diff:
#
#   1. the ORDER holds — the tiers ascend, and the specific inversions that
#      produced the two defects are named individually, so a future edit that
#      re-introduces either goes red here rather than on someone's phone;
#   2. nothing in this gem paints at a bare blocking number any more — a new
#      `z-[9999]` is refused at the point it is written, which is the only
#      moment it is cheap to refuse.
#
# It deliberately does NOT pin the integers. Tiers may be renumbered; the order
# and the naming are the contract.
class LayerScaleContractTest < ActiveSupport::TestCase
  ROOT = File.expand_path("../..", __dir__)

  # The published ladder, lowest first. Adding a tier means adding it here.
  ORDER = %w[
    --z-behind --z-base --z-content --z-raised --z-sticky --z-panel --z-dropdown
    --z-docked --z-nav --z-drawer --z-modal --z-lightbox --z-alert
    --z-toast-blur --z-toast --z-banner --z-tooltip
  ].freeze

  ENGINE_CSS = File.join(ROOT, "app/assets/tailwind/studio_engine/engine.css")

  # Every file that can paint a layer. Sprockets CSS, the Tailwind engine sheet,
  # and the views — the arbitrary `z-[...]` utilities live in markup.
  PAINTING_FILES = (
    Dir[File.join(ROOT, "app/assets/tailwind/studio_engine/*.css")] +
    Dir[File.join(ROOT, "app/assets/stylesheets/**/*.css")] +
    Dir[File.join(ROOT, "app/views/**/*.erb")]
  ).sort.freeze

  # A blocking layer. Below this, the tiers coincide with Tailwind's own
  # z-10..z-50 utilities and a bare number is still readable.
  BLOCKS = 100

  def tokens
    @tokens ||= begin
      css = File.read(ENGINE_CSS)
      root = css[/^:root \{(.*?)^\}/m]
      refute_nil root, "engine.css has no :root block — the layer scale is gone"
      root.scan(/(--z-[a-z-]+):\s*(-?\d+);/).to_h { |name, value| [name, value.to_i] }
    end
  end

  # Comments are prose. This very test's docstring names `z-index:9999`, and so
  # does the scale's own header comment — scanning them would make documenting
  # the defect impossible, which is the opposite of the point.
  def code_of(path)
    src = File.read(path)
    src = src.gsub(%r{/\*.*?\*/}m, " ")   # CSS comments
    src = src.gsub(/<%#.*?%>/m, " ")      # ERB comments
    src = src.gsub(/<!--.*?-->/m, " ")    # HTML comments
    src.gsub(/var\([^)]*\)/, "var()")     # token reads, fallbacks included
  end

  test "every published tier is defined exactly once" do
    assert_equal ORDER.sort, tokens.keys.sort,
                 "engine.css :root and this test's ORDER disagree about the tiers"
  end

  test "the ladder ascends" do
    values = ORDER.map { |t| [t, tokens.fetch(t)] }
    values.each_cons(2) do |(lower, lv), (higher, hv)|
      assert hv > lv, "#{higher} (#{hv}) must sit above #{lower} (#{lv})"
    end
  end

  # The two defects, named. These are implied by "the ladder ascends", and that
  # is exactly why they are spelled out: a reorder of ORDER would keep that test
  # green while putting a bar back over a modal.
  test "nothing docked, pinned or drawered can cover a modal" do
    %w[--z-docked --z-nav --z-drawer].each do |below|
      assert tokens.fetch(below) < tokens.fetch("--z-modal"),
             "#{below} must stay below --z-modal — a modal is the active task"
    end
  end

  test "the environment banner and toasts stay reachable over a modal" do
    %w[--z-toast --z-banner].each do |above|
      assert tokens.fetch(above) > tokens.fetch("--z-modal"),
             "#{above} must stay above --z-modal or a QA session cannot reach it"
    end
    assert tokens.fetch("--z-tooltip") > tokens.fetch("--z-banner"),
           "a banner tooltip must clear the banner it hangs off"
  end

  test "no engine layer paints at a bare blocking number" do
    offenders = PAINTING_FILES.flat_map do |path|
      code = code_of(path)
      hits  = code.scan(/z-index:\s*(\d+)/).flatten
      hits += code.scan(/\bz-\[(\d+)\]/).flatten
      hits.map(&:to_i).select { |n| n >= BLOCKS }
           .map { |n| "#{path.delete_prefix(ROOT + '/')} → #{n}" }
    end
    assert_empty offenders,
                 "use a --z-* tier from engine.css, not a bare number:\n  " \
                 "#{offenders.join("\n  ")}"
  end

  # The modal-open lift is a selector in engine.css pointing at classes emitted
  # in two OTHER files. Rename either class and the banner silently goes back to
  # dimming behind the backdrop, with nothing red anywhere. This is that guard.
  test "the modal-open banner lift still finds its hooks" do
    css = File.read(ENGINE_CSS)
    assert_match(/body\.modal-open\s+\.studio-bar-stack/, css,
                 "engine.css lost the bar-stack half of the modal-open lift")
    assert_match(/body\.modal-open\s+\.studio-app-banner/, css,
                 "engine.css lost the app-banner half of the modal-open lift")

    # code_of, not File.read: both files NAME the hook in a comment explaining
    # what it is for, so a bare substring match stays green through a rename —
    # measured, on the first draft of this test.
    { "_stack.html.erb" => "studio-bar-stack",
      "_app_banner.html.erb" => "studio-app-banner" }.each do |file, hook|
      markup = code_of(File.join(ROOT, "app/views/studio/banners", file))
      assert_match(/class="[^"]*\b#{Regexp.escape(hook)}\b[^"]*"/, markup,
                   "banners/#{file} no longer EMITS #{hook}, the class the lift selects")
    end
  end
end
