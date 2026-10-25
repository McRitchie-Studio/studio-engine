# frozen_string_literal: true

# [integration] Studio.navbar_phone_name through the dummy app: true shows the
# signed-in name below md in a capped box that engine.css fades when the name
# overflows; false (the default) keeps it screen-reader text below md, the
# 0.113.0 bytes.

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"
require_relative "../support/navbar_render_host"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

class NavbarPhoneNameRenderTest < ActiveSupport::TestCase
  CSS = File.read(File.expand_path("../../app/assets/tailwind/studio_engine/engine.css", __dir__))
  # The phone name's below-md block: the first 767px media block that names it.
  PHONE_BLOCK = CSS[/@media \(max-width: 767px\) \{\n(?:(?!\n\}\n).)*?\[data-nav-name-phone\].*?\n\}\n/m]

  setup { @prior = Studio.navbar_phone_name }
  teardown { Studio.navbar_phone_name = @prior }

  test "false, the default, keeps the name screen-reader text below md" do
    Studio.navbar_phone_name = false
    box = name_box

    assert_equal %w[sr-only md:not-sr-only md:max-w-40], box["class"].split
    refute box.key?("data-nav-name-phone")
  end

  test "true shows the name in a capped box, still inside the one account control" do
    Studio.navbar_phone_name = true
    box = name_box

    assert box.key?("data-nav-name-phone")
    classes = box["class"].split
    refute_includes classes, "sr-only"
    assert_equal %w[min-w-0 max-w-[4.5rem] min-[400px]:max-w-[6rem] md:max-w-40], classes
    assert_equal "Plain User", box.at_css("[data-nav-name]").text
    assert box.ancestors("[data-nav-account]").any?, "the name stays part of the account control"
  end

  test "only true or false is accepted" do
    assert_raises(ArgumentError) { Studio.navbar_phone_name = "yes" }
    assert_raises(ArgumentError) { Studio.navbar_phone_name = nil }
  end

  test "engine.css fades the phone name on its own scroll timeline, below md only" do
    block = PHONE_BLOCK

    refute_nil block
    supported = block[/@supports \(animation-timeline: scroll\(\)\) \{\n.*?\n  \}\n/m]
    refute_nil supported, "the fade sits behind the scroll-timeline check"
    assert_includes supported, "text-overflow: clip"
    assert_includes supported, "animation: nav-name-fade linear both"
    assert_includes supported, "animation-timeline: scroll(self inline)"
    assert_match(/@keyframes nav-name-fade \{\n  from, to \{[^}]*mask-image: linear-gradient\(to right, black 50%, transparent\);/m, CSS)
  end

  # Shannon's Firefox screenshot: with no scroll timelines there is no fade, so
  # a clip there cut a long name mid-letter. The clip is the fade's partner and
  # lives only where the fade does; elsewhere truncate's ellipsis stands.
  test "a browser without scroll timelines keeps truncate's ellipsis on the phone name" do
    block = PHONE_BLOCK
    refute_nil block
    outside = block.sub(/@supports \(animation-timeline: scroll\(\)\) \{\n.*?\n  \}\n/m, "")
    refute_includes outside, "text-overflow", "a clip outside the @supports block cuts the name mid-letter"
    assert_includes block, "text-overflow: clip", "the control: the clip still exists, inside the check"
  end

  private

  def name_box
    Nokogiri::HTML5(NavbarRenderHost.render_navbar(signed_in: true)).at_css("[data-nav-account] > span:first-child")
  end
end
