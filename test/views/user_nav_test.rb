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
  # The rule now: link to /profile when it exists, fall back to a host's own
  # account_path (turf-monster, mid-migration), and render PLAIN TEXT when
  # neither does. Never a dead href.

  def test_username_and_avatar_link_to_profile_when_the_route_exists
    doc = Nokogiri::HTML5.fragment(render_nav)
    hrefs = doc.css("a").map { |a| a["href"] }

    assert_equal 2, hrefs.count("/profile"),
      "both the username and the avatar link to /profile"
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
    assert_nil doc.at_css("a.truncate"), "no link when there is no destination"
    refute_nil doc.at_css("span.truncate"), "the name renders as plain text instead"
  end

  def test_the_avatar_still_renders_when_there_is_nowhere_to_link
    doc = Nokogiri::HTML5.fragment(render_nav(profile_path: nil))

    assert_includes doc.to_html, "PS", "the initials circle survives the degrade"
  end

  # turf-monster keeps its own /account working while its rows move to /profile
  # one at a time. Until it adopts, its navbar must still point at the page it
  # actually has — the fallback is what lets the two pages coexist.
  def test_falls_back_to_a_hosts_own_account_path
    doc = Nokogiri::HTML5.fragment(render_nav(profile_path: nil, account_path: "/account"))
    hrefs = doc.css("a").map { |a| a["href"] }

    assert_equal 2, hrefs.count("/account")
  end

  def test_profile_wins_over_a_hosts_account_path
    # Once an app draws both, /profile is the destination — that is how the
    # migration actually flips over for turf-monster.
    doc = Nokogiri::HTML5.fragment(render_nav(profile_path: "/profile", account_path: "/account"))
    hrefs = doc.css("a").map { |a| a["href"] }

    assert_equal 2, hrefs.count("/profile")
    refute_includes hrefs, "/account"
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
  # That property was measured directly in Chromium against this partial's
  # real output plus the hub's compiled Tailwind (viewport 400px, nav given
  # 328px): with min-w-0 on the inner Div 1 row the nav root could not
  # shrink below a 364px min-content width, the avatar was pushed to
  # right=424 (page scrolled horizontally) and the username link measured
  # scrollWidth 156 == clientWidth 156, so NO ellipsis rendered. With
  # min-w-0 on the flex-1 column instead, the nav root shrank to 328px,
  # nothing crossed the viewport, and the link measured scrollWidth 156 >
  # clientWidth 120 -- the ellipsis rendered.
  #
  # What IS assertable here is the structural precondition that made the
  # difference, so these two tests guard it: a flex item defaults to
  # min-width auto, so the min-w-0 escape has to sit on the flex item of
  # the nav root. Putting it anywhere deeper is a no-op for shrinking, and
  # that misplacement is exactly the bug these tests exist to catch. They
  # walk the DOM from the truncating link upward rather than string-matching
  # the class, so min-w-0 appearing elsewhere in the subtree cannot satisfy
  # them.

  def test_min_w_0_sits_on_the_nav_roots_flex_item_not_deeper
    column = username_column(render_nav)

    assert_includes column["class"].split, "min-w-0",
      "the flex item of the nav root must carry min-w-0, or it keeps " \
      "min-width auto and refuses to shrink, defeating the username truncate"
  end

  def test_no_element_below_the_flex_item_carries_a_stray_min_w_0
    # Guards the specific regression: min-w-0 on the inner Div 1 row reads
    # like the fix but does nothing, because that row is a block child of
    # the column, not a flex item of the nav root.
    column = username_column(render_nav)
    strays = column.css("[class~='min-w-0']").map { |el| el["class"] }

    assert_empty strays,
      "min-w-0 below the flex item does not enable shrinking; it belongs on the column"
  end

  private

  # Walks up from the truncating username link to the nav root's direct
  # child -- the element that is actually a flex item of the nav root.
  def username_column(html)
    doc = Nokogiri::HTML5.fragment(html)
    nav_root = doc.at_css("div.flex.gap-2")
    refute_nil nav_root, "expected the nav root flex row"

    link = nav_root.at_css("a.truncate")
    refute_nil link, "expected the truncating username link"

    node = link
    node = node.parent while node.parent && node.parent != nav_root
    assert_equal nav_root, node.parent, "expected the link to descend from the nav root"
    node
  end

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
  def render_nav(logged_in: true, profile_path: "/profile", account_path: nil, **locals)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(
      ["app/views", "test/views/fixtures"]
    )
    user = StubUser.new
    view.define_singleton_method(:logged_in?) { logged_in }
    view.define_singleton_method(:current_user) { user }
    view.define_singleton_method(:logout_path) { "/logout" }
    view.define_singleton_method(:login_path) { "/login" }
    view.define_singleton_method(:signup_path) { "/signup" }
    view.define_singleton_method(:profile_path) { profile_path } if profile_path
    view.define_singleton_method(:account_path) { account_path } if account_path

    view.render(partial: "components/user_nav", locals: locals)
  end
end
