# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/studio/email_image_generator"

# [unit] Studio::EmailImageGenerator: which URLs the /admin/emails generator
# link may carry, how a callable is resolved, and the default wording. The
# Studio.email_manager_generator_* setters and the rendered page are in
# test/integration/emails_page_generator_link_test.rb.
class EmailImageGeneratorTest < Minitest::Test
  G = Studio::EmailImageGenerator

  # ---- which URLs are allowed -------------------------------------------------

  def test_http_and_https_urls_with_a_host_are_web_urls
    assert G.web_url?("https://example.com/email-art")
    assert G.web_url?("http://localhost:3100/admin/email-art?x=1")
    assert G.web_url?("HTTPS://Example.com")
    assert G.web_url?("  https://example.com  "), "surrounding space is stripped, not refused"
  end

  def test_anything_a_browser_could_run_or_misroute_is_refused
    [
      "javascript:alert(1)",
      "JavaScript:alert(1)",
      " javascript:alert(1)",
      "data:text/html,<script>alert(1)</script>",
      "vbscript:msgbox(1)",
      "ftp://example.com/file",
      "//example.com/no-scheme",
      "/admin/email-art",
      "example.com",
      "https://",
      "https:///path-only",
      "https://exa mple.com",
      "https://example.com/\njavascript:alert(1)",
      "java\tscript:alert(1)",
      "https://example.com/art?b=\"><script>x</script>",
      "https://example.com/it's",
      "https://example.com\\@evil.example",
      "https://example.com/`x`",
      "",
      "   ",
      nil,
      42,
      :https
    ].each do |value|
      refute G.web_url?(value), "#{value.inspect} must not be a generator URL"
    end
  end

  # ---- the setter's check -----------------------------------------------------

  def test_unset_blank_and_callables_pass_the_setter
    assert_nil G.normalize_url(nil)
    assert_nil G.normalize_url("")
    assert_nil G.normalize_url("   ")
    callable = ->(_request) { "https://example.com" }
    assert_same callable, G.normalize_url(callable)
    assert_equal "https://example.com/x", G.normalize_url(" https://example.com/x ")
  end

  def test_the_setter_refuses_a_non_web_url_loudly
    ["javascript:alert(1)", "/relative", "example.com", 42].each do |value|
      error = assert_raises(ArgumentError) { G.normalize_url(value) }
      assert_includes error.message, "email_manager_generator_url"
    end
  end

  # ---- resolving per request --------------------------------------------------

  def test_a_callable_receives_the_request
    request = Object.new
    seen = nil
    url = G.resolve_url(->(r) { seen = r; "https://example.com/for-request" }, request)

    assert_same request, seen
    assert_equal "https://example.com/for-request", url
  end

  def test_a_zero_argument_callable_is_called_bare
    assert_equal "https://example.com", G.resolve_url(-> { "https://example.com" }, Object.new)
  end

  def test_a_callable_answering_nil_blank_or_unsafe_draws_no_link
    [nil, "", "javascript:alert(1)", "/relative", 42].each do |answer|
      assert_nil G.resolve_url(->(_r) { answer }), "a callable answering #{answer.inspect} must draw nothing"
    end
  end

  # ---- the link ---------------------------------------------------------------

  def test_no_url_means_no_link_whatever_else_is_set
    assert_nil G.link(url: nil, label: "Make art", description: "Words", app_name: "Turf Monster")
    assert_nil G.link(url: ->(_r) { nil }, label: "Make art")
  end

  def test_defaults_are_generic_and_name_the_app
    link = G.link(url: "https://example.com", app_name: "Turf Monster")

    assert_equal "https://example.com", link.url
    assert_equal "Email image generator", link.label
    assert_equal "Make a new header with Turf Monster's character model: open the generator, " \
                 "copy the prompt, paste it into Claude Code.", link.description
  end

  def test_blank_label_and_description_fall_back_to_the_defaults
    link = G.link(url: "https://example.com", label: "  ", description: "", app_name: "Cyvasse")

    assert_equal G::DEFAULT_LABEL, link.label
    assert_includes link.description, "Cyvasse's character model"
  end

  def test_the_app_can_override_label_and_description
    link = G.link(url: "https://example.com", label: "Header studio",
                  description: "Open it and follow the steps.", app_name: "Cyvasse")

    assert_equal "Header studio", link.label
    assert_equal "Open it and follow the steps.", link.description
  end

  def test_a_percent_in_the_app_name_is_text_not_a_format_directive
    link = G.link(url: "https://example.com", app_name: "100%s Club")

    assert_includes link.description, "100%s Club's character model"
  end
end
