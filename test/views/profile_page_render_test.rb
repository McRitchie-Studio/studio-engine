# frozen_string_literal: true

require "test_helper"
# ActionView's TagBuilder references BigDecimal when it serializes tag options,
# and the pure-Ruby suite boots no Rails to load it for us. Rendering any
# form_with here dies `uninitialized constant TagBuilder::BigDecimal` without
# this — a harness gap, not a defect in the partials.
require "bigdecimal"
require "action_view"
require "action_controller"
require "nokogiri"
require "active_support/core_ext/object/try"

# [view] Renders the /profile page and its two standard rows through ActionView.
#
# WHY THIS EXISTS SEPARATELY from the integration suite: that suite can assert
# the partials are on disk and the routes dispatch, but the engine's dummy app
# has no users table, so it never renders the page. "The file exists" and "the
# page renders" are different claims, and only the second one is the feature.
# A partial that names a missing local, a helper the view context lacks, or a
# constant that moved raises here and nowhere else.
class ProfilePageRenderTest < Minitest::Test
  # Everything the page and its rows read off the user. Shaped like a host model
  # that has all the standard columns.
  class StubUser
    def display_name = "Pat Studio"
    def first_name = "Pat"
    def email = "pat@example.com"
    # The birth trio: present as methods, empty as values — the shape of an
    # account that has the columns and has not filled them in.
    def birth_year = nil
    def birth_month = nil
    def birth_day = nil
    def avatar = @avatar ||= Class.new { def attached? = false }.new
    def avatar_color = "#6366f1"
    def avatar_initials = "PS"
  end

  def view(user: StubUser.new)
    v = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    v.define_singleton_method(:current_user) { user }
    v.define_singleton_method(:profile_path) { "/profile" }
    v.define_singleton_method(:profile_avatar_path) { "/profile/avatar" }
    v.define_singleton_method(:edit_profile_path) { "/profile/edit" }
    v.define_singleton_method(:profile_newsletter_path) { "/profile/newsletter" }
    # show.html.erb reads flash[:email_change_pending] to decide whether to open
    # the handoff modal. A bare ActionView has no controller to delegate flash
    # to, so supply the empty case — the populated one is exercised by a real
    # request in test/integration/profile_requests_test.rb.
    v.define_singleton_method(:flash) { {} }
    v.define_singleton_method(:protect_against_forgery?) { false }
    v
  end

  # THE EDIT PAGE, rendered whole. The read page above has had this since it shipped;
  # the edit page did not, and the gap had teeth: its save bar was extracted into
  # studio/profiles/_save_bar so the browser lane could mount it, and a mistyped
  # partial name in that extraction raises at request time and nowhere else. The
  # browser lane renders the partial DIRECTLY on its lab page, so it would stay green
  # while /profile/edit 500s.
  def render_edit(sections = Studio::ProfileSections.defaults.select { |x| x[:page] == :edit })
    v = view
    v.instance_variable_set(:@profile_sections, sections)
    v.render(template: "studio/profiles/edit")
  end

  def render_page(sections)
    v = view
    v.instance_variable_set(:@profile_sections, sections)
    v.render(template: "studio/profiles/show")
  end

  # --- the identity header ------------------------------------------------------
  #
  # "You at a glance" (the operator's framing, and the shape iOS Settings uses).
  # It renders on BOTH pages, and its badge is the one control on it: a LINK to
  # the edit page when reading, a BUTTON that opens the cropper when editing.

  def identity(user: StubUser.new, editable: false)
    view.render(partial: "studio/profiles/identity", locals: { user: user, editable: editable })
  end

  def test_the_header_shows_who_you_are
    doc = Nokogiri::HTML5.fragment(identity)

    assert_includes doc.text, "Pat Studio"
    assert_includes doc.text, "pat@example.com"
  end

  # THE ONLY WAY THROUGH. The operator removed the page heading and the top-right
  # Edit button, so this badge is the read page's entire route to editing — not a
  # convenience beside another link. Losing it strands the edit page.
  # The glyph starts hidden and fades in. The three reveal paths are asserted
  # together because the last two are what stop a hover-only affordance from
  # stranding people: this badge is the read page's ONLY route to editing, and a
  # keyboard never hovers while touch has no hover at all.
  def test_the_badge_glyph_is_hidden_until_hover_focus_or_touch
    html = identity
    styles = html[/<style>(.*?)<\/style>/m, 1].to_s

    assert_includes html, "studio-avatar-badge-icon"
    assert_match(/\.studio-avatar-badge-icon\s*\{[^}]*opacity:\s*0/, styles,
      "the glyph rests hidden")
    assert_includes styles, ".studio-avatar:hover .studio-avatar-badge-icon"
    assert_includes styles, ".studio-avatar-badge:focus .studio-avatar-badge-icon",
      "a keyboard never hovers, and this badge is the only way to the edit page"
    assert_match(/@media \(hover: none\)/, styles,
      "touch has no hover — the glyph must not simply never appear there")
  end

  def test_the_badge_circle_itself_is_always_visible
    styles = identity[/<style>(.*?)<\/style>/m, 1].to_s

    refute_match(/\.studio-avatar-badge\s*\{[^}]*opacity:\s*0/, styles,
      "only the glyph waits; the circle is the resting affordance")
  end

  # THE WHOLE CARD IS THE LINK on the read page — a 28px badge became the single
  # route to editing once the heading and Edit button came off, so the target
  # grew to the thing people actually aim at.
  def test_the_read_identity_card_is_itself_the_link_to_edit
    doc = Nokogiri::HTML5.fragment(identity)
    card = doc.at_css("a.studio-identity-card")

    refute_nil card, "the card carries the destination"
    assert_equal "/profile/edit", card["href"]
    assert_equal "Edit your profile", card["aria-label"]
    assert_includes card.text, "Pat Studio", "the whole block is inside the link"
  end

  # An <a> inside an <a> is invalid, and browsers repair it by closing the outer
  # link early — which would silently shrink the card's clickable area to
  # whatever preceded the badge.
  def test_the_read_badge_is_decorative_not_a_nested_link
    doc = Nokogiri::HTML5.fragment(identity)

    assert_equal 1, doc.css("a").length, "exactly one link: the card itself"
    badge = doc.at_css("span.studio-avatar-badge")
    refute_nil badge, "the badge stays as a decorative glyph"
    assert_equal "true", badge["aria-hidden"]
  end

  # The edit page's badge is still a real button — it opens the cropper there,
  # and that card is not a link.
  def test_the_edit_badge_stays_a_button
    doc = Nokogiri::HTML5.fragment(identity(editable: true))

    assert_nil doc.at_css("a.studio-identity-card"), "the edit card is not a link"
    assert_equal "button", doc.at_css('[aria-label="Change your profile photo"]').name
  end

  # --- the compact header that takes over on scroll --------------------------

  def test_the_identity_ships_a_compact_header_and_something_to_watch
    html = identity

    assert_includes html, "data-studio-identity-mini"
    assert_includes html, "data-studio-identity-full", "the observer needs a target"
    assert_includes html, "IntersectionObserver"
  end

  # FIXED, not sticky. A sticky bar stays in flow and would reserve its height
  # under the card forever, pushing every row down whether or not it is showing.
  def test_the_compact_header_costs_no_layout_height
    styles = identity[/<style>(.*?)<\/style>/m, 1].to_s

    assert_match(/\.studio-identity-mini\s*\{[^}]*position:\s*fixed/, styles)
    assert_match(/\.studio-identity-mini\s*\{[^}]*opacity:\s*0/, styles, "it rests hidden")
  end

  # CARD WIDTH, not full bleed — it should read as the identity card shrunk, not
  # as a second navbar. The calc keeps it inside the gutters on a narrow screen,
  # where a bare 42rem would run off the edge.
  def test_the_compact_header_matches_the_card_width
    styles = identity[/<style>(.*?)<\/style>/m, 1].to_s

    assert_match(/width:\s*min\(42rem,\s*calc\(100% - 2rem\)\)/, styles)
  end

  # The centring translate and the entry animation share ONE transform property —
  # declaring a second would silently replace the first and the bar would fly in
  # from the left edge.
  def test_the_compact_headers_centring_survives_its_animation
    styles = identity[/<style>(.*?)<\/style>/m, 1].to_s
    visible = styles[/\.studio-identity-mini\.is-visible\s*\{([^}]*)\}/m, 1].to_s

    assert_match(/transform:\s*translateX\(-50%\)/, visible,
      "the visible state must keep the centring, not just drop the offset")
  end

  # Pinned to the height the host navbar publishes — the same variable
  # /admin/style uses to stick its section nav — with a 0px fallback so an app
  # that publishes nothing gets a bar at the top rather than a broken one.
  def test_the_compact_header_pins_under_the_host_navbar
    styles = identity[/<style>(.*?)<\/style>/m, 1].to_s

    # The variable and its fallback, wherever they sit — the offset around them
    # is a design nudge, the anchor is the contract.
    assert_match(/top:[^;]*var\(--nav-h,\s*0px\)/, styles)
  end

  # It duplicates content already on the page and already reachable. A second
  # link would be a duplicate tab stop and a second announcement of the same
  # name for no gain.
  def test_the_compact_header_is_not_a_second_interactive_copy
    doc = Nokogiri::HTML5.fragment(identity)
    mini = doc.at_css("[data-studio-identity-mini]")

    assert_equal "true", mini["aria-hidden"]
    assert_empty mini.css("a, button"), "the full card above is the route to editing"
  end

  def test_the_read_page_carries_no_heading_or_second_edit_control
    html = render_page(Studio::ProfileSections.defaults.select { |x| x[:page] == :show })
    doc = Nokogiri::HTML5.fragment(html)

    assert_nil doc.at_css("h1"), "the card is the page — no heading above it"
    edit_links = doc.css("a").select { |a| a["href"] == "/profile/edit" }
    assert_equal 1, edit_links.length, "exactly one route through: the avatar badge"
  end

  def test_the_edit_headers_badge_opens_the_picker
    doc = Nokogiri::HTML5.fragment(identity(editable: true))
    badge = doc.at_css('[aria-label="Change your profile photo"]')

    refute_nil badge
    assert_equal "button", badge.name, "a div here is unreachable by keyboard"
    assert_equal "$refs.filePicker.click()", badge["@click"]
  end

  # REGRESSION GUARD. The avatar used to be a ROW declaring `requires: :avatar`,
  # so it was dropped whole on a host whose model has no attachment. Moving it
  # into this header lost that protection, and the first render against such a
  # model raised `undefined method 'avatar'`. A header is not exempt from the
  # rule that consumers disagree about their users table.
  def test_the_header_tolerates_a_model_with_no_attachment
    no_avatar = Class.new do
      def display_name = "Pat Studio"
      def email = "pat@example.com"
      def avatar_initials = "P"
      def avatar_color = "#6366f1"
    end.new

    doc = Nokogiri::HTML5.fragment(identity(user: no_avatar, editable: true))

    assert_includes doc.text, "Pat Studio"
    assert_nil doc.at_css('[aria-label="Change your profile photo"]'),
      "no attachment means no upload affordance — not a raise"
  end

  # --- the edit fields ------------------------------------------------------------
  #
  # These are fields in ONE form with ONE save, so none of them carries a button.
  # x-model feeds the dirty check that raises the save bar.

  def test_the_name_fields_prefill_and_feed_the_dirty_check
    doc = Nokogiri::HTML5.fragment(
      view.render(partial: "studio/profiles/name_fields", locals: { user: StubUser.new })
    )

    first = doc.at_css('input[name="profile[first_name]"]')
    assert_equal "Pat", first["value"]
    assert_equal "fields.first_name", first["x-model"]
    assert_nil doc.at_css('input[type="submit"]'), "the sticky bar saves this, not a per-row button"
  end

  # last_name is not a standard column yet — mcritchie-studio and turf-monster
  # have it, the other three do not. The field is gated rather than blocking the
  # page on a coordinated fleet migration.
  def test_the_last_name_field_appears_only_where_the_column_does
    with_last = Class.new(StubUser) { def last_name = "McRitchie" }.new

    assert_nil Nokogiri::HTML5.fragment(
      view.render(partial: "studio/profiles/name_fields", locals: { user: StubUser.new })
    ).at_css('input[name="profile[last_name]"]')

    refute_nil Nokogiri::HTML5.fragment(
      view.render(partial: "studio/profiles/name_fields", locals: { user: with_last })
    ).at_css('input[name="profile[last_name]"]')
  end

  # ONE date input over THREE integer columns — the split is deliberate upstream
  # and the UI joins them for entry.
  def test_the_birthday_field_joins_three_columns_into_one_date
    dated = Class.new(StubUser) do
      def birth_year = 1991
      def birth_month = 9
      def birth_day = 15
    end.new
    field = Nokogiri::HTML5.fragment(
      view.render(partial: "studio/profiles/birthday_fields", locals: { user: dated })
    ).at_css('input[name="profile[birthday]"]')

    assert_equal "date", field["type"]
    assert_equal "1991-09-15", field["value"]
  end

  def test_a_missing_birthday_leaves_the_field_empty_rather_than_guessing
    field = Nokogiri::HTML5.fragment(
      view.render(partial: "studio/profiles/birthday_fields", locals: { user: StubUser.new })
    ).at_css('input[name="profile[birthday]"]')

    assert_equal "", field["value"].to_s, "an unknown birthday must not be guessed at"
  end

  def test_the_email_field_locks_when_google_is_linked
    linked = Class.new(StubUser) do
      def provider = "google_oauth2"
      def uid = "1"
    end.new
    doc = Nokogiri::HTML5.fragment(
      view.render(partial: "studio/profiles/email_fields", locals: { user: linked })
    )

    assert_nil doc.at_css('input[name="profile[email]"]'), "a locked address offers nothing to type into"
    assert_includes doc.text, "linked Google account"
    # The unlink lives on the READ page — a lock that does not say where the key
    # is is just a wall.
    assert_equal "/profile", doc.at_css("a")["href"]
  end

  # --- the Google identity row -------------------------------------------------

  class GoogleUser
    def initialize(provider: "google_oauth2", uid: "123", email: "pat@example.com")
      @provider, @uid, @email = provider, uid, email
    end
    attr_reader :provider, :uid, :email
    def display_name = "Pat Studio"
  end

  def google_row(user)
    v = view
    v.define_singleton_method(:profile_unlink_google_path) { "/profile/google" }
    v.render(partial: "studio/profiles/google_section", locals: { user: user })
  end

  def test_the_linked_state_offers_unlink
    doc = Nokogiri::HTML5.fragment(google_row(GoogleUser.new))

    assert_includes doc.text, "Connected via Google"
    form = doc.at_css("form")
    refute_nil form, "expected the unlink button"
    assert_equal "/profile/google", form["action"]
    assert_equal "delete", doc.at_css('input[name="_method"]')["value"],
      "unlinking removes an identity — it is a DELETE"
  end

  def test_the_unlinked_state_offers_the_omniauth_connect_button
    doc = Nokogiri::HTML5.fragment(google_row(GoogleUser.new(provider: nil, uid: nil)))

    assert_includes doc.text, "Link Google Account"
    # OmniAuth's own path; the engine does not draw it, the middleware owns it.
    assert_equal "/auth/google_oauth2", doc.at_css("form")["action"]
    refute_includes doc.text, "Connected via Google"
  end

  # THE ORPHAN GUARD, at the UI. An account whose only sign-in is Google must not
  # be offered a live Unlink button. The control is DISABLED with the reason
  # beside it rather than hidden — a control that vanishes teaches nothing, and
  # the person cannot tell whether the feature is missing or their account is
  # special. The server refuses this case regardless; this is the explanation.
  def test_a_google_only_account_cannot_click_unlink
    row = google_row(GoogleUser.new(email: nil))
    doc = Nokogiri::HTML5.fragment(row)

    assert_includes doc.text, "Connected via Google"
    refute_nil doc.at_css("button[disabled]"), "unlink must not be clickable"
    assert_nil doc.at_css("form"), "no submittable unlink form for a Google-only account"
    assert_includes doc.text, "Add an email address first"
  end

  def test_an_account_with_another_sign_in_keeps_a_live_unlink
    doc = Nokogiri::HTML5.fragment(google_row(GoogleUser.new(email: "pat@example.com")))

    assert_nil doc.at_css("button[disabled]")
    refute_nil doc.at_css("form")
  end

  # --- the newsletter row ------------------------------------------------------
  #
  # Two states, and the asymmetry between them is the design: joining is one
  # click, leaving asks. Joining is reversible from the same card, so a confirm
  # would be friction protecting nothing; a mis-click on leave is silent until the
  # next send never arrives.

  def newsletter(user)
    v = view
    v.define_singleton_method(:profile_newsletter_path) { "/profile/newsletter" }
    v.render(partial: "studio/profiles/newsletter_section", locals: { user: user })
  end

  def subscriber(**attrs)
    Class.new(StubUser) do
      define_method(:joined_email_list_at) { attrs.fetch(:joined, nil) }
      define_method(:left_email_list_at) { attrs.fetch(:left, nil) }
      define_method(:email) { attrs.fetch(:email, "pat@example.com") }
    end.new
  end

  def test_an_unsubscribed_account_is_offered_a_one_click_join
    doc = Nokogiri::HTML5.fragment(newsletter(subscriber))
    form = doc.at_css("form")

    refute_nil form, "joining is a plain form — it must work with no JavaScript"
    assert_equal "/profile/newsletter", form["action"]
    assert_nil doc.at_css('input[name="_method"]'), "joining is a POST, not an override"
  end

  def test_a_subscribed_account_is_offered_the_way_out
    doc = Nokogiri::HTML5.fragment(newsletter(subscriber(joined: Time.at(1_700_000_000))))

    assert_includes doc.text, "Subscribed"
    button = doc.at_css("button")
    assert_equal "$store.profileModals.open('newsletter-unsubscribe')", button["@click"],
      "leaving opens the confirmation rather than submitting straight away"
  end

  # NO INLINE DELETE FORM on the card. The confirmation carries the form it
  # submits, so there is exactly one place the DELETE is issued from — a confirm
  # whose button posts a form elsewhere on the page drifts the moment that form
  # moves.
  def test_the_subscribed_card_carries_no_form_of_its_own
    doc = Nokogiri::HTML5.fragment(newsletter(subscriber(joined: Time.at(1_700_000_000))))

    assert_nil doc.at_css("form"), "the DELETE lives in the modal, not on the card"
  end

  # A wallet-only account has no address, and a newsletter needs somewhere to
  # send. It is ASKED rather than allowed to submit and fail.
  def test_an_account_with_no_email_is_asked_for_one
    doc = Nokogiri::HTML5.fragment(newsletter(subscriber(email: nil)))

    assert_nil doc.at_css("form"), "there is nothing to submit yet"
    assert_equal "$store.profileModals.open('newsletter-email')", doc.at_css("button")["@click"]
  end

  def test_a_returning_account_is_told_it_can_rejoin
    doc = Nokogiri::HTML5.fragment(
      newsletter(subscriber(joined: Time.at(1_700_000_000), left: Time.at(1_700_000_100)))
    )

    assert_includes doc.text, "Join again"
  end

  # --- the pages ------------------------------------------------------------------

  def test_the_read_page_renders_its_rows_in_one_card
    doc = Nokogiri::HTML5.fragment(
      render_page(Studio::ProfileSections.defaults.select { |x| x[:page] == :show })
    )

    assert_equal %w[google newsletter], doc.css("[data-profile-section]").map { |x| x["data-profile-section"] }
  end

  def test_a_read_page_with_no_rows_still_renders_the_identity
    html = render_page([])

    refute_includes html, "data-profile-section"
    assert_includes html, "Pat Studio", "the header IS the read page when there are no rows"
  end

  # Nothing on the READ page opens a modal, so it must not pay ~40 KB of
  # cropper.js or mount a host for nobody.
  # THE HOST IS CONDITIONAL, which is what the registry's `modals:` key was
  # documented for and, until the newsletter row, never exercised. This test used
  # to assert the page mounted NO host — true and correct while nothing on it
  # opened one. Now a row asks, so the claim becomes "mounts when asked, and only
  # then", which is the property that was always meant.
  def test_the_read_page_mounts_a_host_only_when_a_row_asks_for_one
    without = render_page([{ key: :plain, title: "Plain", partial: "studio/profiles/google_section" }])
    refute_includes without, "profileModals",
      "no row asked for modals — a host here would be furniture for nobody"

    with = render_page(Studio::ProfileSections.defaults.select { |x| x[:page] == :show })
    assert_includes with, "profileModals", "the newsletter row asks for a host"
  end

  # A HOST IS NOT A CROPPER. The avatar is read-only on this page — the picker
  # lives on /profile/edit — so mounting a host must not drag ~40 KB of cropper.js
  # along with it.
  def test_the_read_page_never_loads_the_cropper
    html = render_page(Studio::ProfileSections.defaults.select { |x| x[:page] == :show })

    refute_includes html, "cropper.min.js"
  end

  def test_a_host_section_renders_with_its_own_locals
    # The extension seam, exercised end to end rather than asserted: a host row
    # naming its own partial and passing locals must render like any other.
    v = view
    v.instance_variable_set(:@profile_sections, [
      { key: :note, title: "Host row", partial: "studio/profiles/name_fields", locals: {} }
    ])
    html = v.render(template: "studio/profiles/show")

    assert_includes html, "Host row"
    assert_includes html, 'data-profile-section="note"'
  end
