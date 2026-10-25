# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"
require "nokogiri"

# [integration] The dummy app's modal host renders each touched block with and
# without its new locals, over a real request (/lab/modal_blocks), and the JSON
# routes the newsletter cards post to answer as a consumer's do.
# e2e/modal_blocks.spec.js drives the same page in a browser.
class ModalBlocksLabTest < ActionDispatch::IntegrationTest
  def page
    get "/lab/modal_blocks"
    assert_response :success
    Nokogiri::HTML5(response.body)
  end

  def card(doc, name) = doc.at_css("[data-test='card-#{name}']")

  test "the error card counts down on the host store with the locals, and does not without them" do
    doc = page
    counted = card(doc, "rate-limit").at_css("[role=alert]")
    assert_equal "studioModalCountdown({ seconds: ($store.modals.current().props.secondsLeft), store: 'modals', autoClose: true })",
                 counted["x-data"]
    assert_equal "$store.modals.close()", counted.at_css("button")["@click"]

    plain = card(doc, "error-plain").at_css("[role=alert]")
    assert_nil plain["x-data"], "an error card with no countdown binds no factory"
    assert_equal "$dispatch('lab-error-retry')", plain.at_css("button")["@click"]
  end

  test "the success card closes the store and carries the rich message, and the plain one dispatches" do
    doc = page
    pending = card(doc, "email-pending")
    assert pending.at_css("[data-test=current-email]") && pending.at_css("[data-test=new-email]")
    assert_equal "$store.modals.close()", pending.at_css("button")["@click"]

    assert_equal "$dispatch('lab-success-continue')", card(doc, "success-plain").at_css("button")["@click"]
  end

  test "the birthday card draws the pill and the locked username card draws its way forward" do
    doc = page
    assert_equal 2, card(doc, "birthday-pill").css(".rounded-full.bg-primary").size
    locked = card(doc, "username-locked")
    assert_equal "#lab-contests", locked.at_css("a")["href"]
    assert_nil locked.at_css("input")
  end

  test "the newsletter cards render on the host store in JSON mode and on the profile store as forms" do
    doc = page
    ids = doc.css("template[x-if]").map { |t| t["x-if"][/'([^']+)'\z/, 1] }

    %w[unsubscribe-confirm newsletter-email newsletter-subscribe newsletter-success unsubscribe-goodbye].each do |id|
      assert_includes ids, id
    end
    json_ifs = doc.css("template[x-if]").map { |t| t["x-if"] }.grep(/\$store\.modals\.current\(\)\?\.id/)
    assert_equal 5, json_ifs.size

    form_ifs = doc.css("template[x-if]").map { |t| t["x-if"] }.grep(/\$store\.profileModals\.current\(\)\?\.id/)
    assert_equal ["$store.profileModals.current()?.id === 'newsletter-unsubscribe'",
                  "$store.profileModals.current()?.id === 'newsletter-email'"], form_ifs
    assert_equal 2, doc.css("form[action='/profile/newsletter']").size, "the unset partial still posts its forms"

    subscribe = doc.css("template").find { |t| t["x-if"].to_s.include?("'newsletter-subscribe'") }
    scope = Nokogiri::HTML5.fragment(subscribe.inner_html).at_css("[x-data]")["x-data"]
    assert_includes scope, "url: '/lab/modal_blocks/newsletter'"
    assert_includes scope, "needsEmail: true"
    assert_includes scope, "requiresConsent: true"
    assert_includes scope, "nextId: 'newsletter-success'"
  end

  test "the lab's JSON routes answer as a consumer's do" do
    post "/lab/modal_blocks/newsletter", params: { email: "pat@example.com" }.to_json,
                                         headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    assert_response :success
    assert_equal({ "success" => true, "seeds_earned" => 25, "email" => "pat@example.com" }, response.parsed_body)

    post "/lab/modal_blocks/newsletter/leave", headers: { "Accept" => "application/json" }
    assert_equal({ "success" => true }, response.parsed_body)
  end
end
