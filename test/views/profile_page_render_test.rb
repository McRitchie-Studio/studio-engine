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

  def test_the_avatar_row_renders_with_a_file_field_pointed_at_its_own_route
    html = view.render(partial: "studio/profiles/avatar_section", locals: { user: StubUser.new })
    doc = Nokogiri::HTML5.fragment(html)
    form = doc.at_css("form")

    refute_nil form, "expected an upload form"
    assert_equal "/profile/avatar", form["action"],
      "the avatar posts to its OWN route — sharing PATCH /profile purges the attachment"
    refute_nil doc.at_css('input[type="file"][name="profile[avatar]"]')
  end

  def test_the_avatar_row_advertises_only_the_allowed_types
    html = view.render(partial: "studio/profiles/avatar_section", locals: { user: StubUser.new })
    accept = Nokogiri::HTML5.fragment(html).at_css('input[type="file"]')["accept"]

    assert_equal Studio::ProfileImage::ALLOWED_CONTENT_TYPES.join(","), accept
    refute_includes accept, "svg", "the picker must not offer a format the server rejects"
  end

  def test_the_avatar_row_shows_the_current_picture
    html = view.render(partial: "studio/profiles/avatar_section", locals: { user: StubUser.new })

    assert_includes html, "PS", "an unattached avatar falls back to the initials circle"
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
