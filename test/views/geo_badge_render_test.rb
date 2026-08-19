# frozen_string_literal: true

require "test_helper"
require "action_view"
require "nokogiri"
require_relative "../../app/helpers/studio/geo_helper"

# [component] The shared geo badge — the one geo surface every visitor sees.
#
# Rendered with LOCALS rather than a session, so each branch is measured on its
# own instead of through whatever the network answered:
#
#   · a home-country visitor gets their subdivision's flag ART
#   · anyone else gets their country's emoji flag and their region NAME
#   · an unplaceable visitor gets "??" — which is not cosmetic: under the
#     fail-closed rule that visitor is BLOCKED, and the badge has to say so
#
# The trap this file exists to pin is the third assertion below: a foreign region
# code that collides with a home subdivision ("CA" in Canada) must NOT be handed
# the California flag — a wrong answer that looks right.
class GeoBadgeRenderTest < Minitest::Test
  def test_a_home_country_visitor_gets_their_subdivision_flag
    doc = render_badge(subdivision: "WA", country: "US")

    img = doc.at_css("img")
    refute_nil img, "a resolved US state must render its flag"
    assert_includes img["src"], "state-flags/wa.svg"
    assert_includes doc.text, "WA"
  end

  # Outside the home country the art does not exist and the code may not even be
  # a code — "Alberta" is the whole answer the provider gave.
  def test_a_foreign_visitor_gets_a_country_flag_and_their_region_name
    doc = render_badge(subdivision: "Alberta", country: "CA")

    assert_nil doc.at_css("img"), "no US state art for a Canadian visitor"
    assert_includes doc.text, "🇨🇦"
    assert_includes doc.text, "Alberta"
  end

  # THE TRAP. "CA" is California and Canada; the badge must read the COUNTRY.
  def test_a_foreign_region_colliding_with_a_state_code_gets_no_state_flag
    doc = render_badge(subdivision: "CA", country: "CA")

    assert_nil doc.at_css("img"), "a Canadian region must never render the California flag"
    assert_includes doc.text, "🇨🇦"
  end

  def test_an_unplaceable_visitor_reads_as_unknown
    doc = render_badge(subdivision: nil, country: "US")

    assert_nil doc.at_css("img")
    assert_includes doc.text, "??"
  end

  # A country with no region is still a place. Saying "CA 🇨🇦" beats "??", which
  # would claim the app knows nothing about a visitor it has in fact located.
  def test_a_country_without_a_region_still_names_the_country
    doc = render_badge(subdivision: nil, country: "CA")

    assert_includes doc.text, "🇨🇦"
    assert_includes doc.text, "CA"
  end

  def test_a_blocked_visitor_reads_as_blocked
    doc = render_badge(subdivision: "WA", country: "US", blocked: true)

    assert_includes doc.at_css("span")["class"], "text-red-400"
  end

  # A simulated location is an operator standing somewhere on purpose. It reads
  # as blocked whatever the policy says, because the whole point of standing
  # there is to see the blocked experience.
  def test_a_simulated_location_reads_as_blocked
    doc = render_badge(subdivision: "WA", country: "US", simulated: true)

    assert_includes doc.at_css("span")["class"], "text-red-400"
  end

  def test_an_ordinary_allowed_location_is_not_red
    doc = render_badge(subdivision: "CO", country: "US")

    refute_includes doc.at_css("span")["class"], "text-red-400"
  end

  # --- the helper the partial leans on --------------------------------------
  #
  # Asserted DIRECTLY as well as through the partial, because the partial
  # protects the collision twice — the emoji branch is checked first — and a test
  # that only reads the rendered markup stays green when the guard inside the
  # lookup is deleted. Measured: removing that guard left the render assertions
  # untouched.
  def test_the_flag_lookup_refuses_a_foreign_country
    helper = Object.new.extend(Studio::GeoHelper)
    def helper.image_path(path) = "/assets/#{path}"

    assert_nil helper.geo_subdivision_flag_path("CA", country: "CA"),
               "a Canadian region must not resolve the California flag"
    assert_nil helper.geo_subdivision_flag_path("CA", country: "XX!"),
               "an unparseable country is not the home country either"
    assert_nil helper.geo_subdivision_flag_path("CA", country: nil),
               "and neither is no country at all"
    assert_equal "/assets/state-flags/ca.svg", helper.geo_subdivision_flag_path("CA", country: "US")
  end

  # No art shipped for this code — a normal answer, not an error. The badge then
  # renders the code text-only.
  # THE CASE A MUTATION FOUND (in turf-monster's suite, before this moved here).
  # The renders above pass even without the country guard, because a country flag
  # takes the `if` and the subdivision branch is never reached. The guard only
  # bites where NO country flag is possible and the region code still collides:
  # an unparseable country plus a state-shaped region. Without it, that visitor is
  # served the California flag.
  def test_an_unparseable_country_still_gets_no_subdivision_flag
    doc = render_badge(subdivision: "CA", country: "XX!")

    assert_nil doc.at_css("img"), "no country flag is possible here — that must mean NO flag, not California's"
    assert_includes doc.text, "CA", "the region text still renders"
  end

  def test_the_flag_lookup_is_nil_for_a_subdivision_with_no_art
    helper = Object.new.extend(Studio::GeoHelper)
    def helper.image_path(path) = "/assets/#{path}"

    assert_nil helper.geo_subdivision_flag_path("ZZ")
    assert_nil helper.geo_subdivision_flag_path(nil)
  end

  private

  def render_badge(subdivision:, country:, blocked: false, simulated: false)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.singleton_class.include(Studio::GeoHelper)
    html = view.render(partial: "components/geo_badge",
                       locals: { subdivision: subdivision, country: country,
                                 blocked: blocked, simulated: simulated })
    Nokogiri::HTML5.fragment(html)
  end
end