end

class ProfileEditPageRenderTest < ProfilePageRenderTest
  def test_the_edit_page_renders_whole
    doc = Nokogiri::HTML5.fragment(render_edit)

    # The form, its fields, and the one Save that owns them. Selected by action, not
    # by position: the avatar uploader is a SECOND form on this page and it comes
    # first in document order.
    assert_equal 1, doc.css('form[action="/profile"]').length
    refute_nil doc.at_css('input[name="profile[first_name]"]')
    refute_nil doc.at_css("[data-studio-save-bar]"),
      "the save bar partial did not reach the page — an extraction that renders nowhere"
  end

  def test_the_edit_page_offers_a_way_back
    doc = Nokogiri::HTML5.fragment(render_edit)
    back = doc.at_css('a[aria-label="Back to your profile"]')

    refute_nil back, "the heading and Done came off, so this is the only exit for someone who changed nothing"
    assert_equal "/profile", back["href"]
  end

  # The no-JS path. A page whose script never ran still has to save, and the sticky
  # bar cannot be that path — it exists only once Alpine has computed `dirty`.
  def test_the_edit_page_saves_without_javascript
    doc = Nokogiri::HTML5.fragment(render_edit)
    plain = doc.css('button[type="submit"]').reject { |b| b.ancestors("[data-studio-save-bar]").any? }

    refute_empty plain, "with the save bar behind x-show, a JS-less page would have no Save at all"
  end

  # The dirty check compares against what the SERVER rendered. If the seed and the
  # field disagree the bar is up on arrival, before anyone has typed.
  def test_the_dirty_check_is_seeded_from_the_rendered_values
    doc = Nokogiri::HTML5.fragment(render_edit)
    seed = JSON.parse(doc.at_css("[x-data]")["x-data"][/studioProfileForm\((.*)\)\z/m, 1])

    assert_equal doc.at_css('input[name="profile[first_name]"]')["value"], seed["first_name"]
  end
end
