# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"
require_relative "../support/engine_tailwind_build"

# [integration] The sign-in page's SSO overlay must BLUR in every consumer, and
# the blur must come from classes the ENGINE defines.
#
# THE DEFECT THIS PINS. sessions/new drew its "Click to show other options"
# overlay with `backdrop-overlay`, a utility defined only in turf-monster's
# app/assets/tailwind/application.css. mcritchie-industries renders this engine
# view and never defined it, so its overlay carried no blur and no scrim. The
# class was spelled correctly everywhere; it simply painted nothing outside turf.
#
# HOW THIS DECIDES. It renders the real template with an SSO user available,
# reads the class list off the overlay element, and compiles exactly those
# classes through the engine's consumer-style build WITHOUT the opt-in motion
# layer, because mcritchie-industries does not import it. The declarations the
# classes ADD to an empty build must set a backdrop blur, a backdrop brightness,
# and the primary-900 scrim. Checking that the turf name is gone would prove
# nothing about whether anything replaced it.
class SignInOverlayBlurTest < ActiveSupport::TestCase
  OVERLAY_TEXT = "Click to show other options"

  def setup
    @orig_auth = Studio.auth_methods
    Studio.auth_methods = %i[magic_link]
  end

  def teardown
    Studio.auth_methods = @orig_auth
  end

  def test_the_rendered_overlay_carries_a_blur_the_engine_defines
    added = added_css(overlay_classes)

    assert_match(/--tw-backdrop-blur:\s*blur\(2px\)/, added, "the overlay's classes set no backdrop blur")
    assert_match(/--tw-backdrop-brightness:\s*brightness\((?:70%|0?\.7)\)/, added,
                 "the overlay's classes set no backdrop brightness")
    assert_match(/(?<![-\w])backdrop-filter:[^;]*var\(--tw-backdrop-blur/, added,
                 "no backdrop-filter composes the blur, so nothing would apply it")
    assert_match(/--color-primary-900-rgb[^;]*20%/, added, "the overlay's classes paint no primary-900 scrim")
  end

  # Every class on the overlay must exist in the build a motion-less consumer
  # gets. One that compiles only with the motion layer would blur in turf and
  # the hub and silently not in mcritchie-industries: the same defect again.
  def test_every_overlay_class_compiles_without_the_motion_layer
    classes = overlay_classes
    compiled = EngineTailwindBuild.classes_in_css(EngineTailwindBuild.compile(classes, motion: false))

    assert_empty classes.reject { |c| compiled.include?(c) },
                 "these overlay classes compile to nothing in a consumer without engine-motion.css"
  end

  # THE CONTROL. The class the overlay used to carry adds no backdrop-filter to
  # the engine build, so the assertions above would have failed on the old view.
  def test_the_turf_utility_it_replaced_paints_nothing_in_the_engine_build
    added = added_css(%w[backdrop-overlay])

    refute_match(/backdrop-filter/, added, "backdrop-overlay now compiles in the engine build; re-point this control")
  end

  # The floor: the scan found the overlay element, and it is the one that covers the card.
  def test_the_guard_reads_the_overlay_it_claims_to
    classes = overlay_classes

    assert_includes classes, "inset-0", "the overlay element was not found; re-point this test, do not delete it"
    assert_includes classes, "absolute"
  end

  private

  # HTML5, not Nokogiri::HTML: the HTML4 parser mis-reads the overlay's Alpine
  # `@click="..."` attribute and drops every attribute after it, class included.
  def overlay_classes
    doc = Nokogiri::HTML5(render_login_with_sso)
    label = doc.at_xpath("//span[normalize-space(.)='#{OVERLAY_TEXT}']")

    assert label, "the SSO overlay did not render; is sso_user_available? still the gate?"
    label.parent["class"].to_s.split
  end

  # What the named classes ADD to a build that names nothing. engine.css's own
  # always-emitted rules appear on both sides and cancel, so a backdrop-filter
  # somewhere in the engine sheet cannot pass this by accident.
  def added_css(tokens)
    (EngineTailwindBuild.compile(tokens, motion: false).lines -
      EngineTailwindBuild.compile([], motion: false).lines).join
  end

  # sessions/new through ActionView with the request-scoped helpers stubbed, the
  # pattern engine_login_passwordless_test.rb uses, but with an SSO user present so
  # the overlay branch renders.
  def render_login_with_sso
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    {
      sso_user_available?: true, sso_continue_path: "/sso_continue", sso_hub_logo: nil,
      sso_source_app: "McRitchie Studio", sso_display_name: "Alex", login_path: "/login",
      magic_link_request_path: "/magic_link", signup_path: "/signup", params: {},
      protect_against_forgery?: false
    }.each { |name, value| view.define_singleton_method(name) { |*| value } }
    view.render(template: "sessions/new")
  end
end
