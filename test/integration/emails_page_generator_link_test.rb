# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"
require "nokogiri"

# [integration] The "Email image generator" link at the top of /admin/emails,
# driven through the REAL stack: router -> Studio::EmailsController#index -> the
# engine's index.html.erb, in the dummy app that opts into the page the way a
# consuming app does. The URL rules themselves are unit-tested in
# test/lib/studio/email_image_generator_test.rb.
ActionDispatch::IntegrationTest.app = Rails.application

# The engine's User contract is admin? + display_name; a PORO satisfies it.
class GeneratorLinkTestAdmin
  def admin? = true
  def display_name = "Admin"
end

# The host contract the engine's controllers inherit, exactly as a consuming
# app supplies it.
class ApplicationController < ActionController::Base
  include Studio::ErrorHandling

  def current_user
    @current_user ||= GeneratorLinkTestAdmin.new
  end
end

class EmailsPageGeneratorLinkTest < ActionDispatch::IntegrationTest
  SETTINGS = %i[email_image_generator_url email_image_generator_label
                email_image_generator_description].freeze

  def setup
    Studio::EmailCatalog.reset!
    @saved = SETTINGS.to_h { |name| [name, Studio.public_send(name)] }
    @app_name = Studio.app_name
  end

  def teardown
    SETTINGS.each { |name| Studio.public_send(:"#{name}=", @saved[name]) }
    Studio.app_name = @app_name
    Studio::EmailCatalog.reset!
  end

  def page
    get "/admin/emails"
    assert_equal 200, response.status, response.body[0, 500]
    Nokogiri::HTML(response.body)
  end

  def callout(doc) = doc.at_css("[data-email-image-generator]")

  # ---- set ------------------------------------------------------------------

  test "a configured URL draws the link at the top, opening in a new tab" do
    Studio.app_name = "Turf Monster"
    Studio.email_image_generator_url = "https://example.com/email-art"

    doc = page
    box = callout(doc)
    refute_nil box, "the generator callout is missing"

    link = box.at_css("a")
    assert_equal "https://example.com/email-art", link["href"]
    assert_equal "Email image generator", link.text.strip
    assert_equal "_blank", link["target"]
    assert_includes link["rel"].split, "noopener"
    assert_includes box.text, "Make a new header with Turf Monster's character model: " \
                              "open the generator, copy the prompt, paste it into Claude Code."

    # At the TOP: before the email table, right under the page heading.
    html = response.body
    assert_operator html.index("data-email-image-generator"), :<, html.index("<table"),
      "the generator link must sit above the email table"
    assert_operator html.index("<h1"), :<, html.index("data-email-image-generator")
  end

  test "a callable URL receives the request" do
    seen = nil
    Studio.email_image_generator_url = ->(request) { seen = request; "#{request.base_url}/admin/email-art" }

    link = callout(page).at_css("a")

    assert_kind_of ActionDispatch::Request, seen
    assert_equal "http://www.example.com/admin/email-art", link["href"]
  end

  test "the app's own label and description replace the defaults" do
    Studio.email_image_generator_url = "https://example.com/email-art"
    Studio.email_image_generator_label = "Header studio"
    Studio.email_image_generator_description = "Open it and follow the steps."

    box = callout(page)

    assert_equal "Header studio", box.at_css("a").text.strip
    assert_includes box.text, "Open it and follow the steps."
    refute_includes box.text, "character model"
  end

  test "label, description and URL are escaped" do
    # A quote or angle bracket cannot even be configured: URI refuses it.
    assert_raises(ArgumentError) do
      Studio.email_image_generator_url = "https://example.com/art?b=\"><script>x</script>"
    end

    Studio.email_image_generator_url = "https://example.com/art?a=1&b=2"
    Studio.email_image_generator_label = "<b>Bold</b> label"
    Studio.email_image_generator_description = "<script>alert('x')</script> & more"

    page
    html = response.body
    refute_includes html, "<script>alert('x')</script>"
    refute_includes html, "<b>Bold</b>"
    assert_includes html, 'href="https://example.com/art?a=1&amp;b=2"'
    assert_includes html, "&lt;b&gt;Bold&lt;/b&gt; label"
    assert_includes html, "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; more"
  end

  test "a javascript: URL is refused at configuration and never reaches the page" do
    assert_raises(ArgumentError) { Studio.email_image_generator_url = "javascript:alert(1)" }
    assert_nil Studio.email_image_generator_url

    assert_nil callout(page)
    refute_includes response.body, "javascript:alert"
  end

  test "a callable answering a javascript: URL draws no link" do
    Studio.email_image_generator_url = ->(_request) { "javascript:alert(1)" }

    assert_nil callout(page)
    refute_includes response.body, "javascript:alert"
  end

  # ---- unset ----------------------------------------------------------------

  test "unset, nil and blank draw no link, and the page is byte-for-byte the same" do
    Studio.email_image_generator_url = nil
    unset = (page; response.body)
    assert_nil callout(Nokogiri::HTML(unset))
    refute_includes unset, "Email image generator"

    # A label or description on its own draws nothing either.
    Studio.email_image_generator_label = "Header studio"
    Studio.email_image_generator_description = "Open it."
    ["", "   "].each do |blank|
      Studio.email_image_generator_url = blank
      assert_nil Studio.email_image_generator_url
      assert_equal unset, (page; response.body), "url=#{blank.inspect} changed the page"
    end
  end
end
