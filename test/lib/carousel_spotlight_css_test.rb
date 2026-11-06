# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"

# [unit] engine.css, the spotlight carousel's two paths. The e2e lane runs Chromium,
# which takes the scroll-driven path; e2e/carousel_spotlight.spec.js also switches
# the animation off to read the fallback there. This pins the SPLIT itself: the
# animation only behind the scroll-timeline check, the controller-marked fallback
# outside it, and reduced motion dropping the scale and the grey in both.
class CarouselSpotlightCssTest < Minitest::Test
  CSS = File.read(File.expand_path("../../app/assets/tailwind/studio_engine/engine.css", __dir__))
  BLOCK = CSS[/^@utility carousel-spotlight \{\n.*?\n\}\n/m]
  SUPPORTS = /  @supports \(animation-timeline: view\(\)\)[^{]*\{\n.*?\n  \}\n/m
  REDUCED = /  @media \(prefers-reduced-motion: reduce\) \{\n.*?\n  \}\n/m

  def test_the_utility_exists
    refute_nil BLOCK, "engine.css defines @utility carousel-spotlight"
  end

  def test_the_scroll_driven_animation_sits_only_behind_the_check
    supported = BLOCK[SUPPORTS]
    refute_nil supported, "the scroll-driven path sits behind @supports (animation-timeline: view())"
    assert_includes supported, "animation-timeline: --carousel-slide"
    assert_includes supported, "animation: carousel-spotlight linear both"

    outside = BLOCK.sub(SUPPORTS, "")
    refute_includes outside, "animation-timeline", "a timeline outside the check paints nothing in Firefox"
    assert_includes outside, "view-timeline: --carousel-slide inline", "each slide names its own timeline"
  end

  def test_the_fallback_styles_the_controllers_mark_outside_the_check
    outside = BLOCK.sub(SUPPORTS, "").sub(REDUCED, "")
    rule = outside[/&\[data-carousel-ready\] \.carousel-slide:not\(\[data-current\]\) \.carousel-spotlight-body \{[^}]*\}/]

    refute_nil rule, "a browser without view timelines styles the slides the controller did not mark"
    assert_includes rule, "scale: var(--carousel-spot-scale)"
    assert_includes rule, "filter: grayscale(1)"
    assert_match(/transition: scale 300ms ease/, outside)
  end

  def test_reduced_motion_drops_the_animation_and_the_scale_in_both_paths
    reduced = BLOCK[REDUCED]
    refute_nil reduced

    assert_includes reduced, "animation: none !important", "the scroll-driven path stops"
    assert_includes reduced, "transition: none !important", "the fallback jumps"
    fallback = reduced[/\.carousel-slide:not\(\[data-current\]\) \.carousel-spotlight-body \{[^}]*\}/]
    refute_nil fallback
    assert_includes fallback, "scale: none"
    assert_includes fallback, "filter: none"
    refute_includes fallback, "opacity", "the neighbours stay dimmed"
  end

  def test_the_keyframes_peak_at_the_centre
    frames = CSS[/@keyframes carousel-spotlight \{\n.*?\n\}\n/m]
    refute_nil frames
    assert_match(/0%, 100% \{[^}]*scale: var\(--carousel-spot-scale\)/m, frames)
    assert_match(/50% \{[^}]*scale: 1;/m, frames)
  end
end
