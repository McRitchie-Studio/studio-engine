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
  LIT = "#{GROUP}:has([data-link-sidebar-trigger]:hover, [data-nav-account]:hover, [data-nav-name-trigger]:hover, " \
        "[data-link-sidebar-trigger]:focus-visible, [data-nav-account]:focus-visible, [data-nav-name-trigger]:focus-visible)"

  def lit_rule(target) = CSS[/^\s*#{Regexp.escape("#{LIT} #{target}")}[^{]*\{[^}]*\}/]

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
  HOST_LIT = "#{HOST}:has(#{HOST_GEAR}:hover, [data-nav-account]:hover, [data-nav-name-trigger]:hover, " \
             "#{HOST_GEAR}:focus-visible, [data-nav-account]:focus-visible, [data-nav-name-trigger]:focus-visible)"

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
