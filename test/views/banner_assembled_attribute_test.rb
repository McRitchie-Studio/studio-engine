# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"

# [integration] The EMAIL half of the assembled-attribute family: two attributes in
# _layered_banner.html.erb that were written with their OWN quotes in Ruby and then
# marked html_safe, which is the one shape ERB's attribute escaping can never reach.
#
# THE SIBLING FILE IS test/views/assembled_attribute_locals_test.rb. That one covers
# the Alpine/modal family and its locals are EXPRESSIONS — they stay html_safe on
# purpose, because escaping a handler would move bytes the browser has to run. These
# two are not expressions. A background URL and a colour are CONTENT, so they take
# the full escaping a content attribute is owed and the parser decodes them back.
# Same defect shape, opposite repair. The rule follows what the value IS, never
# which file it lives in.
#
# WHAT WAS MEASURED ON THE UNREPAIRED TEMPLATE, because this seam is worse than the
# ones in the sibling file. A double quote in background_url did not merely inject an
# attribute — it ATE the rest of the tag. The td came back as
#
#     ["background", "quote\"", "\\", "<", "script"]
#
# where a correct render carries
#
#     ["background", "bgcolor", "width", "height", "valign", "style"]
#
# so the cell lost its fallback colour, BOTH dimensions and the background-image CSS
# at once. The failure mode is a structurally wrecked email, not a tainted one.
#
# WHY THE CONSUMER MATTERS HERE. There is no Alpine and no JS in an email, but mail
# clients parse far less forgivingly than a browser and routinely strip or rewrite
# attributes. So this file does not stop at "the parser recovers it": it also pins
# that the three carriers of the background image agree byte-for-byte, and that a
# real signed URL survives the round trip. A browser render is not proof of an email
# render, and the ampersand case below is the only input whose bytes this repair
# actually moves.
#
# HOW EVERY SEAM ASSERTS — the discipline from the sibling file, unchanged:
#
#   * read through Nokogiri::HTML5, the algorithm a browser actually runs, and assert
#     on the DECODED attribute value, never on the template's output bytes. A raw
#     string assertion cannot fail on a repaired seam and cannot pass on a broken one
#     for the right reason, because ERB entity-escapes an unmarked value too.
#   * make TWO claims per seam: SHAPE (the element carries exactly the attributes it
#     carries under a benign value — the injection half) and VALUE (the browser
#     recovers the benign string with the benign token swapped for the hostile one —
#     the truncation half).
#   * carry a NON-VACUITY CONTROL per seam. Both claims are benign-vs-hostile
#     comparisons, so a template that stopped splicing the value ENTIRELY would
#     satisfy them trivially by comparing a thing to itself. That is not
#     hypothetical: in the sibling sweep one mutation survived its own test for
#     exactly this reason and was caught only by a neighbouring test.
class BannerAssembledAttributeTest < ActiveSupport::TestCase
  # Appended to a benign value to make it hostile: the double quote that closes the
  # HTML attribute once ERB has been persuaded to skip its half, plus the apostrophe,
  # backslash and closing tag that show how far the break-out reaches.
  HOSTILE_TAIL = %q{ it's a "quote" \ </script>}

  BENIGN_URL = "https://cdn.example.com/bg.gif"

  def view
    ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
  end

  def banner(**overrides)
    Studio::Banner.new(**{
      background_url: BENIGN_URL,
      header: "Welcome Mason!",
      subtext: "your sign-in link is below",
      logo_url: "https://cdn.example.com/logo.png",
      logo_alt: "Studio"
    }.merge(overrides))
  end

  def render_banner(**overrides)
    view.render(partial: "studio/mailers/layered_banner", locals: { banner: banner(**overrides) })
  end

  # The element as a BROWSER holds it, not as the template wrote it.
  def parse(html, &selector)
    selector.call(Nokogiri::HTML5.fragment(html))
  end

  # One seam: render the banner twice, benign and hostile, and hold the hostile render
  # to the benign one.
  def assert_seam_encoded(attribute:, benign:, attr:, seam:, &selector)
    hostile = "#{benign}#{HOSTILE_TAIL}"

    benign_el  = parse(render_banner(attribute => benign), &selector)
    hostile_el = parse(render_banner(attribute => hostile), &selector)

    refute_nil benign_el, "#{seam}: the benign render produced no element to compare against"
    refute_nil hostile_el, "#{seam}: the hostile render produced no element — the tag itself broke"

    # NON-VACUITY. Without this line a partial that hardcoded the value would pass
    # both claims below, because the two renders would be identical and the swap a
    # no-op. This is the control that makes the seam prove it reads what it names.
    assert_includes benign_el[attr].to_s, benign.to_s,
      "#{seam}: #{attribute} does not reach #{attr} at all, so everything asserted " \
      "about it here would pass on a template that never splices it"

    assert_equal benign_el.attribute_nodes.map(&:name), hostile_el.attribute_nodes.map(&:name),
      "#{seam}: a hostile #{attribute} changed which ATTRIBUTES the element carries, so the " \
      "value broke out of #{attr} and the remainder was parsed as markup"

    assert_equal benign_el[attr].to_s.gsub(benign.to_s, hostile), hostile_el[attr],
      "#{seam}: the browser recovers #{hostile_el[attr].inspect} from #{attr}, so the value " \
      "the template composed did not survive intact"
  end

  # --- the live defect: the td's background attribute ------------------------------

  test "a hostile background_url cannot break out of the td's background attribute" do
    assert_seam_encoded(
      attribute: :background_url, benign: BENIGN_URL, attr: "background",
      seam: "the banner cell's background image"
    ) { |frag| frag.at_css("td[background]") }
  end

  test "a hostile background_url leaves the cell's layout attributes standing" do
    # The claim above is written as a comparison, so it would also be satisfied if BOTH
    # renders lost the same attributes. This names the six outright: they are what the
    # banner is laid out from, and the unrepaired template dropped five of them.
    td = parse(render_banner(background_url: "#{BENIGN_URL}#{HOSTILE_TAIL}")) { |f| f.at_css("td") }

    assert_equal %w[background bgcolor width height valign style],
                 td.attribute_nodes.map(&:name),
                 "a hostile URL must not cost the cell its fallback colour, its dimensions " \
                 "or its background-image CSS"
    assert_equal "600px", td["style"][/width:(\d+px)/, 1], "the cell kept its declared width"
  end

  # --- the seam that was CLASSIFIED AND CLEARED ------------------------------------
  #
  # bgcolor is the same SHAPE as background and was NOT the same live defect. Checked
  # by RENDERING a hostile value rather than by reading the method — reading is how a
  # sweep talks itself into "fixing" a site that was already safe, which is a real
  # cost: it moves bytes in an email for nothing.
  #
  # IT IS REPAIRED ANYWAY, and the reason is measured rather than asserted on faith.
  # Simulating the plausible future refactor — scrim_solid_hex learning to pass a
  # named colour through instead of formatting a triplet — gives two outcomes:
  #
  #   with tag.attributes     bgcolor holds the whole hostile string as ONE value;
  #                           the cell still carries exactly its five attributes
  #   hand-assembled again    the cell gains an injected `onload`
  #
  # So the encoder is what turns that refactor from "an event handler in every email
  # this engine sends" into "a wrong colour". That is worth a line of code, and the
  # test below is the trip-wire that makes anyone who writes that refactor read this.

  test "scrim_solid_hex cannot emit a quote for any input, which is why bgcolor was never live" do
    [0.5, 0, 1, nil, "0.5\" onload=\"alert(1)", HOSTILE_TAIL, -3, 99, "abc"].each do |scrim|
      hex = Studio::Banner.new(background_url: BENIGN_URL, scrim: scrim).scrim_solid_hex

      assert_match(/\A#[0-9A-F]{6}\z/, hex,
        "scrim #{scrim.inspect} produced #{hex.inspect}; the moment this method can return " \
        "anything but a hash and six hex digits, the bgcolor seam becomes live and the " \
        "encoder on it stops being belt-and-braces")
    end
  end

  test "a hostile scrim still leaves the scrim cell whole" do
    scrim_td = parse(render_banner(scrim: "0.5\" onload=\"alert(1)")) { |f| f.css("td").last }

    assert_equal %w[align valign height bgcolor style], scrim_td.attribute_nodes.map(&:name)
    assert_equal "#4C4860", scrim_td["bgcolor"], "the hostile tail is dropped by to_f, not by escaping"
  end

  test "bgcolor tracks the scrim, so the claim above is not made about a constant" do
    # The non-vacuity control for this seam. Every assertion above would hold on a
    # partial that hardcoded a hex string; this is what fails if bgcolor stops
    # varying with the value it is supposed to render.
    low  = parse(render_banner(scrim: 0.1)) { |f| f.css("td").last }["bgcolor"]
    high = parse(render_banner(scrim: 0.9)) { |f| f.css("td").last }["bgcolor"]

    refute_equal low, high, "bgcolor does not follow scrim_opacity, so this seam renders a constant"
  end

  # --- the guard that keeps the family closed --------------------------------------
  #
  # A SOURCE-LEVEL GUARD, and it is the only honest way to hold the bgcolor half.
  # Reverting that seam to the hand-assembled form changes NO rendered byte for any
  # input — that is precisely the finding above — so no behavioural test can catch it,
  # and a mutation of it survives every assertion in this file. This one bites.
  #
  # IT IS WRITTEN AS ONE PREDICATE WITH ITS OWN CONTROLS, because a scan that grades
  # itself is the exact trap this engine just paid for elsewhere: rails_guard_sweep_test
  # re-typed its rule as string operations on a sample, so the rule existed twice, and
  # blinding the real one left the suite green. So `assembles_own_quotes?` is defined
  # ONCE here, the scan calls it, and the controls below call the SAME method — a typo
  # in it cannot go unnoticed by the thing that certifies it.

  PARTIAL_PATH = "app/views/studio/mailers/_layered_banner.html.erb"

  # The shape itself: an attribute name, an equals sign, and a quote the RUBY side
  # opened — spelt either as a bare `"` inside a %-literal or as an escaped `\"`
  # inside a double-quoted string, which is how the sibling family wrote it.
  def self.assembles_own_quotes?(line)
    line.match?(/[a-zA-Z:@.\-]+=\\?"\#\{/)
  end

  # ERB COMMENTS ARE STRIPPED FIRST, because they are prose. The partial's own repair
  # notes quote the broken shape on purpose — that is the point of them — and a scan
  # that read them would flag its own documentation and be silenced for it.
  def banner_partial_code_lines
    Studio::Engine.root.join(PARTIAL_PATH).read.gsub(/<%#.*?%>/m, "").lines
  end

  test "no attribute in the banner partial assembles its own quotes" do
    lines = banner_partial_code_lines
    offenders = lines.select { |l| self.class.assembles_own_quotes?(l) }

    # THE EXIT-BLINDNESS FLOOR, asserted inside the test that trusts the result. A scan
    # whose loop never runs reports zero offenders and passes having read nothing.
    assert_operator lines.size, :>, 100,
      "the scan read #{lines.size} lines of #{PARTIAL_PATH}; it is not reading the partial"

    assert_empty offenders,
      "an attribute is being assembled with its own quotes again — pass it through " \
      "tag.attributes instead, unmarked for content and html_safe only for an expression"
  end

  test "the predicate still flags the shape that was fixed" do
    # THE CONTROL. Without it the scan above passes for free the moment the regex is
    # mistyped, and it would report itself as "the partial is clean".
    assert self.class.assembles_own_quotes?(%q{    <td <%= %(background="#{banner.background_url}").html_safe %>}),
      "the predicate no longer recognises the exact line this task repaired"
    assert self.class.assembles_own_quotes?(%q{  <%= "minlength=\"#{min_length}\"".html_safe %>}),
      "the predicate misses the escaped-quote spelling the sibling family used"
  end

  test "the predicate does not flag the repaired form or ordinary markup" do
    # The other half of the control: a predicate that says YES to everything would
    # satisfy the test above and redden the scan for the wrong reason.
    refute self.class.assembles_own_quotes?(%q{    <td <%= tag.attributes(background: banner.background_url) %>}),
      "the repaired form must not be flagged, or this guard blocks its own fix"
    refute self.class.assembles_own_quotes?(%q{        bgcolor="<%= Studio.theme_primary %>"}),
      "an ordinary ERB output tag inside template-written quotes is the SAFE shape"
  end

  # --- the EMAIL claim: the ampersand is the only input whose bytes moved -----------

  test "a signed URL reaches all three carriers identically and round-trips" do
    # THE ONE REAL INPUT THIS REPAIR CHANGES. No in-repo background URL contains a
    # character the encoder touches, but a signed CDN link does: its query separators
    # now ship as &amp; rather than a bare &.
    #
    # That is a correction, not a regression, and this is the evidence. The CSS twin
    # and the VML src on the SAME element already went through ordinary ERB and so
    # already emitted &amp; — the hand-assembled `background` was the odd one out,
    # shipping a bare & that a parser is entitled to read as the start of an entity.
    # After the repair all three agree, and the parser hands the original URL back.
    url = "#{BENIGN_URL}?X-Amz-Date=20260908&X-Amz-Signature=abc"
    html = render_banner(background_url: url)

    assert_includes html, %(background="#{BENIGN_URL}?X-Amz-Date=20260908&amp;X-Amz-Signature=abc")
    assert_includes html, "background-image:url(#{BENIGN_URL}?X-Amz-Date=20260908&amp;X-Amz-Signature=abc)"
    assert_includes html, %(src="#{BENIGN_URL}?X-Amz-Date=20260908&amp;X-Amz-Signature=abc"),
      "the VML fill feeds Outlook the same picture and must not disagree with the other two"

    td = parse(html) { |f| f.at_css("td[background]") }
    assert_equal url, td["background"],
      "a client that decodes the attribute must get the signature back byte-for-byte, " \
      "or the CDN rejects the request and the banner is blank"
  end

  # --- THE INERTNESS CLAIM ---------------------------------------------------------

  test "the repaired seams render byte-for-byte what they rendered before" do
    # No default or in-repo value contains a character the encoder touches, so this
    # change moved nothing on any email that ships today. Asserted on the RAW output
    # on purpose: this is the one claim the source bytes are the right evidence for,
    # and it is what the surrounding suite and any consumer reading this markup sees.
    html = render_banner

    assert_includes html, %(background="#{BENIGN_URL}")
    assert_includes html, %(bgcolor="#565366"), "the default scrim's solid hex, unmoved"
    assert_includes html, %(bgcolor="#{Studio.theme_primary}"), "the cell's own fallback colour"
    assert_includes html, "background-image:url(#{BENIGN_URL})"
    refute_includes html, "&#39;", "no entity-escaped quotes reach an email for an ordinary value"
    refute_includes html, "&amp;", "nor an escaped ampersand"

    # Preview mode is the admin screen's path through the same partial and must not
    # have drifted either.
    preview = view.render(partial: "studio/mailers/layered_banner",
                          locals: { banner: banner, preview: true })
    assert_includes preview, %(background="#{BENIGN_URL}")
    assert_includes preview, "data-banner-header"
  end
end
