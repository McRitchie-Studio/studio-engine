# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"
require "nokogiri"

# [integration] The self-styled page header over a real request, through the dummy's
# helpers and its callable config.page_header_self_styled (test/dummy/config/application.rb):
# the plain-CSS host's pages bring the row's own CSS and script once, and a Tailwind
# page's row carries neither. e2e/page_header_self_styled.spec.js drives the same pages
# in a browser.
class PageHeaderSelfStyledLabTest < ActionDispatch::IntegrationTest
  def page(path)
    get path
    assert_response :success
    Nokogiri::HTML5(response.body)
  end

  def self_styled_sheets(doc) = doc.css("style").select { |style| style.text.include?("--ph-ink:") }

  test "a plain-CSS host's page brings the row's styles and script once, before the row" do
    doc = page("/lab/plain_css/page_header")

    assert_equal 1, self_styled_sheets(doc).size
    scripts = doc.css("script")
    assert_equal 1, scripts.size, "the row's own module, and no other script on the page"
    assert_equal "module", scripts.first["type"]
    assert_match %r{studio/page_header_self_styled(-[0-9a-f]+)?\.js\z}, scripts.first["src"]
    assert_empty doc.css("script[type=importmap]"), "the host has no import map, and the module needs none"
    sentinel = doc.at_css(".page-header-sentinel")
    assert_equal "page-header", sentinel["data-studio-controller"]
    assert_includes sentinel.next_element["class"].split, "page-header"
    assert_equal "Latest rants", doc.at_css(".page-header h1").text
  end

  test "the legal page renders the header and the column in the same host" do
    doc = page("/lab/plain_css/legal?page=terms")

    assert_equal 1, self_styled_sheets(doc).size
    assert_equal ["Terms of Service"], doc.css("h1").map(&:text)
    assert_equal "terms", doc.at_css(".legal-page")["data-legal-page"]
    assert_equal 8, doc.css(".legal-page-body section h2").size
  end

  test "a Tailwind page's row carries no self-styled assets" do
    doc = page("/lab/page_header_kinds")

    assert doc.at_css(".page-header-sentinel + .page-header"), "the row rendered"
    assert_empty self_styled_sheets(doc)
    # The import map pins every engine module, this one included; only a tag loads it.
    assert_empty doc.css("script[src*='page_header_self_styled']")
  end
end
