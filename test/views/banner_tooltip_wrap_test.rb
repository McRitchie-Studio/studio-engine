# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

# [unit] The banner chip's tooltip must declare its OWN white-space.
#
# THE DEFECT THIS PINS. The tooltip sizes itself `max-width:260px;
# width:max-content` while sitting inside the chip, whose base class carries
# `whitespace-nowrap`. `white-space` INHERITS, so with no declaration of its own
# the tooltip kept an unbreakable line at full width while the cap clamped the
# box: 263px of line in a 260px box. Anchored `right:0` near the viewport edge,
# that surplus ran off the page and into `document.scrollWidth`.
#
# WHY IT HID FOR SO LONG. It only bites where the rendered face is WIDER than
# Montserrat. Since the webfont was vendored with `font-display: optional`,
# "the page renders in the fallback face" is a normal, supported state — and
# Linux resolves that fallback wider than macOS does. So it was invisible on
# developer machines and reddened both consumers' navbar containment specs in
# CI (turf-monster and mcritchie-studio, documentOverflow 4 against a cap of 1).
#
# THE ASSERTION IS ON THE INLINE STYLE, deliberately. Every other property on
# this element is inlined for the same reason: a utility class only exists in a
# consumer's stylesheet if that consumer's Tailwind build scanned this engine
# partial, which is not guaranteed. The class is kept as the idiomatic twin;
# the inline declaration is the one that always ships.
class BannerTooltipWrapTest < ActiveSupport::TestCase
  PARTIAL = Studio::Engine.root.join("app/views/studio/banners/_button.html.erb")

  def tooltip_tag
    markup = PARTIAL.read
    open = markup.index("<span data-studio-banner-tooltip")
    assert open, "the tooltip span is gone from the partial — this guard is measuring nothing"

    markup[open...markup.index(">", open)]
  end

  test "the tooltip declares white-space in its inline style" do
    assert_includes tooltip_tag, "white-space:normal",
                    "the tooltip must declare its own white-space; without it the chip's " \
                    "whitespace-nowrap INHERITS and an unbreakable line overflows the 260px cap"
  end

  test "the tooltip still caps its width, which is what makes the wrap load-bearing" do
    tag = tooltip_tag

    assert_includes tag, "max-width:260px", "the cap is half the contract"
    assert_includes tag, "width:max-content", "without max-content the box would not hug its text"
  end

  test "the chip itself still nowraps, so the inherited value is the real hazard" do
    assert_includes PARTIAL.read, "whitespace-nowrap",
                    "if the chip stopped nowrapping, this guard's premise changed — re-read it"
  end
end
