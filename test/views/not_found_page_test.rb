# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"

# [component] studio/_not_found, the friendly not-found page a lost visitor sees
# (docs/NOT_FOUND_PAGE.md): the app's brand mark and name, a short plain message,
# a primary button to the app's home and, when the visitor came from a page on
# this app, a second link back. Theme tokens only, so it reads in light and dark.
class NotFoundPageTest < ActiveSupport::TestCase
  def page(**locals)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    html = view.render(partial: "studio/not_found", locals: { app_name: "Acme Studio", home_path: "/" }.merge(locals))
    Nokogiri::HTML.fragment(html).at_css("[data-test='not-found']")
  end

  test "it names the app, shows its mark, says what happened and links home" do
    section = page(logo: "/brand/icon-light.svg")

    assert section, "the page's section"
    assert_equal "This page isn’t here", section.at_css("h1").text
    assert_equal section.at_css("h1")["id"], section["aria-labelledby"], "the heading names the region"
    assert_includes section.text, "The address may be mistyped, or the page may have moved."

    logo = section.at_css("img[data-studio-not-found-logo]")
    assert_equal "/brand/icon-light.svg", logo["src"]
    assert_equal "Acme Studio", logo["alt"], "the mark is named for the app"

    home = section.at_css("a[data-test='not-found-home']")
    assert_equal "/", home["href"]
    assert_equal "Back to Acme Studio", home.text
    assert_includes home["class"].split, "btn-primary", "home is the primary button"
  end

  test "a page the visitor came from adds a second link back" do
    back = page(back_path: "/apps?tab=live").at_css("a[data-test='not-found-back']")

    assert_equal "/apps?tab=live", back["href"]
    assert_equal "Go back", back.text
    refute_includes back["class"].split, "btn-primary", "the back link is secondary"
  end

  test "no referrer and no logo: one button and no image" do
    section = page

    assert_nil section.at_css("a[data-test='not-found-back']")
    assert_nil section.at_css("img")
    assert_equal 1, section.css("a").size
  end

  test "it uses the home path it is given, not a hard-coded slash" do
    assert_equal "/app/", page(home_path: "/app/").at_css("a[data-test='not-found-home']")["href"]
  end

  test "the app's name is escaped, never markup" do
    home = page(app_name: "<b>Acme</b>").at_css("a[data-test='not-found-home']")

    assert_equal "Back to <b>Acme</b>", home.text
    assert_nil home.at_css("b")
  end

  test "it draws in theme tokens only, so dark mode needs nothing extra" do
    section = page(logo: "/x.svg", back_path: "/y")
    classes = section.css("[class]").flat_map { |node| node["class"].split }

    refute(classes.any? { |name| name.match?(/\A(bg|text|border)-(white|black|gray|slate|zinc|neutral)\b/) },
           "a fixed colour: #{classes.grep(/\A(bg|text|border)-/).inspect}")
    assert_includes classes, "text-heading"
    assert_includes classes, "text-secondary"
  end
end
