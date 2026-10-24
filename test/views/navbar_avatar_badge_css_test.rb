# frozen_string_literal: true

require "test_helper"

# [unit] The stylesheet half of Studio.navbar_avatar_badge, in engine.css. The
# partial renders a bare [data-nav-avatar-badge] seat after the account
# control; these rules alone take it out of flow, seat it over the avatar, lift
# it above, and keep it on the avatar through the one-row size and the scroll
# timeline. Each assertion spans a selector AND its declaration.
class NavbarAvatarBadgeCssTest < Minitest::Test
  CSS = File.read(File.expand_path("../../app/assets/tailwind/studio_engine/engine.css", __dir__)).freeze

  def seat_rule = CSS[/^\s*\[data-nav-avatar-badge\] \{[^}]*\}/]

  def test_the_seat_is_out_of_flow_over_the_avatar_and_above_it
    rule = seat_rule

    refute_nil rule, "no [data-nav-avatar-badge] rule in engine.css"
    assert_includes rule, "position: absolute"
    assert_includes rule, "right: 0"
    assert_includes rule, "margin-block: auto"
    assert_includes rule, "width: 2rem"
    assert_includes rule, "height: 2rem"
    assert_includes rule, "z-index: 20"
    assert_includes rule, "pointer-events: none", "the avatar under the seat keeps its clicks"
  end

  def test_the_row_is_the_seat_s_containing_block
    assert_match(/:has\(> \[data-nav-avatar-badge\]\) \{ position: relative; \}/, CSS)
  end

  def test_the_badge_rides_the_upper_left_corner_and_takes_the_pointer
    rule = CSS[/\[data-nav-avatar-badge\] > \* \{[^}]*\}/]

    refute_nil rule
    assert_includes rule, "left: -0.5rem"
    assert_includes rule, "top: -0.25rem"
    assert_includes rule, "pointer-events: auto"
  end

  def test_the_seat_follows_the_one_row_avatar_size
    assert_match(/\[data-nav-rows="1"\] \+ \[data-nav-account\] \+ \[data-nav-avatar-badge\] \{\s*width: var\(--nav-avatar\);\s*height: var\(--nav-avatar\);/, CSS)
  end

  def test_the_seat_scales_with_the_avatar_on_the_scroll_timeline
    assert_match(/\[data-nav-avatar-badge\] \{ transform-origin: right center; animation-name: nav-tl-avatar; \}/, CSS)
    assert_match(/\.nav-shell\[data-nav-timeline\] \[data-nav-avatar-badge\],[^{]*\{[^}]*animation-timeline: scroll\(root block\)/m, CSS)
  end
end
