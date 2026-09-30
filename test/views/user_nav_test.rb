# frozen_string_literal: true

require "test_helper"
require "action_view"
require "nokogiri"
require "active_support/core_ext/object/try"

# Renders components/_user_nav.html.erb through ActionView and pins the slot
# contract: the new partial slots (balance_slot / extra_icons_slot /
# div2_slot — String path or { partial:, locals: } Hash), the deprecated
# legacy *_html string locals (still honored — hub and turf call sites must
# render unchanged), and the precedence rule (slot wins over legacy string).
class UserNavTest < Minitest::Test
  # --- legacy string locals (backward compatibility) --------------------

  def test_legacy_balance_html_string_still_renders
    html = render_nav(balance_html: %(<span data-legacy="balance">LEGACY-BAL</span>))

    assert_includes html, "LEGACY-BAL"
    assert_includes html, %(data-legacy="balance")
  end

  def test_legacy_extra_icons_html_string_still_renders
    html = render_nav(extra_icons_html: %(<span data-legacy="icons">LEGACY-ICONS</span>))

    assert_includes html, "LEGACY-ICONS"
  end

  def test_legacy_div2_html_string_replaces_the_default_second_row
    # div2_html was documented but silently ignored before the slot rework;
    # it now honors the documented contract.
    html = render_nav(div2_html: %(<div data-legacy="div2">LEGACY-DIV2</div>))

    assert_includes html, "LEGACY-DIV2"
    refute_includes html, "seedsNavbar", "default level bar should be replaced"
  end

  def test_hub_style_call_renders_unchanged
    # The hub's exact call: render "components/user_nav", show_logout_link: true
    html = render_nav(show_logout_link: true)

    assert_includes html, "Log out"
    assert_includes html, "/logout"
    assert_includes html, "seedsNavbar", "default level bar renders when no div2 slot given"
    assert_includes html, "Pat Studio"
  end

  # --- partial slots ----------------------------------------------------

  def test_balance_slot_renders_a_partial_by_name
    html = render_nav(balance_slot: "user_nav_fixtures/balance")

    assert_includes html, "SLOT-BALANCE"
  end

  def test_hash_slot_renders_with_locals
    html = render_nav(balance_slot: { partial: "user_nav_fixtures/balance_amount", locals: { amount: 112 } })

    assert_includes html, "$112"
  end

  def test_extra_icons_slot_renders_a_partial_by_name
    html = render_nav(extra_icons_slot: "user_nav_fixtures/icons")

    assert_includes html, "SLOT-ICONS"
  end

  def test_div2_slot_replaces_the_default_second_row
    html = render_nav(div2_slot: "user_nav_fixtures/div2")

    assert_includes html, "SLOT-DIV2"
    refute_includes html, "seedsNavbar", "default level bar should be replaced"
    refute_includes html, "navLevelPop", "default level bar styles should be replaced"
  end

  def test_slot_wins_over_legacy_string_when_both_are_passed
    html = render_nav(
      balance_slot: "user_nav_fixtures/balance",
      balance_html: %(<span>LEGACY-BAL</span>)
    )

    assert_includes html, "SLOT-BALANCE"
    refute_includes html, "LEGACY-BAL"
  end

  # --- where the username and avatar point ------------------------------
  #
  # THE REGRESSION THESE GUARD (found 2026-08-14). The partial used to resolve
  # `defined?(account_path) ? account_path : "#"` in two places. Neither
  # mcritchie-studio nor mcritchie-industries draws an account route, so both
  # shipped a navbar whose username AND avatar were `href="#"` — a link that
  # looks identical to a working one until it is clicked, which is why it
  # survived in two production apps for as long as they have had a navbar.
  #
  # The rule now: a host's own account_path wins where it exists (turf-monster),
  # /profile is the destination for the four apps that never wrote one, and
  # PLAIN TEXT renders when neither does. Never a dead href.

  # FLIPPED in engine-navbar-phone-polish: these counted TWO /profile links
  # (the name, then the avatar). The name and avatar are now ONE link — one
  # tab stop — so the count is 1, and the link carries both.
  def test_username_and_avatar_link_to_profile_when_the_route_exists
    doc = Nokogiri::HTML5.fragment(render_nav)
    hrefs = doc.css("a").map { |a| a["href"] }

    assert_equal 1, hrefs.count("/profile"),
      "the username and the avatar are one link to /profile"
    link = doc.at_css("a[href='/profile']")
    assert_includes link.text, "Pat Studio", "the name is inside the link"
    assert_includes link.to_html, "PS", "the avatar is inside the same link"
  end

  def test_no_dead_href_anywhere_when_no_account_route_exists
    html = render_nav(profile_path: nil, account_path: nil)

    refute_includes html, 'href="#"',
      "a link to nowhere is the bug; render plain text instead"
  end

  def test_the_username_still_renders_when_there_is_nowhere_to_link
    # Degrading must not cost the user their name or their picture — only the
    # link. Asserting the text survives is what separates this fix from
    # "hide the whole block".
    doc = Nokogiri::HTML5.fragment(render_nav(profile_path: nil))

    assert_includes doc.text, "Pat Studio"
    assert_nil doc.at_css("a"), "no link when there is no destination"
    refute_nil doc.at_css("span[data-nav-name]"), "the name renders as plain text instead"
  end

  def test_the_avatar_still_renders_when_there_is_nowhere_to_link
    doc = Nokogiri::HTML5.fragment(render_nav(profile_path: nil))

    assert_includes doc.to_html, "PS", "the initials circle survives the degrade"
  end

  def test_a_hosts_own_account_path_is_used_when_profile_is_not_drawn
    doc = Nokogiri::HTML5.fragment(render_nav(profile_path: nil, account_path: "/account"))
    hrefs = doc.css("a").map { |a| a["href"] }

    assert_equal 1, hrefs.count("/account")
  end

  # THE MIGRATION RULE, and the one most likely to be "simplified" into a
  # regression. turf-monster's /account carries wallet balances, identities,
  # referrals and quests; /profile ships with two rows. Preferring /profile here
  # would silently demote turf's navbar to a thinner page on a routine
  # dependency bump — an upgrade that takes something away.
  #
  # So the host's page wins while it exists, and turf flips over by DELETING its
  # account route once /profile can actually replace it.
  def test_a_hosts_own_account_path_wins_when_both_exist
    doc = Nokogiri::HTML5.fragment(render_nav(profile_path: "/profile", account_path: "/account"))
    hrefs = doc.css("a").map { |a| a["href"] }

    assert_equal 1, hrefs.count("/account"),
      "the engine must not repoint an app that already has its own account page"
    refute_includes hrefs, "/profile"
  end

  # --- logged-out path --------------------------------------------------

  def test_logged_out_renders_login_and_signup
    html = render_nav(logged_in: false)

    assert_includes html, "Log in"
    assert_includes html, "Sign up"
    refute_includes html, "Pat Studio"
  end

  # --- username truncation chain ----------------------------------------
  #
  # This suite renders through ActionView only: there is no layout engine
  # here, so it CANNOT assert "the username shows an ellipsis at 400px".
  # What IS assertable is the structural precondition, and these tests walk
  # the DOM rather than string-match classes.
  #
  # The rule, measured twice. In Chromium at 400px (nav given 328px) the name
  # ellipsized only with min-w-0 on the left column — the flex item of the nav
  # root — and not one level deeper, because a flex item defaults to min-width
  # auto. And after engine-navbar-phone-polish first moved min-w-0 onto the
  # account link, the browser lane caught a 320px phone with a balance pushing
  # the avatar 17px past the screen: the icon column would not give. So the
  # column keeps min-w-0, the account link never shrinks, and the name
  # truncates inside a max width of its own.

  def test_min_w_0_sits_on_the_icon_column_the_nav_roots_flex_item
    root = nav_root(render_nav)
    column = root.element_children.find { |el| !el.key?("data-nav-account") }

    assert_includes column["class"].split, "min-w-0",
      "the icon column must carry min-w-0, or it refuses to shrink and pushes the avatar off a phone"
    assert_empty column.css("[class~='min-w-0']").map { |el| el["class"] },
      "min-w-0 below the flex item does not enable shrinking; it belongs on the column"
  end

  def test_the_account_link_never_shrinks
    link = account_item(render_nav)

    assert_includes link["class"].split, "flex-shrink-0", "the avatar must stay on screen"
    refute_includes link["class"].split, "min-w-0"
  end

  def test_the_name_truncates_inside_a_max_width
    name = account_item(render_nav).at_css("[data-nav-name]")

    assert_includes name["class"].split, "truncate"
    assert_includes name.parent["class"].split, "md:max-w-40",
      "the link does not shrink, so the name's box needs a max width to ellipsize in"
  end

  # --- one account link, avatar only on a phone ---------------------------

  def test_one_account_link_is_one_tab_stop
    doc = Nokogiri::HTML5.fragment(render_nav)
    accounts = doc.css("[data-nav-account]")

    assert_equal 1, accounts.size, "one account element"
    assert_equal "a", accounts.first.name
    assert_equal 1, doc.css("a[href='/profile']").size, "one link to the account page"
  end

  def test_phone_shows_the_avatar_only_and_keeps_the_name_for_screen_readers
    link = account_item(render_nav)
    name_box = link.at_css("[data-nav-name]").parent

    assert_equal %w[sr-only md:not-sr-only md:max-w-40], name_box["class"].split,
      "below md the name is screen-reader text; from md up it shows"
    assert_equal "Pat Studio", name_box.text.strip, "the name is still the link's text"

    avatar = link.css("span").find { |el| el["aria-hidden"] == "true" }
    refute_nil avatar, "the avatar is decorative inside the link (the name labels it)"
    assert_includes avatar.to_html, "PS"
    refute_includes avatar["class"].to_s.split, "hidden", "the avatar shows at every width"
  end

  # --- one theme toggle on a phone -----------------------------------------

  def test_signed_in_theme_toggle_is_desktop_only
    doc = Nokogiri::HTML5.fragment(render_nav)
    wrappers = doc.css("[data-nav-theme-toggle]")

    assert_equal 1, wrappers.size, "one theme toggle in the user nav"
    assert_equal %w[hidden md:flex], wrappers.first["class"].split,
      "below md the navbar's phone row draws the toggle; this one must hide"
    refute_empty wrappers.first.element_children, "the toggle itself renders inside the wrapper"
  end

  def test_signed_out_theme_toggle_is_desktop_only_too
    doc = Nokogiri::HTML5.fragment(render_nav(logged_in: false))
    wrappers = doc.css("[data-nav-theme-toggle]")

    assert_equal 1, wrappers.size
    assert_equal %w[hidden md:flex], wrappers.first["class"].split
  end

  # --- what the phone polish must keep --------------------------------------

  def test_the_desktop_sidebar_button_passed_as_extra_icons_html_still_renders
    # The engine navbar hands its desktop link-sidebar trigger in through
    # extra_icons_html. cyvasse's fork of this partial dropped it once, which
    # left desktops no way into the sidebar.
    html = render_nav(extra_icons_html: %(<button class="hidden md:inline-flex" data-sidebar-trigger>SIDEBAR</button>))
    button = Nokogiri::HTML5.fragment(html).at_css("[data-sidebar-trigger]")

    refute_nil button
    assert_nil button.ancestors.find { |el| el["data-nav-account"] }, "icons stay outside the account link"
  end

  def test_the_admin_menu_still_renders_for_an_admin
    html = render_nav(admin: true)

    assert_includes html, 'title="Admin"'
    refute_nil Nokogiri::HTML5.fragment(html).at_css("button[title='Admin']")
  end

  private

  def nav_root(html)
    root = Nokogiri::HTML5.fragment(html).at_css("div.flex.gap-2")
    refute_nil root, "expected the nav root flex row"
    root
  end

  # The account link (or its plain-text stand-in): a direct child of the nav
  # root, i.e. actually a flex item of it.
  def account_item(html)
    root = nav_root(html)
    item = root.element_children.find { |el| el.key?("data-nav-account") }
    refute_nil item, "expected the account link as a direct child of the nav root"
    item
  end

  public

  # --- off-chain collapse -----------------------------------------------

  def test_offchain_user_without_logout_link_gets_no_second_row
    # StubUser has no :level and no :truncated_solana; without
    # show_logout_link the default second row would be an empty progress
    # strip — it must not render at all (the turf nav fills it, a plain
    # app's nav collapses to one line).
    html = render_nav

    refute_includes html, "seedsNavbar", "empty default second row must collapse"
    refute_includes html, "navbar-replay-level"
  end

  def test_show_logout_link_keeps_the_second_row_for_offchain_users
    html = render_nav(show_logout_link: true)

    assert_includes html, "seedsNavbar"
    assert_includes html, "Log out"
  end

  # Minimal user double covering everything the partial (and the nested
  # avatar partial) reads. No :level and no :truncated_solana, so the
  # default second row takes the show_logout_link branch like the hub.
  class StubUser
    def display_name = "Pat Studio"
    def avatar = @avatar ||= Class.new { def attached? = false }.new
    def avatar_color = "#6366f1"
    def avatar_initials = "PS"
  end

  # `profile_path` / `account_path` are passed as nil to model a host that does
  # NOT draw that route — `defined?` is false there, exactly as in a real app
  # whose router never named the helper.
  def render_nav(logged_in: true, profile_path: "/profile", account_path: nil, admin: false, **locals)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(
      ["app/views", "test/views/fixtures"]
    )
    user = StubUser.new
    view.define_singleton_method(:logged_in?) { logged_in }
    view.define_singleton_method(:admin?) { admin } if admin
    view.define_singleton_method(:current_user) { user }
    view.define_singleton_method(:logout_path) { "/logout" }
    view.define_singleton_method(:login_path) { "/login" }
    view.define_singleton_method(:signup_path) { "/signup" }
    view.define_singleton_method(:profile_path) { profile_path } if profile_path
    view.define_singleton_method(:account_path) { account_path } if account_path

    view.render(partial: "components/user_nav", locals: locals)
  end
end
