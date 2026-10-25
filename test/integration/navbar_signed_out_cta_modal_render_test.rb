# frozen_string_literal: true

# [integration] Studio.navbar_signed_out_cta's optional keys through the dummy
# app: modal: makes the button open a modal on the engine's modal host with its
# path as the fallback href, sign_in_link: false drops the quiet sign-in link in
# both rows (one Sign in, not two), and sign_in_path repoints that link. A CTA
# without them renders the bytes it rendered in 0.113.0. Read through the HTML5
# parser: HTML4 drops @click.

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"
require_relative "../support/navbar_render_host"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"
require "json"

class NavbarSignedOutCtaModalRenderTest < ActiveSupport::TestCase
  AUTH = { id: "auth", props: { step: "credentials", mode: "signup", submitting: nil, formError: "" } }.freeze
  TURF = { label: "Sign in", path: "/signin", modal: AUTH, sign_in_link: false }.freeze

  setup { @prior = Studio.navbar_signed_out_cta }
  teardown { Studio.navbar_signed_out_cta = @prior }

  test "a CTA with none of the optional keys renders as with only label and path" do
    Studio.navbar_signed_out_cta = { label: "Build App", path: "/build" }
    plain = render

    Studio.navbar_signed_out_cta = { label: "Build App", path: "/build", modal: nil, sign_in_path: nil }
    assert_equal plain, render
    refute_includes plain, "data-nav-cta-modal"
  end

  test "modal: opens the modal from the button, with its path as the href" do
    Studio.navbar_signed_out_cta = TURF
    button = doc.at_css("[data-nav-signed-out-cta]")

    assert_equal "/signin", button["href"], "the fallback with no script or no modal host"
    assert_equal "auth", button["data-nav-cta-modal"]
    expected = '$store.modals && ($event.preventDefault(), $store.modals.open("auth", ' \
               '{"step":"credentials","mode":"signup","submitting":null,"formError":""}))'
    assert_equal expected, button["@click"]
  end

  # The button opens a dialog, so it says so before it is pressed; a CTA that
  # only navigates is a plain link and claims no popup.
  test "modal: marks the button aria-haspopup=dialog, and a plain CTA carries none" do
    Studio.navbar_signed_out_cta = TURF
    assert_equal "dialog", doc.at_css("[data-nav-signed-out-cta]")["aria-haspopup"]

    Studio.navbar_signed_out_cta = { label: "Build App", path: "/build" }
    refute doc.at_css("[data-nav-signed-out-cta]").key?("aria-haspopup")
    refute_includes render, "aria-haspopup", "no other signed-out control claims a popup either"
  end

  test "[unit] the helper adds aria-haspopup only with a modal" do
    helper = Object.new.extend(StudioNavbarHelper)
    with_modal = helper.studio_navbar_cta_modal_options({ label: "x", path: "/x", modal: { id: "auth", props: {} } })
    assert_equal "dialog", with_modal[:"aria-haspopup"]
    assert_equal({}, helper.studio_navbar_cta_modal_options({ label: "x", path: "/x" }))
    assert_equal({}, helper.studio_navbar_cta_modal_options(nil))
  end

  test "the props reach the expression as the JSON they were configured as" do
    Studio.navbar_signed_out_cta = TURF.merge(modal: { id: "auth", props: { note: %(it's "quoted" </script>) } })
    expr = doc.at_css("[data-nav-signed-out-cta]")["@click"]

    json = expr[/open\("auth", (.*)\)\)\z/, 1]
    assert_equal({ "note" => %(it's "quoted" </script>) }, JSON.parse(json))
    refute_includes expr, "</script>", "ActiveSupport's JSON escapes the angle brackets"
  end

  test "sign_in_link: false leaves one sign-in control, in both rows" do
    Studio.navbar_signed_out_cta = TURF
    page = doc

    assert_empty page.css("[data-nav-sign-in]"), "no quiet link on desktop or in the phone row"
    assert_equal 1, page.css("header a").count { |a| a.text.strip == "Sign in" }
  end

  test "sign_in_path repoints the quiet link in both rows" do
    Studio.navbar_signed_out_cta = { label: "Build App", path: "/build", sign_in_path: "/signin" }
    links = doc.css("[data-nav-sign-in]")

    assert_equal 2, links.size
    assert_equal %w[/signin /signin], links.map { |a| a["href"] }
  end

  test "a bad modal is refused when assigned" do
    assert_raises(Studio::NavbarSignedOutCta::InvalidConfig) do
      Studio.navbar_signed_out_cta = TURF.merge(modal: { id: "auth'); x('" })
    end
  end

  test "signed in, nothing of the CTA renders" do
    Studio.navbar_signed_out_cta = TURF

    refute_includes NavbarRenderHost.render_navbar(signed_in: true), "data-nav-cta-modal"
  end

  private

  def render = NavbarRenderHost.render_navbar(signed_in: false)
  def doc = Nokogiri::HTML5(render)
end
