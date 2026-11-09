# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"

# [unit] engine.css, the cascade carousel (style: :cascade). The e2e lane reads the
# laid-out stack in Chromium (e2e/carousel_cascade.spec.js); this pins the rules the
# controller relies on: each data-cascade-step the controller writes has a place,
# a narrow region and visible: 3 reach one step, reduced motion lays the stack flat
# with no glide, and a failed controller leaves a scrolling row.
class CarouselCascadeCssTest < Minitest::Test
  CSS = File.read(File.expand_path("../../app/assets/tailwind/studio_engine/engine.css", __dir__))
  BLOCK = CSS[/^@utility carousel-cascade \{\n.*?\n\}\n/m]
  REDUCED = /  @media \(prefers-reduced-motion: reduce\) \{\n.*?\n  \}\n/m
  NARROW = /  @container \(width < 36rem\) \{\n.*?\n  \}\n/m

  def test_the_utility_exists
    refute_nil BLOCK, "engine.css defines @utility carousel-cascade"
  end

  def test_every_step_the_controller_writes_has_a_place
    %w[-2 -1 1 2 before after].each do |step|
      assert_includes BLOCK, %([data-cascade-step="#{step}"]), "step #{step} is laid out"
    end
    assert_match(/before.*after.*\{\s*--cascade-d: 3;\s*opacity: 0;\s*visibility: hidden;/m, BLOCK, "past the window is hidden")
  end

  def test_the_stack_is_3d_and_the_open_slide_on_top
    assert_includes BLOCK, "perspective: 1400px"
    assert_includes BLOCK, "translateZ(calc(var(--cascade-d) * -1 * var(--cascade-depth)))"
    assert_includes BLOCK, "z-index: calc(10 - var(--cascade-d))"
  end

  def test_a_narrow_region_and_visible_three_reach_one_step
    narrow = BLOCK.scan(NARROW)
    assert_equal 2, narrow.size, "the narrow region sets the reach and hides the second step"
    assert_includes narrow.first, "--carousel-cascade-reach: 1"
    assert_includes narrow.last, %([data-cascade-step="2"])
    assert_match(/&\[data-carousel-visible="3"\] > \.carousel-track \{\s*--carousel-cascade-reach: 1;/, BLOCK)
  end

  # A phone's side cards run past the track: its edges fade them (a mask), on the
  # narrow region only, so the wide stack keeps no mask and nothing is cut hard.
  def test_a_narrow_region_fades_its_edges
    narrow = BLOCK.scan(NARROW).first
    fade = "linear-gradient(to right, transparent, #000 var(--carousel-cascade-fade, 10%), #000 calc(100% - var(--carousel-cascade-fade, 10%)), transparent)"
    assert_includes narrow, "-webkit-mask-image: #{fade}"
    assert_includes narrow, "mask-image: #{fade}"
    wide = BLOCK[/^  & > \.carousel-track \{\n.*?\n  \}\n/m]
    assert_match(/mask-image: none;/, wide, "the wide stack has no mask")
    assert_match(/&\[data-studio-controller-failed\] > \.carousel-track \{[^}]*mask-image: none;/, BLOCK, "the fallback row drops it")
  end

  def test_reduced_motion_lays_it_flat_with_no_glide
    reduced = BLOCK[REDUCED]
    refute_nil reduced
    refute_match(/translateZ|rotateY|scale\(/, reduced, "no depth, turn or scale under reduced motion")
    assert_includes reduced, "transition: none !important"
    assert_includes reduced, "animation: none !important"
  end

  def test_a_failed_controller_leaves_a_scrolling_row
    assert_match(/&\[data-studio-controller-failed\] > \.carousel-track \{[^}]*overflow-x: auto;/, BLOCK)
    assert_match(/&\[data-studio-controller-failed\] > \.carousel-track > \.carousel-slide \{[^}]*visibility: visible;/, BLOCK)
  end
end
