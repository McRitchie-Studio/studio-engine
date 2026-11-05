# frozen_string_literal: true

require "test_helper"
require "action_view"
require "nokogiri"
require_relative "../../app/helpers/studio_icon_helper"

# Renders the link-sidebar family (components/_link_sidebar, _sidebar_panel,
# _link_sidebar_trigger) through ActionView and pins the emitted contract:
# dual desktop/mobile panels driven by the `sidebars` Alpine store, the anchor
# for the link-sidebar controller (the store flag and the click handlers are
# studio/link_sidebar), the panel's title and name, section/link rendering (groups
# with no label word unless a section opts in to a header, one line a row at rest, emoji
# swap), and the trigger's aria wiring.
class LinkSidebarTest < Minitest::Test
  SECTIONS = [
    { title: "Site", links: [
      { label: "Home", href: "/", emoji: "🏠", desc: "Front door" },
      { label: "Docs", href: "/docs", emoji: "📚", hover_emoji: "🔎", target: "_blank" }
    ] },
    { title: "Ops", admin: true, links: [
      { label: "Errors", href: "/error_logs", emoji: "🚨" }
    ] }
  ].freeze

  def test_renders_dual_panels_with_sections_and_the_controller_anchor
    html = render_sidebar(sections: SECTIONS, admin: true)
    doc = Nokogiri::HTML5.fragment(html)

    desktop = doc.at_css("#studio-link-sidebar")
    mobile  = doc.at_css("#studio-link-sidebar-mobile")
    refute_nil desktop, "expected the desktop panel"
    refute_nil mobile, "expected the mobile panel"
    assert_includes desktop["class"], "hidden md:flex"
    assert_includes mobile["class"], "md:hidden"
    assert_includes desktop["class"], "studio-link-sidebar-layer"
    assert_equal "$store.sidebars.linkTreeOpen", desktop["x-show"]
    refute_nil desktop["x-cloak"], "panel must cloak until Alpine boots"

    anchors = doc.css('template[data-studio-controller="link-sidebar"]')
    assert_equal 1, anchors.size, "one anchor for the link-sidebar controller"
    refute_match(/<script/i, html, "the flag and the handlers are studio/link_sidebar, a nonced module")
    assert_includes desktop["@turbo:before-cache.window"], "$store.sidebars.linkTreeOpen = false"
    assert_includes html, "html { overflow-x: clip; }"
  end

  def test_renders_links_and_emoji_swap
    html = render_sidebar(sections: SECTIONS, admin: true)

    assert_includes html, %(href="/docs")
    assert_includes html, %(target="_blank")
    assert_includes html, %(rel="noopener")
    assert_includes html, "studio-emoji-swap", "hover_emoji links render through emoji_swap"
  end

  # --- no label word, and the groups stay apart ------------------------------

  def test_no_section_shows_a_label_word_by_default
    [[true, SECTIONS], [false, [SECTIONS.first]]].each do |admin, sections|
      doc = Nokogiri::HTML5.fragment(render_sidebar(sections: sections, admin: admin))

      refute_includes doc.at_css("#studio-link-sidebar nav").text, "Site"
      refute_includes doc.at_css("#studio-link-sidebar nav").text, "Ops"
      refute_includes doc.at_css("#studio-link-sidebar nav").text, "ADMIN"
      assert_empty doc.css("#studio-link-sidebar .label-upper")
    end
  end

  def test_each_group_keeps_its_words_as_an_accessible_name
    doc = Nokogiri::HTML5.fragment(render_sidebar(sections: SECTIONS, admin: true, geo_flag: true, geo_routes: true))

    names = doc.css('#studio-link-sidebar nav > [role="group"]').map { |group| group["aria-label"] }
    assert_equal ["Site", "Ops, admin", "Geo, admin"], names
  end

  # --- the opt-in header ------------------------------------------------------

  def headed_sections
    [
      { title: "My Apps", header: true, links: [{ label: "Home", href: "/", emoji: "*" }] },
      { title: "Help", links: [{ label: "Docs", href: "/docs", emoji: "*" }] },
      { title: "Admin", admin: true, header: true, links: [{ label: "Errors", href: "/up", emoji: "*" }] }
    ]
  end

  def groups_in(doc, panel = "#studio-link-sidebar")
    doc.css(%(#{panel} nav > [role="group"]))
  end

  def test_a_section_with_header_true_shows_its_title_above_its_rows
    groups = groups_in(Nokogiri::HTML5.fragment(render_sidebar(sections: headed_sections, admin: true)))
    header = groups[0].element_children.first

    assert_equal "My Apps", header.text
    assert_includes header["class"].split, "label-upper"
    assert_includes header["class"].split, "truncate", "a long title stays on one line"
    assert_equal "a", groups[0].element_children[1].name, "the rows follow the header"
    assert_equal "Admin", groups[2].element_children.first.text
  end

  def test_a_section_with_no_header_key_or_header_false_shows_no_word
    sections = headed_sections + [{ title: "Off", header: false, links: [{ label: "Off", href: "/off", emoji: "*" }] }]
    doc = Nokogiri::HTML5.fragment(render_sidebar(sections: sections, admin: true))
    groups = groups_in(doc)

    assert_empty groups[1].css("[data-sidebar-group-header]")
    assert_empty groups[3].css("[data-sidebar-group-header]")
    refute_includes groups[1].text, "Help"
    assert_equal 2, doc.css("#studio-link-sidebar [data-sidebar-group-header]").size
  end

  def test_a_declared_string_key_header_opts_in_too
    sections = [{ "title" => "My Apps", "header" => true, "links" => [{ "label" => "Home", "href" => "/", "emoji" => "*" }] }]
    doc = Nokogiri::HTML5.fragment(render_sidebar(sections: sections, admin: false))

    assert_equal ["My Apps"], doc.css("#studio-link-sidebar [data-sidebar-group-header]").map(&:text)
  end

  def test_a_header_with_a_blank_title_draws_nothing
    [nil, "", "  "].each do |title|
      sections = [{ title: title, header: true, links: [{ label: "Home", href: "/", emoji: "*" }] }]
      doc = Nokogiri::HTML5.fragment(render_sidebar(sections: sections, admin: false))

      assert_empty doc.css("[data-sidebar-group-header]"), "title #{title.inspect}"
    end
  end

  # The group's aria-label names it, so the word on screen stays out of the accessibility
  # tree: a screen reader says it once. It carries no id, as both panels render this body.
  def test_a_header_keeps_the_group_name_and_is_not_announced_twice
    doc = Nokogiri::HTML5.fragment(render_sidebar(sections: headed_sections, admin: true))
    headers = doc.css("#studio-link-sidebar [data-sidebar-group-header]")

    assert_equal ["My Apps", "Help", "Admin"], groups_in(doc).first(3).map { |group| group["aria-label"] }
    assert(headers.all? { |header| header["aria-hidden"] == "true" })
    assert(headers.none? { |header| header["id"] })
    assert_nil groups_in(doc).first["aria-labelledby"]
  end

  def test_a_headed_admin_section_says_admin_in_its_name_and_shows_no_chip
    sections = [{ title: "Ops", admin: true, header: true, links: [{ label: "Errors", href: "/up", emoji: "*" }] }]
    doc = Nokogiri::HTML5.fragment(render_sidebar(sections: sections, admin: true))

    assert_equal "Ops, admin", groups_in(doc).first["aria-label"]
    assert_equal "Ops", doc.at_css("#studio-link-sidebar [data-sidebar-group-header]").text
    refute_includes doc.at_css("#studio-link-sidebar nav").text, "ADMIN"
  end

  def test_a_header_is_not_a_click_target_and_sits_outside_every_row
    doc = Nokogiri::HTML5.fragment(render_sidebar(sections: headed_sections, admin: true))

    doc.css("#studio-link-sidebar [data-sidebar-group-header]").each do |header|
      assert_equal "div", header.name
      assert_empty header.css("a, button"), "no control inside the header"
      assert_empty header.ancestors("a, button"), "no control around the header"
      assert_empty header.attribute_nodes.map(&:name).grep(/\A(@|x-on|href|tabindex|role)/), "no handler or focus stop"
    end
  end

  def test_a_header_keeps_the_divider_and_shows_in_both_panels
    doc = Nokogiri::HTML5.fragment(render_sidebar(sections: headed_sections, admin: true))

    first, second, third = groups_in(doc).first(3).map { |group| group["class"].split }
    refute_includes first, "border-t"
    assert_includes second, "border-t"
    assert_includes third, "border-t"
    assert_equal ["My Apps", "Admin"], doc.css("#studio-link-sidebar-mobile [data-sidebar-group-header]").map(&:text)
  end

  def test_a_title_is_escaped_in_the_header
    sections = [{ title: "<b>Apps</b>", header: true, links: [{ label: "Home", href: "/", emoji: "*" }] }]
    doc = Nokogiri::HTML5.fragment(render_sidebar(sections: sections, admin: false))
    header = doc.at_css("#studio-link-sidebar [data-sidebar-group-header]")

    assert_equal "<b>Apps</b>", header.text
    assert_empty header.element_children
  end

  def test_the_rows_of_a_headed_group_are_the_rows_of_an_unheaded_one
    links = [{ label: "Home", href: "/", emoji: "*", desc: "Front door" }, { label: "Docs", href: "/docs", emoji: "*" }]
    rows = [true, false].map do |header|
      doc = Nokogiri::HTML5.fragment(render_sidebar(sections: [{ title: "Site", header: header, links: links }], admin: false))
      doc.css("#studio-link-sidebar nav a").map(&:to_html)
    end

    assert_equal rows[1], rows[0]
  end

  # Cyvasse, Industries and Commercial Welding name their admin section "Admin".
  def test_a_group_named_admin_does_not_say_it_twice
    sections = ["Admin", "Admin tools", "Administrators"].map do |title|
      { title: title, admin: true, links: [{ label: title, href: "/#{title.parameterize}", emoji: "*" }] }
    end
    doc = Nokogiri::HTML5.fragment(render_sidebar(sections: sections, admin: true))

    assert_equal ["Admin", "Admin tools", "Administrators, admin"],
                 doc.css('#studio-link-sidebar nav > [role="group"]').first(3).map { |group| group["aria-label"] }
  end

  def test_a_divider_separates_the_groups_and_none_tops_the_first
    doc = Nokogiri::HTML5.fragment(render_sidebar(sections: SECTIONS, admin: true))

    first, second = doc.css('#studio-link-sidebar nav > [role="group"]').map { |group| group["class"].split }
    refute_includes first, "border-t"
    assert_includes second, "border-t"
    assert_includes second, "border-subtle"
  end

  def test_a_section_with_no_links_draws_no_group
    sections = [SECTIONS.first, { title: "Empty", links: [] }, { title: "Last", links: [{ label: "End", href: "/end", emoji: "*" }] }]
    doc = Nokogiri::HTML5.fragment(render_sidebar(sections: sections, admin: false))

    assert_equal %w[Site Last], doc.css('#studio-link-sidebar nav > [role="group"]').map { |group| group["aria-label"] }
  end

  # --- one line a row at rest ------------------------------------------------

  def test_every_row_centers_its_icon_and_a_desc_rides_absolute_for_the_hover
    doc = Nokogiri::HTML5.fragment(render_sidebar(sections: SECTIONS, admin: true))

    %w[/ /docs /error_logs].each do |href|
      row = doc.at_css(%(#studio-link-sidebar a[href="#{href}"]))["class"].split
      assert_includes row, "items-center", href
      refute_includes row, "items-start", href
    end

    described = doc.at_css(%(#studio-link-sidebar a[href="/"]))
    refute_nil described["data-sidebar-row-described"]
    assert_equal "Front door", described.at_css("[data-sidebar-row-desc]").text
    assert_includes described.at_css("[data-sidebar-row-desc]")["class"].split, "truncate"
  end

  def test_a_row_with_no_desc_has_nothing_to_show_on_hover
    doc = Nokogiri::HTML5.fragment(render_sidebar(sections: SECTIONS, admin: true))
    row = doc.at_css(%(#studio-link-sidebar a[href="/error_logs"]))

    assert_nil row["data-sidebar-row-described"]
    assert_nil row.at_css("[data-sidebar-row-label]")
    assert_nil row.at_css("[data-sidebar-row-desc]")
  end

  def test_the_description_stays_out_of_layout_in_the_stylesheet
    css = File.read(File.expand_path("../../app/assets/tailwind/studio_engine/engine.css", __dir__))
    rule = css[/^\s*\[data-sidebar-row-desc\] \{(.*?)\}/m, 1]

    assert_includes rule, "position: absolute;"
    assert_includes rule, "opacity: 0;"
  end

  def test_the_live_geo_row_is_one_line_with_its_gloss_on_hover
    doc = Nokogiri::HTML5.fragment(render_sidebar(sections: SECTIONS, admin: true, geo_flag: true, geo_routes: true))
    row = doc.at_css(%(#studio-link-sidebar a[href="/admin/geo"]))

    assert_includes row["class"].split, "items-center"
    refute_nil row["data-sidebar-row-described"]
    assert_equal "Geo", row.at_css("[data-sidebar-row-label]").text
    assert_equal "Country and subdivision blocking", row.at_css("[data-sidebar-row-desc]").text
  end

  # The row that cannot link is one line too. Its description holds only the string to
  # copy, and tabindex lets a tap and a key reach it.
  def test_the_disabled_geo_row_is_one_line_with_the_fix_as_its_description
    doc = Nokogiri::HTML5.fragment(render_sidebar(sections: SECTIONS, admin: true, geo_flag: false, geo_routes: false))
    row = doc.at_css('#studio-link-sidebar [data-test="geo-signpost-disabled"]')

    assert_includes row["class"].split, "items-center"
    refute_nil row["data-sidebar-row-described"]
    assert_equal "0", row["tabindex"]
    assert_equal "config.draw_geo_routes = true", row.at_css("[data-sidebar-row-desc]").text
    assert_includes row["title"], "config/initializers/studio.rb", "the long form stays in the title"
  end

  def test_a_plain_emoji_sits_in_the_swaps_box
    doc = Nokogiri::HTML5.fragment(render_sidebar(sections: SECTIONS, admin: true, geo_flag: true, geo_routes: true))

    assert_includes doc.at_css(%(#studio-link-sidebar a[href="/error_logs"]))&.at_css("span")&.[]("class").to_s.split, "studio-emoji-box"
    assert_includes doc.at_css(%(#studio-link-sidebar a[href="/admin/geo"]))&.at_css("span")&.[]("class").to_s.split, "studio-emoji-box"
    css = Studio::UiPrimitives::EMOJI_SWAP_CSS
    assert_match(/\.studio-emoji-box,\s*\.studio-emoji-swap,\s*\.nav-emoji-swap \{/, css, "one rule, one box")
  end

  # --- the panel's title and its name ----------------------------------------

  def test_a_signed_in_panel_titles_itself_with_the_navbars_name
    [true, false].each do |admin|
      doc = Nokogiri::HTML5.fragment(render_sidebar(sections: [SECTIONS.first], admin: admin, user: named_user("Alex")))

      %w[#studio-link-sidebar #studio-link-sidebar-mobile].each do |panel|
        title = doc.at_css("#{panel} [data-link-sidebar-title]")
        assert_equal "Alex", title.text, "#{panel}, admin: #{admin}"
        assert_nil doc.at_css("#{panel} [data-link-sidebar-greeting]"), "a signed-in title is not a greeting"
      end
      refute_includes doc.to_html, ">Links<"
      refute_includes doc.to_html, "Admin Menu"
    end
  end

  # The same call the navbar makes, so a host's name setting reaches both.
  def test_the_title_follows_the_hosts_name_setting
    previous = Studio.navbar_user_name
    Studio.navbar_user_name = ->(user) { "#{user.first_name} the Host" }
    doc = Nokogiri::HTML5.fragment(render_sidebar(sections: [SECTIONS.first], admin: false, user: named_user("Alex")))

    assert_equal "Alex the Host", doc.at_css("#studio-link-sidebar [data-link-sidebar-title]").text
  ensure
    Studio.navbar_user_name = previous
  end

  def test_a_long_name_truncates_and_keeps_its_full_text_for_a_pointer
    long = "Bartholomew Fitzgerald-Wellington"
    doc = Nokogiri::HTML5.fragment(render_sidebar(sections: [SECTIONS.first], admin: false, user: named_user(long)))
    title = doc.at_css("#studio-link-sidebar [data-link-sidebar-title]")

    assert_includes title["class"].split, "truncate"
    assert_equal long, title["title"]
  end

  def test_a_name_is_escaped
    doc_html = render_sidebar(sections: [SECTIONS.first], admin: false, user: named_user("<b>Al</b>"))

    refute_includes doc_html, "<b>Al</b>"
  end

  def test_a_signed_out_panel_titles_itself_with_a_greeting_and_omits_the_logout_footer
    html = render_sidebar(sections: [SECTIONS.first], admin: false, logged_in: false)
    doc = Nokogiri::HTML5.fragment(html)

    %w[#studio-link-sidebar #studio-link-sidebar-mobile].each do |panel|
      title = doc.at_css("#{panel} [data-link-sidebar-title][data-link-sidebar-greeting]")
      refute_nil title, "#{panel}: studio/link_sidebar writes over this element"
      assert_includes ["Good morning", "Good afternoon", "Good evening"], title.text
    end
    refute_includes html, ">Links<"
    refute_includes html, "Log out"
  end

  def test_a_signed_in_panel_shows_the_logout_footer
    html = render_sidebar(sections: [SECTIONS.first], admin: false, user: named_user("Alex"))

    assert_includes html, "Log out"
    assert_includes html, "/logout"
  end

  # The visible title is a name or a greeting, neither of which names a menu. The
  # panel's own name stays, through aria-label and not aria-labelledby.
  def test_the_panel_keeps_its_accessible_name_at_every_level
    [
      [{ admin: true, user: named_user("Alex") }, "Admin menu"],
      [{ admin: false, user: named_user("Alex") }, "Links menu"],
      [{ admin: false, logged_in: false }, "Links menu"]
    ].each do |viewer, name|
      doc = Nokogiri::HTML5.fragment(render_sidebar(sections: [SECTIONS.first], **viewer))

      %w[#studio-link-sidebar #studio-link-sidebar-mobile].each do |panel|
        assert_equal name, doc.at_css(panel)["aria-label"], viewer.inspect
        assert_nil doc.at_css(panel)["aria-labelledby"], "the title never names the panel"
      end
    end
  end

  def test_trigger_wires_aria_to_both_panels
    html = view(sections: [], admin: false)
           .render(partial: "components/link_sidebar_trigger", locals: { class_name: "hidden md:inline-flex" })
    doc = Nokogiri::HTML5.fragment(html)
    button = doc.at_css("button[data-link-sidebar-trigger]")

    refute_nil button
    assert_equal "studio-link-sidebar studio-link-sidebar-mobile", button["aria-controls"]
    assert_equal "dialog", button["aria-haspopup"]
    assert_includes button["class"], "hidden md:inline-flex"
    assert_includes button["@click.stop"], "$store.sidebars.linkTreeOpen"
  end

  # Regression pin (industries wave-1): the base class string used to hardcode
  # inline-flex AFTER the caller's class_name, so `hidden md:inline-flex` lost
  # the cascade and the desktop trigger rendered on mobile beside the real
  # mobile trigger. The caller owns the display class; bare renders default it.
  def test_trigger_class_name_owns_the_display_class
    html = view(sections: [], admin: false)
           .render(partial: "components/link_sidebar_trigger", locals: { class_name: "hidden md:inline-flex" })
    classes = Nokogiri::HTML5.fragment(html).at_css("button")["class"].split

    assert_includes classes, "hidden"
    assert_includes classes, "md:inline-flex"
    refute_includes classes, "inline-flex",
                    "a bare inline-flex token beats the caller's hidden in the cascade"
  end

  def test_trigger_defaults_to_inline_flex_without_class_name
    html = view(sections: [], admin: false)
           .render(partial: "components/link_sidebar_trigger")
    classes = Nokogiri::HTML5.fragment(html).at_css("button")["class"].split

    assert_includes classes, "inline-flex"
    refute_includes classes, "hidden"
  end

  # --- the geo signpost: THE REACH THIS PANEL OWES ---------------------------
  #
  # These are the tests whose absence let the gap ship. The 0.58.0 signpost went
  # into components/_admin_dropdown under the premise that the shared dropdown
  # reaches every app "from one change" — and this panel is precisely where that
  # premise breaks: wherever the host declares an admin-flagged section, the
  # engine SUPPRESSES the dropdown (studio_sidebar_replaces_admin_menu?, so two
  # cog glyphs do not read as a double gear) and this panel becomes the admin
  # menu. mcritchie-studio is that app — layouts/application.html.erb renders
  # this partial and link_tree_helper.rb stamps admin: true — so the app with
  # the largest admin surface in the ecosystem was the one guaranteed never to
  # see the row. A dropdown-only test can never catch that; this one does.

  def test_the_sidebar_carries_the_geo_signpost_for_an_admin
    html = render_sidebar(sections: SECTIONS, admin: true, geo_flag: true, geo_routes: true)
    doc = Nokogiri::HTML5.fragment(html)

    refute_nil doc.at_css(%(a[href="/admin/geo"])), "a sidebar-chrome app must reach the geo manager"
    assert_includes html, ">Geo<", "and the row must say what it is"
  end

  def test_the_geo_row_is_on_by_default_and_a_host_may_take_it_out
    assert_equal true, Studio.sidebar_geo_signpost

    previous = Studio.sidebar_geo_signpost
    on = render_sidebar(sections: SECTIONS, admin: true, geo_flag: true, geo_routes: true)
    Studio.sidebar_geo_signpost = false
    off = render_sidebar(sections: SECTIONS, admin: true, geo_flag: true, geo_routes: true)
    off_disabled = render_sidebar(sections: SECTIONS, admin: true, geo_flag: false, geo_routes: false)

    assert_equal ["Site", "Ops, admin", "Geo, admin"], group_names(on)
    assert_equal ["Site", "Ops, admin"], group_names(off), "no Geo group, so no stray divider"
    assert_includes on, "/admin/geo"
    refute_includes off, "/admin/geo"
    refute_includes off_disabled, "geo-signpost-disabled"
  ensure
    Studio.sidebar_geo_signpost = previous
  end

  def group_names(html)
    Nokogiri::HTML5.fragment(html).css('#studio-link-sidebar nav > [role="group"]').map { |group| group["aria-label"] }
  end

  # Signage, not silence, for an app that has not turned geo on — the same
  # contract the dropdown carries, in the chrome that suppresses the dropdown.
  def test_the_sidebar_signposts_geo_even_where_it_is_unreachable
    html = render_sidebar(sections: SECTIONS, admin: true, geo_flag: false, geo_routes: false)

    assert_includes html, "geo-signpost-disabled"
    assert_includes html, "config.draw_geo_routes = true"
    refute_includes html, "/admin/geo", "a row you are told is off must not be linked"
  end

  # Admin chrome, like every other admin row here. The panel renders for signed-in
  # non-admins too (public sections), and geo signage is not theirs.
  def test_the_geo_signpost_is_admin_only
    html = render_sidebar(sections: [SECTIONS.first], admin: false, geo_flag: true, geo_routes: true)

    refute_includes html, ">Geo<"
    refute_includes html, "/admin/geo"
  end

  # EXACTLY ONE HOME PER APP. A host declaring only PUBLIC sections keeps the
  # admin dropdown — the engine navbar renders BOTH chromes for that shape,
  # deliberately, so its admins never lose Theme/Navbar/Error Logs. Signposting
  # geo here as well would show such an admin the same row twice, in two menus
  # open at the same time. Fixing a reach gap by double-signing is not a fix.
  def test_the_sidebar_yields_the_signpost_when_it_is_not_the_admin_menu
    html = render_sidebar(sections: [SECTIONS.first], admin: true, geo_flag: true, geo_routes: true)

    refute_includes html, ", admin",
                     "precondition: no admin-flagged section, so the dropdown is NOT suppressed"
    refute_includes html, "/admin/geo", "the dropdown carries the row for this shape"
    refute_includes html, ">Geo<"
  end

  # The panel closes behind the row, driven by THIS panel's store flag — the
  # partial takes the expression from its caller so a forked chrome can pass its
  # own (turf-monster's gear sidebar drives gearOpen, not linkTreeOpen).
  def test_the_geo_row_closes_the_panel_behind_it
    html = render_sidebar(sections: SECTIONS, admin: true, geo_flag: true, geo_routes: true)
    row = Nokogiri::HTML5.fragment(html).at_css(%(a[href="/admin/geo"]))

    assert_equal "$store.sidebars.linkTreeOpen = false", row["@click"]
  end

  def test_both_panels_ask_for_the_blurred_edge
    doc = Nokogiri::HTML5.fragment(render_sidebar(sections: SECTIONS, admin: true))

    %w[#studio-link-sidebar #studio-link-sidebar-mobile].each do |panel|
      assert_equal "", doc.at_css(panel)["data-sidebar-edge"], panel
    end
  end

  # THE SIDEBAR CLAIMS ONLY THE CLOSE BUTTONS IT RENDERED.
  #
  # components/_sidebar_panel is shared and stamps `data-link-sidebar-close` on every
  # panel's close button. studio/link_sidebar claims that attribute on the document, in
  # the capture phase, so its claim is scoped to the two panels this partial renders:
  # unscoped, it takes the close click of every other panel on the page.
  #
  # The behaviour is test/javascript/link_sidebar.test.mjs (click intent) and
  # e2e/sidebar_panel_close.spec.js (which listener runs first). This tier holds the
  # seam between the two files: the ids the module scopes to are the ids rendered here,
  # each with the close button the module claims.
  def test_the_module_scopes_its_close_claim_to_the_panels_rendered_here
    source = File.read(File.expand_path("../../app/javascript/studio/link_sidebar.js", __dir__))
    scope = source[/^export const LINK_SIDEBAR_PANELS = "([^"]+)"/, 1]
    refute_nil scope, "studio/link_sidebar must declare LINK_SIDEBAR_PANELS once"

    doc = Nokogiri::HTML5.fragment(render_sidebar(sections: SECTIONS, admin: true))
    ids = scope.split(",").map(&:strip)
    assert_equal %w[#studio-link-sidebar #studio-link-sidebar-mobile], ids
    ids.each do |id|
      refute_nil doc.at_css("#{id} [data-link-sidebar-close]"),
                 "#{id} must render the close button the module claims"
    end
    assert_equal ids.size, doc.css("aside").size, "every panel rendered here is in the module's scope"
  end

  # --- Studio.sidebar_style = :glass ------------------------------------------

  GLASS_SECTIONS = [
    { title: "My Apps", header: true, links: [
      { label: "Team Voice Notes to Webhook", href: "/apps/voice", emoji: "🐶", hover_emoji: "🚀" }
    ] },
    { title: "Admin", header: true, links: [
      { label: "Dashboard", href: "/admin", emoji: "📊", hover_emoji: "🔬", icon: "chart-column", desc: "Users + logs" },
      { label: "Odd", href: "/odd", emoji: "🦄", icon: "no-such-icon" }
    ] }
  ].freeze

  def test_the_default_style_ignores_icons_and_marks_no_current_row
    html = render_sidebar(sections: GLASS_SECTIONS, admin: true, path: "/admin")
    doc = Nokogiri::HTML5.fragment(html)

    %w[studio-link-sidebar studio-link-sidebar-mobile].each do |id|
      panel = doc.at_css("##{id}")
      assert_includes panel["class"], "bg-surface border-l border-subtle shadow-2xl"
      refute_nil panel["data-sidebar-edge"]
      assert_nil panel["data-sidebar-glass"]
    end
    assert_empty doc.css("svg[stroke]"), "no line icon under the default style"
    assert_empty doc.css("[aria-current]")
    assert_empty doc.css("[data-sidebar-glass-shell], [data-sidebar-glass-head], [data-sidebar-glass-foot]")
    assert_includes html, "👋"
    assert_includes doc.at_css('[role="group"] + [role="group"]')["class"], "border-t"
  end

  def test_glass_panels_turn_the_edge_off_and_mark_the_shell
    doc = glass_doc(path: "/admin")

    %w[studio-link-sidebar studio-link-sidebar-mobile].each do |id|
      panel = doc.at_css("##{id}")
      refute_nil panel["data-sidebar-glass"]
      assert_nil panel["data-sidebar-edge"], "the whole panel blurs, so the separate strip is off"
      refute_includes panel["class"], "bg-surface"
      refute_nil panel["data-pin-edge"], "the aside keeps its geometry"
      assert_equal "translate-x-full", panel["x-transition:enter-start"], "the aside keeps its slide"
      assert_equal 1, panel.css("> [data-sidebar-glass-shell]").size
      assert_equal 1, panel.css("[data-sidebar-glass-foot]").size
    end
    refute_includes doc.at_css('[role="group"] + [role="group"]')["class"], "border-t", "headers group the rows, not lines"
  end

  def test_a_glass_row_draws_its_line_icon_with_no_swap
    row = glass_row("Dashboard", path: "/")

    refute_nil row.at_css("[data-sidebar-row-icon] svg")
    assert_nil row.at_css(".studio-emoji-swap"), "a line icon row has no hover swap"
    refute_includes row.text, "📊"
  end

  def test_a_glass_row_with_no_icon_keeps_its_portrait_and_swap
    row = glass_row("Team Voice Notes to Webhook", path: "/")

    assert_nil row.at_css("svg")
    assert_equal "🚀", row.at_css(".studio-emoji-swap-hover").text
    assert_equal "🐶", row.at_css(".studio-emoji-swap-base").text
    assert_includes row["class"], "group"
  end

  def test_a_glass_row_whose_icon_is_unknown_falls_back_to_its_emoji
    row = glass_row("Odd", path: "/")

    assert_nil row.at_css("svg")
    assert_includes row.text, "🦄"
  end

  def test_glass_marks_the_current_row_in_both_panels_and_only_that_row
    doc = glass_doc(path: "/admin")

    current = doc.css('a[aria-current="page"]')
    assert_equal 2, current.size, "one row in each panel"
    assert_equal ["/admin"], current.map { |row| row["href"] }.uniq
  end

  def test_glass_marks_no_row_on_a_page_without_one
    assert_empty glass_doc(path: "/nowhere").css("[aria-current]")
  end

  def test_a_glass_row_keeps_its_hover_description
    row = glass_row("Dashboard", path: "/")

    refute_nil row["data-sidebar-row-described"]
    assert_equal "Users + logs", row.at_css("[data-sidebar-row-desc]").text
  end

  def test_glass_log_out_is_a_line_icon_in_its_own_footer
    foot = glass_doc(path: "/").at_css("#studio-link-sidebar [data-sidebar-glass-foot]")

    refute_nil foot.at_css('a[href="/logout"] svg')
    refute_includes foot.text, "👋"
    assert_empty foot.ancestors("nav"), "Log out sits outside the scrolling list"
  end

  def test_glass_renders_with_no_request_and_lights_nothing
    html = with_glass { render_sidebar(sections: GLASS_SECTIONS, admin: true) }

    assert_empty Nokogiri::HTML5.fragment(html).css("[aria-current]")
  end

  def test_glass_marks_the_geo_row_on_its_own_page
    html = with_glass { render_sidebar(sections: GLASS_SECTIONS + [{ title: "Ops", admin: true, links: [{ label: "Admin", href: "/admin", emoji: "🛠" }] }], admin: true, geo_flag: true, geo_routes: true, path: "/admin/geo") }
    rows = Nokogiri::HTML5.fragment(html).css('#studio-link-sidebar a[aria-current="page"]')

    assert_equal ["/admin/geo"], rows.map { |row| row["href"] }
  end

  # Safari and Firefox do not know prefers-reduced-transparency, so a not query is false there
  # too and the blur never reaches them. The browser lane runs Chromium only, which knows the
  # feature, so it cannot see this. This is the guard.
  def test_the_blur_answers_to_supports_alone_and_the_setting_undoes_it
    css = glass_stylesheet

    refute_match(/@media\s+not\s*\(prefers-reduced-transparency/, css)
    block = css[/@supports \(\(backdrop-filter: blur\(1px\)\).*?\n    \}\n/m]
    refute_nil block
    blur, undo = block.split("@media (prefers-reduced-transparency: reduce)")
    %w[-webkit-backdrop-filter backdrop-filter].each do |property|
      assert_match(/^\s*#{property}: var\(--glass-filter\);/, blur)
      assert_match(/^\s*#{property}: none;/, undo)
    end
    assert_includes undo, "background-color: var(--glass-fill);"
  end

  # A headless WebKit paints the thin fill with no visible blur. If a real browser does too, the
  # fill alone has to carry the text, over the page that is worst for each theme.
  def test_the_thin_fill_alone_keeps_resting_text_at_4_5_to_1
    css = glass_stylesheet
    light = css[/^\s*\[data-sidebar-glass-shell\] \{\s*--glass-row-height.*?\n    \}/m]
    dark = css[/^\s*\.dark \[data-sidebar-glass-shell\] \{.*?\n    \}/m]

    { dark => [255, 255, 255], light => [0, 0, 0] }.each do |tokens, page|
      fill, alpha = thin_fill(tokens)
      seen = fill.zip(page).map { |ink, under| (alpha * ink) + ((1 - alpha) * under) }
      %w[--glass-ink --glass-soft-ink].each do |token|
        ink = tokens[/#{token}: #(\h{6})/, 1].scan(/../).map { |pair| pair.to_i(16) }
        assert_operator contrast(ink, seen), :>=, 4.5, "#{token} over #{page.inspect}"
      end
    end
  end

  def test_the_panel_without_glass_is_untouched_for_other_callers
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    html = view.render(partial: "components/sidebar_panel", locals: { open: "x", edge: true, id: "p" })
    panel = Nokogiri::HTML5.fragment(html).at_css("#p")

    assert_includes panel["class"], "bg-surface border-l border-subtle shadow-2xl"
    refute_nil panel["data-sidebar-edge"]
    assert_nil panel["data-sidebar-glass"]
  end

  private

  def glass_stylesheet
    File.read(File.expand_path("../../app/assets/tailwind/studio_engine/engine.css", __dir__))
  end

  def thin_fill(tokens)
    red, green, blue, alpha = tokens.match(%r{--glass-thin-fill: rgb\((\d+) (\d+) (\d+) / ([\d.]+)\)}).captures
    [[red, green, blue].map(&:to_f), alpha.to_f]
  end

  def contrast(one, other)
    lighter, darker = [one, other].map { |rgb| luminance(rgb) }.minmax.reverse
    (lighter + 0.05) / (darker + 0.05)
  end

  def luminance(rgb)
    red, green, blue = rgb.map do |channel|
      value = channel / 255.0
      value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055)**2.4
    end
    (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
  end

  def with_glass
    prior = Studio.sidebar_style
    Studio.sidebar_style = :glass
    yield
  ensure
    Studio.sidebar_style = prior
  end

  def glass_doc(path:)
    Nokogiri::HTML5.fragment(with_glass { render_sidebar(sections: GLASS_SECTIONS, admin: true, path: path) })
  end

  def glass_row(label, path:)
    glass_doc(path: path).at_css("#studio-link-sidebar").css("nav a").find { |row| row.text.include?(label) }
  end

  def named_user(first_name)
    Struct.new(:first_name, :display_name).new(first_name, first_name)
  end

  def render_sidebar(sections:, admin:, logged_in: true, user: nil, geo_flag: nil, geo_routes: false, path: nil)
    previous = Studio.geo_blocking_enabled
    Studio.geo_blocking_enabled = geo_flag
    rendered = view(sections: sections, admin: admin, logged_in: logged_in, user: user, geo_routes: geo_routes)
    rendered.define_singleton_method(:request) { Struct.new(:path, :host).new(path, "hub.example") } if path
    rendered
      .render(partial: "components/link_sidebar")
  ensure
    Studio.geo_blocking_enabled = previous
  end

  def view(sections:, admin:, logged_in: true, user: nil, geo_routes: false)
    resolved = Studio::SidebarSections.resolve(sections, Struct.new(:a) { def admin? = true }.new(1))
    resolved = resolved.reject { |s| s[:admin] } unless admin
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.extend(StudioIconHelper)
    view.define_singleton_method(:studio_sidebar_sections) { resolved }
    view.define_singleton_method(:admin?) { admin }
    view.define_singleton_method(:logged_in?) { logged_in }
    view.define_singleton_method(:current_user) { user }
    view.define_singleton_method(:logout_path) { "/logout" }
    # Present only where the host drew the geo routes — the state that decides
    # whether the signpost links or explains.
    view.define_singleton_method(:admin_geo_path) { "/admin/geo" } if geo_routes
    view
  end
end
