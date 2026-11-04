# frozen_string_literal: true

require "test_helper"

# [unit] The account group, in engine.css. Where the account opens the link
# sidebar, as the gear does, these rules light the gear, the name and the
# avatar together. The group is found by what the user nav row holds, so the
# partial renders no new markup (user_nav_test pins the hooks it keys on).
# Each assertion spans a selector AND its declaration.
class NavbarAccountGroupCssTest < Minitest::Test
  CSS = File.read(File.expand_path("../../app/assets/tailwind/studio_engine/engine.css", __dir__)).freeze

  GROUP = ':has(> [data-nav-tools]):has(> [data-nav-account][aria-controls~="studio-link-sidebar"])'
  # [data-nav-name-trigger] is the name as its own control in row 1
  # (Studio.navbar_name_in_rows); pointing at it lights the group too.
  GEAR = "[data-link-sidebar-trigger]"
  LIT = "#{GROUP}:has(#{GEAR}:hover, [data-nav-account]:hover, [data-nav-name-trigger]:hover)"
  FOCUS_LIT = "#{GROUP}:has(#{GEAR}:focus-visible, [data-nav-account]:focus-visible, [data-nav-name-trigger]:focus-visible)"

  def lit_rule(target, lit = LIT) = CSS[/^\s*#{Regexp.escape("#{lit} #{target}")}[^{]*\{[^}]*\}/]

  # The group's rules: from its comment to the next section's, comments dropped.
  def section
    CSS[%r{/\* THE ACCOUNT GROUP.*?(?=/\* THE ACCOUNT ROW)}m].gsub(%r{/\*.*?\*/}m, "")
  end

  # The bodies of every @media (hover: hover) block in text, and text without them.
  def split_hover_blocks(text)
    inside = +""
    outside = text.dup
    while (start = outside.index("@media (hover: hover)"))
      open_at = outside.index("{", start)
      depth = 1
      cursor = open_at + 1
      while depth.positive?
        depth += { "{" => 1, "}" => -1 }.fetch(outside[cursor], 0)
        cursor += 1
      end
      inside << outside[(open_at + 1)...(cursor - 1)]
      outside[start...cursor] = ""
    end
    [inside, outside]
  end

  def test_every_hover_in_the_group_sits_inside_the_hover_guard
    inside, outside = split_hover_blocks(section)

    refute_includes outside, ":hover", "a tap leaves :hover on a touch screen, so this rule stays lit there"
    assert_includes inside, ":hover"
    assert_includes CSS, "POINTING NEEDS A POINTER"
  end

  def test_keyboard_focus_stays_outside_the_hover_guard
    inside, outside = split_hover_blocks(section)

    refute_includes inside, ":focus-visible", "a keyboard on a touch device must still light the group"
    assert_includes outside, "#{FOCUS_LIT} #{GEAR},"
    assert_includes outside, "#{FOCUS_LIT} [data-nav-name] { color: var(--color-primary); }"
    assert_includes outside, "#{FOCUS_LIT} [data-nav-account] > [aria-hidden] > * {"
    assert_includes outside, "#{FOCUS_LIT} #{GEAR} svg { transform: rotate(45deg); }"
    assert_includes outside, "#{HOST_FOCUS_LIT} #{HOST_GEAR},"
    assert_includes outside, "#{HOST_FOCUS_LIT} [data-nav-name] { color: var(--color-primary); }"
    assert_includes outside, "#{HOST_FOCUS_LIT} [data-nav-account] > [aria-hidden] > * {"
    assert_includes outside, "#{HOST_FOCUS_LIT} #{HOST_GEAR} svg { transform: rotate(45deg); }"
  end

  def test_any_of_the_three_lights_the_gear_and_the_name
    rule = lit_rule("[data-link-sidebar-trigger],")

    refute_nil rule, "no lit rule for the gear in engine.css"
    assert_includes rule, "#{LIT} [data-nav-name]", "the name lights with the gear"
    assert_includes rule, "color: var(--color-primary)"
  end

  def test_the_avatar_glows_in_the_brand_primary
    rule = lit_rule("[data-nav-account] > [aria-hidden] > *")

    refute_nil rule, "no lit rule for the avatar in engine.css"
    assert_includes rule, "box-shadow:"
    assert_includes rule, "rgb(var(--color-primary-rgb) / 0.85)", "the ring reads the theme's primary, not a fixed colour"
  end

  def test_the_gear_turns_only_when_motion_is_welcome
    assert_match(/@media \(prefers-reduced-motion: no-preference\) \{\s*#{Regexp.escape(LIT)} \[data-link-sidebar-trigger\] svg \{ transform: rotate\(45deg\); \}/, CSS)
  end

  def test_the_gear_drops_its_own_hover_pill_inside_the_group
    assert_includes CSS, "#{GROUP} [data-link-sidebar-trigger]:hover { background-color: transparent; }"
  end

  HOST = ':has(> [data-nav-tools] [data-nav-menu-trigger]):has(> [data-nav-account][data-profile-image-toggle]' \
         ':not([aria-controls~="studio-link-sidebar"]))'
  HOST_GEAR = "[data-nav-menu-trigger] [aria-controls]"
  HOST_LIT = "#{HOST}:has(#{HOST_GEAR}:hover, [data-nav-account]:hover, [data-nav-name-trigger]:hover)"
  HOST_FOCUS_LIT = "#{HOST}:has(#{HOST_GEAR}:focus-visible, [data-nav-account]:focus-visible, [data-nav-name-trigger]:focus-visible)"

  def test_a_host_sidebar_groups_the_menu_trigger_with_the_account
    rule = CSS[/^\s*#{Regexp.escape("#{HOST_LIT} #{HOST_GEAR},")}[^{]*\{[^}]*\}/]

    refute_nil rule, "no lit rule for the host gear in engine.css"
    assert_includes rule, "#{HOST_LIT} [data-nav-name]"
    assert_includes rule, "color: var(--color-primary)"
    assert_includes CSS, "#{HOST_LIT} [data-nav-account] > [aria-hidden] > * {"
    assert_includes CSS, "#{HOST_LIT} #{HOST_GEAR} svg { transform: rotate(45deg); }"
    assert_includes CSS, "#{HOST} #{HOST_GEAR}:hover { background-color: transparent; }"
  end
end
