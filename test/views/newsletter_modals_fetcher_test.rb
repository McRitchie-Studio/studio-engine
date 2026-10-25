# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"

# [unit][integration] studio/profiles/_newsletter_modals' fetcher: local, the
# host's own request wrapper named by its export in studio/host_fetchers
# (studio/newsletter_modal.js carries the contract). It is a NAME the factory
# looks up, so it is refused rather than escaped; it means nothing under :form,
# so it is refused there too; and unset it adds nothing to a card (the 0.113.0
# goldens in test/views/modal_blocks_baseline_test.rb hold the :form bytes).
class NewsletterModalsFetcherTest < ActiveSupport::TestCase
  ENGINE_ROOT = File.expand_path("../..", __dir__)
  USER = Struct.new(:email).new("pat@example.com")
  JSON_LOCALS = { user: USER, submit_mode: :json, subscribe_url: "/s", unsubscribe_url: "/u",
                  subscribe_card: true, success_card: true, goodbye_card: true }.freeze

  def view
    ActionView::Base.with_empty_template_cache.with_view_paths([File.join(ENGINE_ROOT, "app/views")])
                    .tap { |v| v.extend(Studio::Engine.helpers) }
  end

  def render_cards(**locals)
    view.render(partial: "studio/profiles/newsletter_modals", locals: locals)
  end

  def refusal(**locals)
    render_cards(**locals)
    nil
  rescue StandardError => e
    e = e.cause while e.cause
    e
  end

  # Every x-data in the render, decoded (HTML5: `@click` survives the parse).
  def scopes(html)
    Nokogiri::HTML5.fragment(html).css("template").map { |t| Nokogiri::HTML5.fragment(t.inner_html) }
               .flat_map { |f| f.css("[x-data]").map { |n| n["x-data"] } }
  end

  test "a named fetcher reaches every card that sends a request, and only those" do
    data = scopes(render_cards(**JSON_LOCALS, fetcher: "authedFetch"))
    sending = data.select { |d| d.include?("url:") }
    showing = data.reject { |d| d.include?("url:") }
    assert_equal 3, sending.size, "unsubscribe, email and subscribe each send"
    sending.each { |d| assert_includes d, "fetcher: 'authedFetch'" }
    assert_equal 2, showing.size, "the success and goodbye beats only show"
    showing.each { |d| refute_includes d, "fetcher", "a card that sends nothing names no fetcher" }
  end

  test "unset, no card names a fetcher (the plain fetch path)" do
    data = scopes(render_cards(**JSON_LOCALS))
    assert_equal 5, data.size, "the probe finds every card's scope"
    data.each { |d| refute_includes d, "fetcher" }
    assert_equal data, scopes(render_cards(**JSON_LOCALS, fetcher: "")), "a blank fetcher is unset"
  end

  test "a fetcher that is not a JS identifier is refused, naming the local" do
    ["authed fetch", "a.b", "x'y", %(x"y), "2fetch", "f()", "a\nb"].each do |bad|
      err = refusal(**JSON_LOCALS, fetcher: bad)
      assert_instance_of ArgumentError, err, "#{bad.inspect} rendered"
      assert_includes err.message, "fetcher:"
      assert_includes err.message, "JS identifier"
    end
    assert_nil refusal(**JSON_LOCALS, fetcher: "ds_Fetch$2"), "the control: a real identifier renders"
  end

  test "a fetcher under :form is refused, since no form card would call it" do
    err = refusal(user: USER, fetcher: "authedFetch")
    assert_instance_of ArgumentError, err
    assert_includes err.message, "submit_mode: :json"
  end
end
