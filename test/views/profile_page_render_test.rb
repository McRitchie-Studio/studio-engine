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
    def avatar = @avatar ||= Class.new { def attached? = false }.new
    def avatar_color = "#6366f1"
    def avatar_initials = "PS"
  end

  def view(user: StubUser.new)
    v = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    v.define_singleton_method(:current_user) { user }
    v.define_singleton_method(:profile_path) { "/profile" }
    v.define_singleton_method(:profile_avatar_path) { "/profile/avatar" }
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

    assert_equal %w[avatar first_name], doc.css("[data-profile-section]").map { |s| s["data-profile-section"] }
    assert_includes doc.text, "Profile photo"
    assert_includes doc.text, "Your name"
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
