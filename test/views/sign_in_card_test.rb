# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"

# [unit] studio/auth/_sign_in_card and _sign_in_modal: the engine's standard
# sign-in card (task engine-ships-sign-in-card).
#
# WHAT IS AT STAKE. Real mode must post where the hub's and Turf's cards post:
# Google as a POST form to /auth/google_oauth2 with Turbo off, and the email to
# the magic-link endpoint, each carrying return_to. Demo mode (the style guide)
# must post NOWHERE: no form action to /auth or /magic_link, no CSRF field, and
# a config with no endpoint, so a reviewer pressing every button sends nothing.
#
# HOW IT READS. Through Nokogiri::HTML5, which keeps the Alpine attributes
# (@submit.prevent) that the HTML4 parser silently drops.
class SignInCardTest < ActiveSupport::TestCase
  ENGINE_ROOT = File.expand_path("../..", __dir__)

  def view
    ActionView::Base.with_empty_template_cache.with_view_paths([File.join(ENGINE_ROOT, "app/views")])
                    .tap { |v| v.extend(Studio::Engine.helpers) }
                    .tap do |v|
                      # As in a real request, so a CSRF field is drawn wherever a
                      # live form would carry one, and its absence in demo means something.
                      v.define_singleton_method(:protect_against_forgery?) { true }
                      v.define_singleton_method(:form_authenticity_token) { |**| "test-token" }
                      v.define_singleton_method(:request_forgery_protection_token) { :authenticity_token }
                    end
  end

  def render_partial(name, **locals)
    Nokogiri::HTML5.fragment(view.render(partial: name, locals: locals))
  end

  # Google posts only when the app has an OAuth client (or OmniAuth test mode).
  def with_google_ready
    saved = ENV.values_at("GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET")
    ENV["GOOGLE_CLIENT_ID"] = "id"
    ENV["GOOGLE_CLIENT_SECRET"] = "secret"
    yield
  ensure
    ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_CLIENT_SECRET"] = saved
  end

  def config_of(doc)
    JSON.parse(doc.at_css("[data-sign-in-card]")["data-sign-in-card"])
  end

  def test_google_posts_to_the_oauth_request_path_with_return_to_and_turbo_off
    with_google_ready do
      doc = render_partial("studio/auth/sign_in_card", return_to: "/contests/42", google: true)
      form = doc.at_css("form[data-sign-in-google='ready']")

      assert form, "the live card renders Google as a form"
      assert_equal "post", form["method"]
      assert_equal "/auth/google_oauth2?return_to=%2Fcontests%2F42", form["action"]
      assert_equal "false", form.at_css("button")["data-turbo"], "Turbo must not follow the OmniAuth request phase"
      assert form.at_css("input[name='authenticity_token']"), "the request phase is CSRF-checked"
      assert form.at_css("svg"), "the Google mark renders"
    end
  end

  def test_google_without_return_to_posts_to_the_bare_path
    with_google_ready do
      doc = render_partial("studio/auth/sign_in_card", google: true)
      assert_equal "/auth/google_oauth2", doc.at_css("form[data-sign-in-google='ready']")["action"]
    end
  end

  def test_email_form_posts_to_the_magic_link_endpoint_with_return_to
    doc = render_partial("studio/auth/sign_in_card", return_to: "/build/abc", magic_link: true, google: false)
    form = doc.at_css("form[data-sign-in-email-form='live']")

    assert form, "the email form renders"
    assert_equal "/magic_link", form["action"]
    assert_equal "post", form["method"]
    assert_equal "send()", form["@submit.prevent"]
    assert form.at_css("input[type='email'][name='email'][required]"), "the shared email field renders"
    assert_equal "/build/abc", form.at_css("input[type='hidden'][name='return_to']")["value"]
    assert form.at_css("input[name='authenticity_token']"), "the no-JavaScript fallback is CSRF-checked too"
    assert_equal "/magic_link", config_of(doc)["endpoint"]
    assert_equal "/build/abc", config_of(doc)["returnTo"]
  end

  def test_a_named_magic_link_path_wins
    doc = render_partial("studio/auth/sign_in_card", magic_link: true, magic_link_path: "/auth/email")
    assert_equal "/auth/email", doc.at_css("form[data-sign-in-email-form]")["action"]
  end

  def test_an_offsite_return_to_is_dropped
    with_google_ready do
      ["https://evil.example/x", "//evil.example", "javascript:alert(1)"].each do |bad|
        doc = render_partial("studio/auth/sign_in_card", return_to: bad, google: true, magic_link: true)

        assert_equal "/auth/google_oauth2", doc.at_css("form[data-sign-in-google]")["action"], bad
        assert_nil doc.at_css("input[name='return_to']"), bad
        assert_nil config_of(doc)["returnTo"], bad
      end
    end
  end

  def test_order_is_google_then_or_then_email_then_the_link_sent_step
    with_google_ready do
      html = view.render(partial: "studio/auth/sign_in_card", locals: { google: true, magic_link: true })
      google = html.index("data-sign-in-google")
      divider = html.index(">or<")
      email = html.index("data-sign-in-email-form")
      sent = html.index(%(data-sign-in-step="sent"))

      assert google && divider && email && sent
      assert_operator google, :<, divider
      assert_operator divider, :<, email
      assert_operator email, :<, sent
    end
  end

  def test_the_link_sent_step_reuses_the_resend_footer
    doc = render_partial("studio/auth/sign_in_card", magic_link: true)
    sent = doc.at_css("[data-sign-in-step='sent']")

    assert sent.css("button").any? { |b| b["@click"] == "resendMagicLink()" }, "the resend footer renders in the sent step"
    refute sent.css("button").any? { |b| b["@click"].to_s.include?("$store.") },
           "the page card has no modal to close, so the footer's Close is dropped"
  end

  def test_the_modal_closes_its_own_store
    doc = render_partial("studio/auth/sign_in_modal", modal_store: "dsModals", magic_link: true)
    clicks = doc.css("button").map { |b| b["@click"] }

    assert_includes clicks, "$store.dsModals.close()"
    refute clicks.any? { |c| c.to_s.include?("$store.modals.") }, "a named store is never swapped for the default"
    assert doc.at_css("input#sign-in-modal-email"), "the modal's field has its own id"
  end

  def test_the_modal_refuses_a_non_identifier_store
    err = assert_raises(ActionView::Template::Error) do
      view.render(partial: "studio/auth/sign_in_modal", locals: { modal_store: "mo dals" })
    end
    assert_includes err.cause.message, "modal_store"
  end

  def test_extras_and_preamble_slots_render_partials
    doc = render_partial("studio/auth/sign_in_card",
                         preamble: "studio/modals/shared/age_attestation",
                         extras: [{ partial: "components/google_logo", locals: {} }])

    assert doc.at_css("[data-sign-in-slot='preamble']"), "the preamble slot renders"
    assert doc.at_css("[data-sign-in-slot='extras'] svg"), "the extras slot renders the named partial"
  end

  def test_no_slots_render_no_slot_wrappers
    doc = render_partial("studio/auth/sign_in_card")
    assert_nil doc.at_css("[data-sign-in-slot]")
  end

  def test_heading_defaults_from_the_app_name_and_can_be_named
    assert_includes render_partial("studio/auth/sign_in_card").at_css("h1").text, Studio.app_name
    doc = render_partial("studio/auth/sign_in_card", heading: "Welcome back", subheading: "Pick a way in")
    assert_equal "Welcome back", doc.at_css("h1").text.strip
    assert_includes doc.text, "Pick a way in"
  end

  # --- demo mode: nothing posts ---------------------------------------------

  def test_demo_mode_renders_no_live_action
    with_google_ready do
      %w[studio/auth/sign_in_card studio/auth/sign_in_modal].each do |partial|
        locals = { demo: true, return_to: "/x" }
        locals[:modal_store] = "dsModals" if partial.end_with?("modal")
        html = view.render(partial: partial, locals: locals)
        doc = Nokogiri::HTML5.fragment(html)

        assert doc.at_css("button[data-sign-in-google='demo'][type='button']"), "#{partial}: Google is an inert button"
        assert_nil doc.at_css("form[data-sign-in-google]"), "#{partial}: no Google form"
        assert doc.at_css("form[data-sign-in-email-form='demo']"), "#{partial}: the email form still renders"
        doc.css("form").each do |form|
          assert_nil form["action"], "#{partial}: a demo form carries no action"
        end
        assert_nil doc.at_css("input[name='authenticity_token']"), "#{partial}: no CSRF field, nothing to post"
        refute_match %r{/auth/google_oauth2|/magic_link}, html, "#{partial}: no live endpoint anywhere in the markup"

        config = config_of(doc)
        assert_equal true, config["demo"]
        assert_nil config["endpoint"]
        assert_equal 5, config["cooldown"]
      end
    end
  end

  def test_live_mode_counts_down_sixty_seconds
    assert_equal 60, config_of(render_partial("studio/auth/sign_in_card", magic_link: true))["cooldown"]
  end

  # THE CONTROL for the demo test: the same probe finds the endpoints when they
  # are there, so the refutes above are not vacuous.
  def test_the_demo_probe_can_find_a_live_endpoint
    with_google_ready do
      html = view.render(partial: "studio/auth/sign_in_card", locals: { google: true, magic_link: true })
      assert_match %r{/auth/google_oauth2}, html
      assert_match %r{/magic_link}, html
    end
  end
end
