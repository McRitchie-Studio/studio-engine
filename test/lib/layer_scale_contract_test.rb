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
    --z-banner --z-toast-blur --z-toast --z-tooltip
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

  # THE THIRD DEFECT, AND THE ONE THE TEST ABOVE COULD NOT SEE.
  #
  # "Above the modal" was the whole question the first time, so that is all the
  # assertion above asks — and it stayed GREEN for the entire time the toast was
  # unusable, because --z-toast > --z-modal was true the whole way through. Both
  # tiers clearing the modal says nothing about which of THEM wins, and they land
  # on the same pixels: #toast-container is fixed at top 0 with 1rem of padding
  # (layouts/studio/_flash), and `body.modal-open` lifts the bar stack to sticky
  # top 0 at --z-banner, so on a 1440x900 viewport the bars own y0-47 and the
  # toast card starts at y16 — with its Dismiss button in the overlap.
  #
  # MEASURED on mcritchie-studio, dark and light, 1440x900 and 390x844, scrollY 0
  # and 900: with a modal open, elementFromPoint at the Dismiss button returned
  # the BANNER div and a real click left the toast count at 1; with no modal it
  # returned the button's SVG and the count dropped to 0. A toast carrying
  # buttons gets `duration: 0`, so that button is its ONLY exit — the toast was
  # stuck on the page permanently.
  #
  # The order is the fix and it is a semantic one: a toast is transient and
  # demands interaction, a banner is persistent chrome. e2e/toast_over_banner
  # asserts the same property where the defect actually lives — on a real click.
  test "a toast outranks the environment banner it shares the corner with" do
    %w[--z-toast --z-toast-blur].each do |above|
      assert tokens.fetch(above) > tokens.fetch("--z-banner"),
             "#{above} (#{tokens.fetch(above)}) must sit above --z-banner " \
             "(#{tokens.fetch("--z-banner")}). With a modal open the bar stack is " \
             "lifted to --z-banner at top 0, over the same pixels the toast's " \
             "Dismiss button occupies — and a toast with buttons never auto-" \
             "dismisses, so covering that button strands the toast forever."
    end

    assert_equal 1, tokens.fetch("--z-toast") - tokens.fetch("--z-toast-blur"),
                 "the frosted halo must sit DIRECTLY under its own toast. Any tier " \
                 "that fits between them paints inside the toast's own visual unit " \
                 "— the banner did exactly that in the first draft of this fix."
  end

  # THE LIFT DEPENDS ON A WORKING SCROLL LOCK, and this gem's was inert wherever
  # its own link sidebar shipped. Measured on a consumer, 2026-08-27: with a
  # modal open a real wheel gesture scrolled the page 600px → 1000px and the
  # sticky header slid away with it.
  #
  # `body { overflow: hidden }` locks the viewport only while it PROPAGATES to
  # it, and it propagates only while `html` is `overflow: visible`. The link
  # sidebar sets `html { overflow-x: clip }` — right on its own terms — which
  # ends the propagation and turns BODY into a scroll container pinned at
  # scrollTop 0. Every position:sticky child of body then has a scrollport that
  # never moves.
  #
  # Every place this gem writes the lock has to write it the same way, or a
  # consumer picks the broken one by rendering a different host.
  test "every scroll lock in the gem locks html, not body" do
    {
      "app/views/studio/modals/_host.html.erb" => "the default modal host",
      "app/views/studio/modals/_scoped_host.html.erb" => "the scoped modal host",
      "app/assets/tailwind/studio_engine/engine-motion.css" => "the motion layer",
    }.each do |file, what|
      css = File.read(File.join(ROOT, file)).gsub(%r{/\*.*?\*/}m, " ")

      assert_match(/html:has\(body\.modal-open\)\s*\{[^}]*overflow:\s*hidden/, css,
                   "#{what} must lock html — on body the lock stops propagating the " \
                   "moment anything sets overflow on html, and this gem's own link " \
                   "sidebar does exactly that")
      refute_match(/(?<!:has\()body\.modal-open\s*\{[^}]*overflow:\s*hidden/, css,
                   "#{what} still locks body, which makes it a scroll container that " \
                   "never scrolls and strands every sticky child of it")
    end
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

    # A LEVEL ALONE IS NOT THE FIX. The first cut of this rule used `position:
    # relative`, which escapes z-index:auto and looks right at the top of a page
    # — and leaves the bars off screen for a reader who has scrolled, which is
    # every reader who did anything before opening a modal. Measured on a
    # consumer board at scrollY 900: relative put the stack at top -900, sticky
    # at top 0. `fixed` also pins but pulls it out of flow, and the page jumps
    # up by the bars' height.
    rule = css[/body\.modal-open\s+\.studio-bar-stack.*?\{(.*?)\}/m]
    assert_match(/position:\s*sticky/, rule.to_s,
                 "a scrolled reader never sees a bar that only got a z-index — pin it")
    assert_match(/top:\s*0/, rule.to_s, "sticky without a top offset never pins")
    refute_match(/position:\s*fixed/, rule.to_s,
                 "fixed pulls the bars out of flow and the page jumps by their height")

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
