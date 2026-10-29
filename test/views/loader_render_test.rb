# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "tmpdir"
require "fileutils"
require_relative "../../app/helpers/studio/loader_helper"

# [unit] The branded loader, rendered (Studio::LoaderHelper, docs/LOADER.md).
#
# The load-bearing shapes:
#   A. It draws the APP's icon: the configured one, else the Navbar Logo the
#      app already declares, with no per-app markup.
#   B. It takes the app's colours from the theme: the stylesheet section reads
#      --color-primary and --color-accent, never a brand hex for the icon parts.
#   C. One class and one size variable, the style on data-loader-style.
#   D. A signature style inlines only the art's marked layers over the icon,
#      and falls back to Breathe when the art is missing.
#   E. A pending loader is hidden from assistive tech and drawn in currentColor;
#      the overlay renders hidden with its delay.
#   F. Reduced motion stops every animation and hides the moving parts.
class LoaderRenderTest < ActiveSupport::TestCase
  ENGINE_ROOT = File.expand_path("../..", __dir__)
  FIXTURES = File.join(ENGINE_ROOT, "test/fixtures/files/loader")
  MOTION_CSS = File.join(ENGINE_ROOT, "app/assets/tailwind/studio_engine/engine-motion.css")

  setup do
    @saved_loader = Studio.loader
    @saved_logos = Studio.theme_logos
    @saved_brand = Studio.navbar_brand
    Studio.navbar_brand = nil
    Studio.theme_logos = [ { file: "brand/icon.svg", title: "Navbar Logo" } ]
  end

  teardown do
    Studio.loader = @saved_loader
    Studio.theme_logos = @saved_logos
    Studio.navbar_brand = @saved_brand
  end

  # ── A + C ─────────────────────────────────────────────────

  test "by default it breathes the app's own Navbar Logo, at one class and a size variable" do
    loader = render_loader.at_css(".studio-loader")

    assert_equal "breathe", loader["data-loader-style"]
    assert_equal "status", loader["role"]
    assert_includes loader["style"], "--studio-loader-size: 96px"
    assert_equal "/brand/icon.svg", loader.at_css("img.studio-loader-icon")["src"]
    assert loader.at_css(".studio-loader-halo"), "breathe draws its halo"
    assert_equal "Loading", loader.at_css(".sr-only").text
  end

  test "the configured icon wins over the Navbar Logo" do
    Studio.loader = { style: :orbit, icon: "/brand/icon-dark.svg" }
    loader = render_loader(size: 32, label: "Loading contests").at_css(".studio-loader")

    assert_equal "orbit", loader["data-loader-style"]
    assert_includes loader["style"], "--studio-loader-size: 32px"
    assert_equal "/brand/icon-dark.svg", loader.at_css("img.studio-loader-icon")["src"]
    assert loader.at_css(".studio-loader-orb > .studio-loader-spark")
    assert_equal "Loading contests", loader.at_css(".sr-only").text
  end

  test "every generic style draws only the icon image, so it fits any app" do
    %i[breathe liquid orbit steel].each do |style|
      loader = render_loader(style: style).at_css(".studio-loader")
      assert_equal style.to_s, loader["data-loader-style"]
      assert loader.css("img.studio-loader-icon").all? { |img| img["src"] == "/brand/icon.svg" }, style.to_s
      assert_nil loader.at_css("path[d^='M133']"), "#{style} inlines no brand art"
    end
  end

  test "liquid takes a percent and clamps it" do
    loader = render_loader(style: :liquid, percent: 140).at_css(".studio-loader")

    assert loader.key?("data-loader-percent")
    assert_includes loader["style"], "--studio-loader-percent: 100"
    assert loader.at_css(".studio-loader-ghost"), "the dim icon under the fill"
    assert loader.at_css(".studio-loader-fill > img.studio-loader-icon")
  end

  # ── B ─────────────────────────────────────────────────────

  test "the colours come from the theme, so every app's loader is in its own colours" do
    section = File.read(MOTION_CSS)[/BRANDED LOADER.*/m]

    assert_includes section, "--studio-loader-color: var(--color-primary)"
    assert_includes section, "--studio-loader-hot: var(--color-accent)"
    assert_includes section, "var(--color-page)"
  end

  # ── D ─────────────────────────────────────────────────────

  test "sparkle inlines the art's sparks, in order, over the icon image" do
    with_public("brand/sparkle.svg" => "studio-sparkle.svg") do
      loader = render_loader(style: :sparkle, art: "/brand/sparkle.svg").at_css(".studio-loader")

      assert_equal "sparkle", loader["data-loader-style"]
      assert loader.at_css("img.studio-loader-icon")
      sparks = loader.css("svg.studio-loader-art path.studio-loader-sparkle")
      assert_equal 5, sparks.size
      assert_equal "0 0 370.2 300.2", loader.at_css("svg.studio-loader-art")["viewbox"]
      assert_includes sparks[2]["style"], "--studio-loader-i: 2"
      assert_equal "translate(0,0)", sparks[0]["transform"]
    end
  end

  test "weld bead draws six cooling layers on the outline, the hottest three glowing" do
    with_public("brand/bead.svg" => "welding-bead.svg") do
      Studio.loader = { style: :weld_bead, art: "/brand/bead.svg" }
      loader = render_loader.at_css(".studio-loader")

      assert_equal "weld-bead", loader["data-loader-style"]
      layers = loader.css("path.studio-loader-bead")
      assert_equal (1..6).map(&:to_s), layers.map { |l| l["data-layer"] }
      assert layers.all? { |l| l["d"].start_with?("M133.1 300") }
      glow = loader.at_css("g[filter]")
      assert_equal 3, glow.css("path").size
      assert_equal "url(##{loader.at_css('filter')['id']})", glow["filter"], "the glow names its own instance's filter"
    end
  end

  test "a signature style whose art is missing falls back to breathe" do
    with_public({}) do
      loader = render_loader(style: :sparkle, art: "/brand/missing.svg").at_css(".studio-loader")
      assert_equal "breathe", loader["data-loader-style"]
    end
  end

  # ── E ─────────────────────────────────────────────────────

  test "a pending loader hides from assistive tech and draws in the text colour" do
    loader = render_view { |view| view.studio_loader_pending }.at_css(".studio-loader")

    assert loader.key?("data-loader-pending")
    assert loader.key?("data-loader-mono")
    assert_equal "true", loader["aria-hidden"]
    assert_nil loader["role"]
    assert_includes loader["style"], "--studio-loader-size: 18px"
    assert_includes loader.at_css("span.studio-loader-icon")["style"], %(--studio-loader-mask: url("/brand/icon.svg"))
    assert_nil loader.at_css(".sr-only")
  end

  test "the overlay renders hidden, once, with its delay and a caption line" do
    overlay = render_view { |view| view.studio_loader_overlay(delay: 500) }.at_css(".studio-loader-overlay")

    assert overlay.key?("hidden")
    assert_equal "500", overlay["data-delay"]
    assert overlay.key?("data-studio-loader-overlay")
    assert overlay.at_css(".studio-loader-overlay-panel .studio-loader[role=status]")
    assert overlay.at_css("[data-studio-loader-caption]")
  end

  test "pending loaders show only inside a busy button or form" do
    css = File.read(MOTION_CSS)

    assert_includes css, ".studio-loader[data-loader-pending] { display: none; }"
    assert_includes css, %([aria-busy="true"] .studio-loader[data-loader-pending] { display: inline-grid; })
  end

  # ── F ─────────────────────────────────────────────────────

  test "under reduced motion every loader is a still icon" do
    section = File.read(MOTION_CSS)[/BRANDED LOADER.*/m]
    reduced = section[/@media \(prefers-reduced-motion: reduce\) \{.*?\n  \}/m]

    assert reduced, "the loader ships a reduced-motion block"
    assert_match(/\.studio-loader \*,.*animation: none !important/m, reduced)
    %w[.studio-loader-halo .studio-loader-orb .studio-loader-art].each do |part|
      assert_includes reduced, part, "#{part} is not drawn under reduced motion"
    end
  end

  private

  def with_public(files)
    Dir.mktmpdir do |root|
      files.each do |target, fixture|
        FileUtils.mkdir_p(File.join(root, File.dirname(target)))
        FileUtils.cp(File.join(FIXTURES, fixture), File.join(root, target))
      end
      original = Rails.method(:public_path)
      begin
        Rails.define_singleton_method(:public_path) { Pathname.new(root) }
        yield root
      ensure
        Rails.define_singleton_method(:public_path, original)
      end
    end
  end

  def render_loader(**options)
    render_view { |view| view.studio_loader(**options) }
  end

  def render_view
    view = ActionView::Base.with_empty_template_cache.with_view_paths([ File.join(ENGINE_ROOT, "app/views") ])
    view.extend(Studio::LoaderHelper)
    Nokogiri::HTML::DocumentFragment.parse(yield(view).to_s)
  end
end
