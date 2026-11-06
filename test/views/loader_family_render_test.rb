# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require_relative "../../app/helpers/studio/loader_helper"

# [unit] The loader family, rendered (Studio::LoaderHelper, docs/LOADER.md,
# "The family").
#
#   A. Spinner, dots and bar are styles of studio_loader that wrap the canonical
#      .spinner, .loading-dots and .progress-meter, with no icon; a bar is a
#      progressbar whose percent is its value.
#   B. A skeleton is aria-busy, its shapes aria-hidden, and one line names it.
#   C. Infinite scroll: page 1 holds its items and the next page's frame; a later
#      page puts its items in its own frame; the last says it is done; the
#      button is an ordinary link to the next page.
#   D. Pull to refresh wraps its block with a hidden indicator and a status line.
#   E. The stylesheet: the plain styles set the canonical rules' knobs, the
#      skeleton uses theme tints and stops under reduced motion.
class LoaderFamilyRenderTest < ActiveSupport::TestCase
  ENGINE_ROOT = File.expand_path("../..", __dir__)
  MOTION_CSS = File.join(ENGINE_ROOT, "app/assets/tailwind/studio_engine/engine-motion.css")

  # ── A ──────────────────────────────────────────────────────

  test "a spinner is the canonical ring inside the family's one class" do
    loader = render { |v| v.studio_loader(style: :spinner) }.at_css(".studio-loader")

    assert_equal "spinner", loader["data-loader-style"]
    assert_equal "status", loader["role"]
    assert_includes loader["style"], "--studio-loader-size: 20px"
    assert loader.at_css("span.spinner[aria-hidden='true']")
    assert_nil loader.at_css("img"), "a plain style draws no icon"
    assert_equal "Loading", loader.at_css(".sr-only").text
  end

  test "dots are the canonical three dots" do
    loader = render { |v| v.studio_loader(style: :dots, label: "Alex is typing") }.at_css(".studio-loader")

    assert_equal "dots", loader["data-loader-style"]
    assert_equal 3, loader.css(".loading-dots > span").size
    assert_equal "Alex is typing", loader.at_css(".sr-only").text
  end

  test "a bar with a percent is a determinate progressbar" do
    loader = render { |v| v.studio_loader(style: :bar, percent: 62, label: "Uploading") }.at_css(".studio-loader")

    assert_equal "progressbar", loader["role"]
    assert_equal "62", loader["aria-valuenow"]
    assert_equal "0", loader["aria-valuemin"]
    assert_equal "100", loader["aria-valuemax"]
    assert_equal "Uploading", loader["aria-label"]
    assert_nil loader["aria-live"]
    assert loader.at_css(".progress-meter > .progress-meter-fill")
    assert_nil loader.at_css(".progress-meter--indeterminate")
    assert_includes loader["style"], "--studio-loader-size: 100%"
    assert_nil loader.at_css(".sr-only"), "its name is aria-label, not a hidden line inside a progressbar"
  end

  test "a bar with no percent sweeps and has no value" do
    loader = render { |v| v.studio_loader(style: :bar) }.at_css(".studio-loader")

    assert_nil loader["aria-valuenow"]
    assert loader.at_css(".progress-meter.progress-meter--indeterminate")
  end

  test "a pending spinner hides from assistive tech, as every pending loader does" do
    loader = render { |v| v.studio_loader_pending(style: :spinner) }.at_css(".studio-loader")

    assert_equal "true", loader["aria-hidden"]
    assert loader.key?("data-loader-pending")
    assert loader.key?("data-loader-mono")
    assert loader.at_css(".spinner")
  end

  # ── B ──────────────────────────────────────────────────────

  test "a skeleton is busy, its shapes are hidden, and one line names the wait" do
    root = render { |v| v.studio_skeleton(:avatar, count: 3, label: "Loading people", class: "sm:grid-cols-2") }.at_css(".studio-skeleton")

    assert_equal "true", root["aria-busy"]
    assert_equal "avatar", root["data-skeleton"]
    assert_includes root["class"], "sm:grid-cols-2"
    assert_equal "Loading people", root.at_css(".sr-only").text
    items = root.css(".studio-skeleton-item")
    assert_equal 3, items.size
    assert items.all? { |item| item["aria-hidden"] == "true" }
    assert_equal 3, root.css("[data-bone='avatar']").size
    assert_equal 6, root.css("[data-bone='line']").size
  end

  test "each kind draws its shapes, and the last of several lines is short" do
    lines = render { |v| v.studio_skeleton }.css("[data-bone='line']")
    assert_equal 3, lines.size
    assert_includes lines.last["style"], "--studio-skeleton-width: 60%"

    card = render { |v| v.studio_skeleton(:card) }
    assert card.at_css("[data-bone='media']")
    assert card.at_css("[data-bone='title']")

    media = render { |v| v.studio_skeleton(:media) }
    assert_equal 1, media.css(".studio-skeleton-bone").size
  end

  test "an unknown skeleton kind is refused" do
    assert_raises(ArgumentError) { render { |v| v.studio_skeleton(:table) } }
  end

  # ── C ──────────────────────────────────────────────────────

  test "page 1 holds its items, then the next page's frame with an ordinary link" do
    root = render_scroll(page: 1, next_url: "/posts?page=2").at_css("#posts")

    assert_includes root["class"], "studio-infinite-scroll"
    assert_equal "infinite-scroll", root["data-studio-controller"]
    assert_equal 2, root.css("> [data-item]").size, "page 1's items sit in the list itself"
    frame = root.at_css("turbo-frame#posts-page-2[data-infinite-scroll-next]")
    assert frame
    link = frame.at_css("a[data-infinite-scroll-more]")
    assert_equal "/posts?page=2", link["href"]
    assert_includes link.text, "Load more"
    assert link.at_css(".studio-loader[data-loader-pending][data-loader-style='spinner']")
    status = root.at_css("[data-infinite-scroll-status]")
    assert_equal "polite", status["aria-live"]
    assert_equal "status", status["role"]
  end

  test "a later page puts its items in its own frame, with the next frame nested inside" do
    root = render_scroll(page: 2, next_url: "/posts?page=3").at_css("#posts")

    page_frame = root.at_css("> turbo-frame#posts-page-2")
    assert page_frame, "page 2 answers the frame page 1 left for it"
    assert_equal 2, page_frame.css("> [data-item]").size
    assert page_frame.at_css("> turbo-frame#posts-page-3 a[href='/posts?page=3']")
  end

  test "the last page says it is done and leaves no frame waiting" do
    root = render_scroll(page: 3, next_url: nil).at_css("#posts")

    assert_nil root.at_css("[data-infinite-scroll-next]")
    assert_equal "That is everything", root.at_css("[data-infinite-scroll-done]").text
    assert_equal "That is everything", root["data-infinite-scroll-end"]
    assert_equal "%{count} more loaded", root["data-infinite-scroll-announce"]
  end

  # ── D ──────────────────────────────────────────────────────

  test "pull to refresh wraps its block with a hidden indicator and a status line" do
    root = render { |v| v.studio_pull_to_refresh(frame: "feed") { "<p data-body>hi</p>".html_safe } }.at_css(".studio-pull-refresh")

    assert_equal "pull-to-refresh", root["data-studio-controller"]
    assert_equal "feed", root["data-pull-to-refresh-frame"]
    indicator = root.at_css(".studio-pull-refresh-indicator")
    assert indicator.key?("hidden")
    assert_equal "true", indicator["aria-hidden"]
    assert root.at_css("[data-pull-to-refresh-status][role='status']")
    assert root.at_css("[data-body]")
  end

  # ── E ──────────────────────────────────────────────────────

  test "the plain styles set the canonical rules' knobs rather than restyling them" do
    css = File.read(MOTION_CSS)

    assert_match(/\.studio-loader\[data-loader-style="spinner"\] :where\(\.spinner\) \{[^}]*--spinner-color: var\(--studio-loader-color\)/m, css)
    assert_match(/\.studio-loader\[data-loader-style="dots"\] \.loading-dots \{[^}]*--loading-dots-color: var\(--studio-loader-color\)/m, css)
    assert_match(/\.studio-loader\[data-loader-style="bar"\] \.progress-meter \{[^}]*--progress: calc\(var\(--studio-loader-percent, 0\) \* 1%\)/m, css)
    assert_equal 1, css.scan(/^\.spinner \{/).size, "one spinner rule"
    # A host counts the selectors that end in ".spinner{" to prove the motion layer
    # is imported once (turf-monster test/lib/tailwind_css_first_test.rb), so the
    # family never ends a selector in it.
    assert_equal 1, css.scan(/\.spinner\s*\{/).size, "only the canonical rule ends in .spinner {"
  end

  test "the skeleton is a tint of the theme's text and stands still under reduced motion" do
    css = File.read(MOTION_CSS)
    family = css[css.index("LOADER FAMILY")..]

    assert_match(/--studio-skeleton-bone: color-mix\(in srgb, var\(--color-text\) 9%, transparent\)/, family)
    assert_match(/@media \(prefers-reduced-motion: reduce\) \{\s*\.studio-skeleton-bone \{ animation: none;/, family)
    assert_match(/\.studio-infinite-scroll turbo-frame \{ display: contents; \}/, family)
  end

  private

  def render
    view = ActionView::Base.with_empty_template_cache.with_view_paths([ File.join(ENGINE_ROOT, "app/views") ])
    view.extend(Studio::LoaderHelper)
    Nokogiri::HTML::DocumentFragment.parse(yield(view).to_s)
  end

  def render_scroll(page:, next_url:)
    render do |view|
      view.studio_infinite_scroll(id: "posts", page: page, next_url: next_url) do
        "<div data-item>a</div><div data-item>b</div>".html_safe
      end
    end
  end
end
