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
    def avatar = @avatar ||= Class.new { def attached? = false }.new
    def avatar_color = "#6366f1"
    def avatar_initials = "PS"
  end

  def view(user: StubUser.new)
    v = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    v.define_singleton_method(:current_user) { user }
    v.define_singleton_method(:profile_path) { "/profile" }
    v.define_singleton_method(:profile_avatar_path) { "/profile/avatar" }
    v.define_singleton_method(:profile_email_path) { "/profile/email" }
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

  # --- the rows ---------------------------------------------------------------

  def avatar_row
    @avatar_row ||= view.render(partial: "studio/profiles/avatar_section", locals: { user: StubUser.new })
  end

  def test_the_avatar_row_renders_with_a_file_field_pointed_at_its_own_route
    doc = Nokogiri::HTML5.fragment(avatar_row)
    form = doc.at_css("form")

    refute_nil form, "expected an upload form"
    assert_equal "/profile/avatar", form["action"],
      "the avatar posts to its OWN route — sharing PATCH /profile purges the attachment"
    refute_nil doc.at_css('input[type="file"][name="profile[avatar]"]')
  end

  def test_the_avatar_row_advertises_only_the_allowed_types
    accept = Nokogiri::HTML5.fragment(avatar_row).at_css('input[x-ref="filePicker"]')["accept"]

    assert_equal Studio::ProfileImage::ALLOWED_CONTENT_TYPES.join(","), accept
    refute_includes accept, "svg", "the picker must not offer a format the server rejects"
  end

  def test_the_avatar_row_shows_the_current_picture
    assert_includes avatar_row, "PS", "an unattached avatar falls back to the initials circle"
  end

  # --- the turf-monster interaction, which is the point of this row -----------
  #
  # The operator named turf's /account avatar as the north star: click the
  # picture, a hover cap says "Update", pick a file, crop it square, and it saves
  # with no Save button. These tests pin the wiring that produces that, because
  # every piece of it is invisible in a screenshot and trivial to break.

  def test_the_avatar_is_the_click_target_and_opens_the_picker
    doc = Nokogiri::HTML5.fragment(avatar_row)
    trigger = doc.at_css('[aria-label="Change your profile photo"]')

    refute_nil trigger, "the avatar itself is the affordance — there is no Save button"
    assert_equal "$refs.filePicker.click()", trigger["@click"]
  end

  # turf's is a <div @click>, which no keyboard or screen-reader user can reach —
  # for them the only way to change a photo would be a mouse. Same visual, but a
  # real button.
  def test_the_click_target_is_keyboard_reachable
    trigger = Nokogiri::HTML5.fragment(avatar_row).at_css('[aria-label="Change your profile photo"]')

    assert_equal "button", trigger.name, "a div is unreachable by keyboard"
    assert_equal "button", trigger["type"], "an untyped button inside a form submits it"
  end

  def test_the_hover_cap_says_update_and_reveals_on_focus_too
    doc = Nokogiri::HTML5.fragment(avatar_row)
    # Find the element that actually REVEALS, then read what it says — rather
    # than finding the words and guessing which ancestor carries the class.
    overlay = doc.css("span").find { |s| s["class"].to_s.include?("group-hover:opacity-100") }

    refute_nil overlay, "the hover cap is what tells someone the picture is clickable"
    assert_equal "Update", overlay.text.strip
    assert_includes overlay["class"], "opacity-0", "the cap is hidden until hover"
    assert_includes overlay["class"], "group-focus:opacity-100",
      "a keyboard user must see the same affordance a mouse user does"
  end

  def test_the_row_saves_immediately_through_the_upload_host
    assert_includes avatar_row, "imageUploadHost(",
      "the crop-then-immediate-save factory is what removes the Save button"
    assert_includes avatar_row, "crop-photo-confirmed.window"
    assert_includes avatar_row, 'x-ref="form"'
    assert_includes avatar_row, 'x-ref="fileInput"'
  end

  # REGRESSION GUARD. turf's call site binds applyCrop($event.detail.blob)
  # directly, which predates the owner token. Every imageUploadHost on a page
  # hears the same window event, so a page that later grows a second uploader
  # would have BOTH hosts save the same crop. onCropConfirmed checks the owner
  # first and costs nothing extra.
  def test_the_crop_confirm_goes_through_the_owner_guard
    assert_includes avatar_row, "onCropConfirmed($event.detail)"
    refute_includes avatar_row, "applyCrop($event.detail",
      "binding applyCrop directly skips the owner guard turf's copy predates"
  end

  # The modal store must be the PAGE's, not the app's shared one — two consumers
  # render no shared host at all, and the two that do ship a fork of it.
  def test_the_row_opens_on_the_page_scoped_store
    assert_includes avatar_row, "store: 'profileModals'"
    refute_includes avatar_row, "Alpine.store('modals')"
  end

  # The saving card must NOT be dismissible. submitFormWithProgress opens it with
  # `dismissible: opts.dismissible === true`, and the scoped host's bfcache /
  # turbo:before-cache cleanup keeps ONLY `dismissible === false` entries — its
  # own comment says "a still-in-flight upload must not silently lose the card
  # its promise will resolve against". Passing the flag through drops the card
  # mid-upload and lets Escape close it. Copied from turf's call site; both
  # engine sibling call sites (studio/emails/show.html.erb) omit it.
  def test_the_saving_card_is_not_dismissible_mid_upload
    refute_includes avatar_row, "dismissible",
      "an upload in flight must keep its saving card"
  end

  def test_the_first_name_row_renders_prefilled_and_capped
    html = view.render(partial: "studio/profiles/first_name_section", locals: { user: StubUser.new })
    doc = Nokogiri::HTML5.fragment(html)
    field = doc.at_css('input[name="profile[first_name]"]')

    refute_nil field, "expected the first-name field"
    assert_equal "Pat", field["value"], "the row shows what is saved, not a blank box"
    assert_equal Studio::FIRST_NAME_MAX_LENGTH.to_s, field["maxlength"]
    assert_equal "/profile", doc.at_css("form")["action"]
  end

  # --- the page ---------------------------------------------------------------

  def test_the_page_renders_each_resolved_section
    html = render_page(Studio::ProfileSections.defaults)
    doc = Nokogiri::HTML5.fragment(html)

    assert_equal %w[avatar first_name email google], doc.css("[data-profile-section]").map { |s| s["data-profile-section"] }
    assert_includes doc.text, "Profile photo"
    assert_includes doc.text, "Your name"
    assert_includes doc.text, "Google account"
  end

  def test_the_page_renders_only_the_rows_it_was_given
    # The controller resolves and filters; the template decides nothing. A page
    # given one row must render one row — this is what makes an app whose model
    # cannot serve a row get a shorter page instead of an error.
    html = render_page(Studio::ProfileSections.defaults.select { |s| s[:key] == :avatar })
    doc = Nokogiri::HTML5.fragment(html)

    assert_equal %w[avatar], doc.css("[data-profile-section]").map { |s| s["data-profile-section"] }
    refute_includes doc.text, "Your name"
  end

  # --- one card, rows inside it ------------------------------------------------

  # The operator's revision (2026-08-14): four separate cards read as four
  # unrelated settings pages stacked up. One card, hairline dividers.
  def test_the_page_renders_one_card_with_the_rows_inside_it
    doc = Nokogiri::HTML5.fragment(render_page(Studio::ProfileSections.defaults))
    cards = doc.css(".card")

    assert_equal 1, cards.length, "the rows share one card, not one card each"
    assert_equal Studio::ProfileSections.defaults.length,
                 cards.first.css("[data-profile-section]").length,
                 "every row lives inside that card"
  end

  # A TOP border on every row but the first, so a row can be added or dropped
  # anywhere without leaving a trailing rule under the last one.
  def test_rows_are_divided_by_a_top_border_except_the_first
    doc = Nokogiri::HTML5.fragment(render_page(Studio::ProfileSections.defaults))
    rows = doc.css("[data-profile-section]")

    refute_includes rows.first["class"], "border-t", "no rule above the first row"
    rows.drop(1).each do |row|
      assert_includes row["class"], "border-t", "#{row["data-profile-section"]} needs its divider"
    end
  end

  # --- the delta-gated buttons -------------------------------------------------

  def test_the_first_name_field_is_prefilled_and_its_button_says_update
    doc = Nokogiri::HTML5.fragment(
      view.render(partial: "studio/profiles/first_name_section", locals: { user: StubUser.new })
    )

    assert_equal "Pat", doc.at_css('input[name="profile[first_name]"]')["value"],
      "a blank field made you retype a name you had already set"
    assert_equal "Update", doc.at_css('input[type="submit"]')["value"]
  end

  # The gate compares TRIMMED values on both sides, so whitespace is not a
  # change — and the controller trims on the way in too, which is what makes the
  # button agree with what the server would actually do.
  def test_the_update_button_is_disabled_until_the_name_actually_changes
    html = view.render(partial: "studio/profiles/first_name_section", locals: { user: StubUser.new })
    submit = Nokogiri::HTML5.fragment(html).at_css('input[type="submit"]')

    assert_equal "value.trim() === initial.trim()", submit[":disabled"]
    # Read the parsed attribute, not the raw markup — the JSON quotes render as
    # &quot; entities.
    x_data = Nokogiri::HTML5.fragment(html).at_css("form")["x-data"]
    assert_equal %({ initial: "Pat", value: "Pat" }), x_data,
      "the delta is measured against what the server rendered"
  end

  # NO-JS FALLBACK. Alpine adds the disabled state on init; a static `disabled`
  # in the markup would leave a page whose JS never ran with a control it can
  # never turn on. The server re-checks regardless.
  def test_the_buttons_are_not_statically_disabled
    %w[first_name_section email_section].each do |partial|
      submit = Nokogiri::HTML5.fragment(
        view.render(partial: "studio/profiles/#{partial}", locals: { user: StubUser.new })
      ).at_css('input[type="submit"]')

      assert_nil submit["disabled"], "#{partial} must not ship a hard-disabled button"
    end
  end

  def test_the_email_button_says_change_and_gates_on_a_real_delta
    html = view.render(partial: "studio/profiles/email_section", locals: { user: StubUser.new })
    submit = Nokogiri::HTML5.fragment(html).at_css('input[type="submit"]')

    assert_equal "Change", submit["value"]
    # Empty, or the address you already have, would spend a real email on nothing.
    assert_equal "value.trim() === '' || value.trim().toLowerCase() === current", submit[":disabled"]
    x_data = Nokogiri::HTML5.fragment(html).at_css("form")["x-data"]
    assert_includes x_data, %(current: "pat@example.com"),
      "the gate compares against the address the server rendered, lowercased"
  end

  def test_an_account_with_no_address_yet_gets_save_not_change
    no_email = Class.new(StubUser) { def email = nil }.new
    submit = Nokogiri::HTML5.fragment(
      view.render(partial: "studio/profiles/email_section", locals: { user: no_email })
    ).at_css('input[type="submit"]')

    assert_equal "Save", submit["value"], "there is no prior owner to ask, so it applies directly"
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

  # --- the page mounts the modals its rows need -------------------------------

  def test_the_page_mounts_a_scoped_modal_host_when_a_row_needs_one
    html = render_page(Studio::ProfileSections.defaults)

    assert_includes html, "profileModals", "the page brings its own modal store"
    assert_includes html, "'crop-photo'"
    assert_includes html, "'saving'"
    assert_includes html, "cropper.min.js", "the crop modal needs cropper.js on the page"
  end

  # REGRESSION GUARD, and the reason this is scoped_host rather than host:
  # mcritchie-studio and turf-monster each ship their own
  # app/views/studio/modals/_host.html.erb, which SHADOWS the engine's in this
  # non-isolated engine — the page would silently get their fork and its
  # registrations, and profileModals would never be registered.
  def test_the_page_uses_the_unforked_scoped_host
    html = render_page(Studio::ProfileSections.defaults)

    refute_includes html, "studio/modals/host",
      "the shared host partial is forked by two consumers and would shadow the engine's"
  end

  # Loaded only where a row can actually open the cropper — a page of plain rows
  # must not pull ~40 KB of cropper.js for nothing.
  def test_a_page_with_no_modal_rows_loads_no_cropper
    html = render_page(Studio::ProfileSections.defaults.reject { |s| s[:modals] })

    refute_includes html, "cropper.min.js"
    refute_includes html, "profileModals"
  end

  def test_a_page_with_no_servable_rows_renders_an_honest_empty_state
    # Reachable: an app with no avatar attachment and no first_name column
    # resolves to zero rows. A blank page would read as broken.
    html = render_page([])

    assert_includes html, "Nothing to edit yet"
    refute_includes html, "data-profile-section"
  end

  def test_a_host_section_renders_with_its_own_locals
    # The extension seam, exercised end to end rather than asserted: a host row
    # naming its own partial and passing locals must render like any other.
    v = view
    v.instance_variable_set(:@profile_sections, [
      { key: :note, title: "Host row", partial: "studio/profiles/first_name_section", locals: {} }
    ])
    html = v.render(template: "studio/profiles/show")

    assert_includes html, "Host row"
    assert_includes html, 'data-profile-section="note"'
  end
end
