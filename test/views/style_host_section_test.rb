# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"

# [unit] The living style guide's HOST SECTION SEAM.
#
# THE SEAM. style/index.html.erb renders four engine sections. A consuming app
# grows a FIFTH — its own modals — by defining app/views/style/host/_modals.html.erb.
# The guide finds it by convention, the same three-term
# lookup_context.exists?(name, prefixes, partial) the modal host uses for
# modals/_host_extras, and renders the section chrome itself (style/_host.html.erb).
#
# TWO HALVES, BOTH LOAD-BEARING, and each is a different failure:
#
#   PRESENT — an app that supplies the partial gets the section AND the sticky
#   nav pill. A section with no pill is unreachable from the nav that exists to
#   reach it; a pill with no section scrolls nowhere.
#
#   ABSENT — an app that supplies nothing gets NOTHING. Not an empty container,
#   not a bare heading, not a dangling pill. Five apps mount this engine and only
#   one will ship a host section soon; the other four must see the page they see
#   today. That is asserted here as a whole-document comparison rather than a
#   handful of refutes, because "renders nothing" is a claim about the WHOLE
#   page and a refute only ever covers the string somebody thought to name.
class StyleHostSectionTest < ActiveSupport::TestCase
  # The two pages are compared to each other byte for byte below, and the Tricks
  # section stamps Time.current into its "at" specimens at SECOND resolution. Two
  # renders that straddle a second tick differ by a digit no part of this seam
  # wrote. Measured before freezing: 2 failures in 8 runs of this file, and 1 in
  # 20 direct comparisons — a flake that would have landed in CI and read as a
  # real leak. Freeze the clock and the comparison means what it says.
  include ActiveSupport::Testing::TimeHelpers

  FROZEN_AT = Time.utc(2026, 1, 1, 12, 0, 0)

  ENGINE_VIEWS = "app/views"

  # The fixture root stands in for a consuming app. It holds exactly one file —
  # style/host/_modals.html.erb — and lives under its own root so no sibling
  # suite mounts it: the seam fires on a CONVENTION, so a fixture in a shared
  # root would flip the absent case for every test that mounts it.
  HOST_FIXTURE = "test/views/fixtures/style_host_app"

  ANCHOR = "host-modals"
  MARKER = "HOST-SECTION-MARKER"

  # The engine's own sections, in the order the page publishes them.
  ENGINE_SECTIONS = %w[theme modals tricks tasks].freeze

  # --- absent: the page is what it was ------------------------------------

  def test_a_base_app_gets_no_host_section_anywhere_on_the_page
    html = base_html

    refute_includes html, MARKER,
                    "the fixture partial must be unreachable without its view-path root"
    # One assertion covers the id, the href, and any class or data attribute
    # somebody might hang the section off later.
    refute_includes html, ANCHOR,
                     "a base app's page must carry no trace of the host anchor"
  end

  def test_a_base_app_renders_exactly_the_four_engine_sections
    # Catches the empty container the seam must never emit: a wrapper with a
    # different id, or none at all, passes the string refutes above.
    assert_equal ENGINE_SECTIONS, top_section_ids(base_html)
  end

  def test_a_base_app_navs_exactly_the_four_engine_pills
    assert_equal [%w[#theme Theme], %w[#modals Modals], %w[#tricks Tricks], %w[#tasks Tasks]],
                 nav_pills(base_html)
  end

  # --- present: the app's content, in the gem's chrome --------------------

  def test_a_supplied_partial_renders_inside_the_gems_section_chrome
    node = Nokogiri::HTML.fragment(host_html).at_css("##{ANCHOR}")

    refute_nil node, "the host section must render when the app supplies a partial"
    assert_equal "section", node.name,
                 "the gem owns the section element; the app supplies content only"
    assert_includes node.text, MARKER,
                    "the app's partial must render INSIDE the section, not beside it"
  end

  def test_the_gem_heads_the_section_with_the_app_name
    # The app supplies no heading — that is the half of the contract that keeps
    # the gem dictating the structure.
    node = Nokogiri::HTML.fragment(host_html).at_css("##{ANCHOR}")

    assert_equal Studio.app_name, node.at_css("h2")&.text&.strip
  end

  def test_the_section_lands_between_modals_and_tricks
    assert_equal %w[theme modals host-modals tricks tasks], top_section_ids(host_html)
  end

  # --- the nav pill follows the section ------------------------------------

  def test_the_nav_grows_one_pill_for_the_host_section_in_the_same_place
    assert_equal [["#theme", "Theme"], ["#modals", "Modals"],
                  ["##{ANCHOR}", Studio.app_name],
                  ["#tricks", "Tricks"], ["#tasks", "Tasks"]],
                 nav_pills(host_html)
  end

  def test_the_pill_targets_an_anchor_that_exists
    # A pill whose target is missing scrolls nowhere, and looks like a working
    # nav while it does it.
    doc = Nokogiri::HTML.fragment(host_html)
    nav_pills(host_html).each do |href, label|
      refute_nil doc.at_css(href.sub("#", "#")),
                 "the #{label} pill points at #{href}, which is not in the document"
    end
  end

  # --- the seam's whole footprint -----------------------------------------

  def test_the_seam_adds_nothing_outside_its_own_section_and_pill
    # THE ABSENT-CASE PROOF, stated positively. Take the page an app WITH a host
    # section gets, cut out the section and its pill, and what is left must be
    # the page a base app gets — the same document, not merely one missing the
    # strings this file happened to name. Anything the seam leaks elsewhere (a
    # stray wrapper, a spacer div, a blank line's worth of markup in a different
    # place) fails here and nowhere else.
    #
    # Compared after collapsing whitespace runs: an ERB `if` leaves the newlines
    # around it behind, which is a difference in the source's indentation and
    # not in the page.
    stripped = Nokogiri::HTML.fragment(host_html)
    stripped.at_css("##{ANCHOR}").remove
    stripped.css("nav a[href='##{ANCHOR}']").each(&:remove)

    assert_equal squish(Nokogiri::HTML.fragment(base_html).to_html),
                 squish(stripped.to_html)
  end

  private

  # Both pages, rendered under ONE frozen clock so they are comparable. Rendered
  # together rather than lazily for the same reason: two lazy renders are two
  # different moments.
  def pages
    @pages ||= travel_to(FROZEN_AT) do
      { base: render_index([ENGINE_VIEWS]),
        host: render_index([ENGINE_VIEWS, HOST_FIXTURE]) }
    end
  end

  # A BASE app: this engine's views and nothing else. Not a contrivance —
  # measured 2026-09-07, NONE of the five apps mounting this engine
  # (mcritchie-studio, turf-monster, acquisition-studio, mcritchie-industries,
  # moms-app) defines app/views/style/host/_modals.html.erb, so this is the page
  # every one of them renders today.
  def base_html
    pages[:base]
  end

  # A consuming app that supplies the partial.
  def host_html
    pages[:host]
  end

  def render_index(paths)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(paths)
    view.extend(Studio::Engine.helpers)
    view.render(template: "style/index")
  end

  # The page's TOP-LEVEL sections, in document order. Scoped to the direct
  # children of the section stack: the Modals partial nests its own
  # <section id="modals-auth"> subsections, and a whole-document scan would
  # return those too.
  def top_section_ids(html)
    Nokogiri::HTML.fragment(html)
                  .css("div[class~='space-y-16'] > section[id]")
                  .map { |n| n["id"] }
  end

  # [href, label] for every pill in the sticky section nav, in order.
  def nav_pills(html)
    Nokogiri::HTML.fragment(html)
                  .css("nav[aria-label='Style guide sections'] a")
                  .map { |a| [a["href"], a.text.strip] }
  end

  def squish(str)
    str.gsub(/\s+/, " ").strip
  end
end
