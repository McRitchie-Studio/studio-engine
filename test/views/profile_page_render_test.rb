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
    # show.html.erb reads flash[:email_change_pending] to decide whether to open
    # the handoff modal. A bare ActionView has no controller to delegate flash
    # to, so supply the empty case — the populated one is exercised by a real
    # request in test/integration/profile_requests_test.rb.
    v.define_singleton_method(:flash) { {} }
    v.define_singleton_method(:protect_against_forgery?) { false }
    v
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

  def test_the_read_headers_badge_links_to_the_edit_page
    doc = Nokogiri::HTML5.fragment(identity)
    badge = doc.at_css('[aria-label="Edit your profile"]')

    refute_nil badge, "the read page needs a way through to editing"
    assert_equal "a", badge.name
    assert_equal "/profile/edit", badge["href"]
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

  # --- the pages ------------------------------------------------------------------

  def test_the_read_page_renders_its_rows_in_one_card
    doc = Nokogiri::HTML5.fragment(
      render_page(Studio::ProfileSections.defaults.select { |x| x[:page] == :show })
    )

    assert_equal %w[google], doc.css("[data-profile-section]").map { |x| x["data-profile-section"] }
  end

  def test_a_read_page_with_no_rows_still_renders_the_identity
    html = render_page([])

    refute_includes html, "data-profile-section"
    assert_includes html, "Pat Studio", "the header IS the read page when there are no rows"
  end

  # Nothing on the READ page opens a modal, so it must not pay ~40 KB of
  # cropper.js or mount a host for nobody.
  def test_the_read_page_mounts_no_modal_host
    html = render_page(Studio::ProfileSections.defaults.select { |x| x[:page] == :show })

    refute_includes html, "cropper.min.js"
    refute_includes html, "profileModals"
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
