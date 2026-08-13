# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

# [integration] The magic-link email BODY — the call to action and the
# copy-and-paste fallback beneath it.
#
# These are two spellings of one thing: the way in. The button is what almost
# everyone taps; the raw URL is what the rest fall back to when a client
# swallows the button. So they are asserted together, and the property is that
# they AGREE — same colour, both readable — because a mismatch between them
# reads to a recipient as a broken email rather than a styling choice.
#
# Colour is asserted against Studio.theme_* rather than a hex literal. Every app
# sets its own palette, so pinning "#6f63e8" here would pass in the dummy app
# and say nothing about McRitchie Studio, turf-monster, or the next host.
class MagicLinkEmailBodyTest < ActiveSupport::TestCase
  def setup
    @previous_url_options = ActionMailer::Base.default_url_options
    ActionMailer::Base.default_url_options = { host: "example.test" }
  end

  def teardown
    ActionMailer::Base.default_url_options = @previous_url_options
  end

  # A literal token, not a minted Studio::Link. The mailer only turns the token
  # into a URL (magic_link_url_for is pure routing), and the dummy app carries no
  # schema — so minting a row would couple this body test to the links table for
  # nothing.
  TOKEN = "tokenfortest1234"

  def body_html
    mail = UserMailer.magic_link("reader@example.test", TOKEN)
    (mail.html_part&.body || mail.body).to_s
  end

  def doc = Nokogiri::HTML(body_html)

  # The two anchors that point at @magic_url: the button and the fallback.
  def sign_in_links(document = doc)
    document.css("a").select { |a| a["href"].to_s.include?(TOKEN) }
  end

  test "the call to action carries the brand colour, not the success green" do
    html = body_html

    assert_includes html, Studio.theme_primary,
      "the sign-in button should be theme primary — it ties the button to the banner above it"
    refute_includes html, Studio.theme_success,
      "success is the 'it worked' green; signing in has not happened yet"
  end

  test "the button cell paints for clients that ignore css" do
    button_cell = doc.css("td[bgcolor]").find { |td| td.css("a").any? }

    refute_nil button_cell, "the button needs a bgcolor td — Outlook ignores background on the anchor"
    assert_equal Studio.theme_primary.downcase, button_cell["bgcolor"].to_s.downcase
  end

  # The two carry the colour DIFFERENTLY — the button paints its td (an anchor
  # background is unreliable in Outlook), the fallback colours its own text — so
  # this compares the rendered colours, not the place they are written.
  test "the fallback link matches the button rather than contradicting it" do
    document = doc
    links = sign_in_links(document)

    assert_equal 2, links.length,
      "expected the button and the copy-and-paste fallback (got #{links.length})"

    button_colour = document.css("td[bgcolor]").find { |td| td.css("a").any? }["bgcolor"]
    fallback_colour = links.last["style"].to_s[/color:\s*(#[0-9a-fA-F]{3,8})/, 1]

    assert_equal button_colour.to_s.downcase, fallback_colour.to_s.downcase,
      "a green fallback under a brand-coloured button reads as a mistake, not a choice"
  end

  # 9px was small enough that the URL had to be zoomed into to be selected by
  # hand — which defeats the only reason the fallback exists.
  test "the fallback url is large enough to select by hand" do
    fallback = sign_in_links.last
    size = fallback["style"].to_s[/font-size:(\d+)px/, 1].to_i

    assert_operator size, :>=, 11,
      "the copy-and-paste URL is the fallback for a broken button; it has to be readable"
  end

  test "the fallback url wraps instead of overflowing the card" do
    fallback = sign_in_links.last

    assert_includes fallback["style"].to_s, "word-break:break-all",
      "a magic-link URL is longer than 600px and will burst the card without this"
  end

  # Both anchors must point at the SAME link. A fallback that resolves elsewhere
  # is worse than no fallback: it fails only for the people the button failed.
  test "both ways in lead to the same link" do
    hrefs = sign_in_links.map { |a| a["href"] }

    assert_equal 1, hrefs.uniq.length, "button and fallback disagree: #{hrefs.inspect}"
  end
end
