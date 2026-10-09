# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"

# [unit] Leaflet is VENDORED into the engine and served by the consumer's asset
# pipeline, never from a CDN and never from a consumer's public/. These are the
# static halves of that claim; e2e/site_footer.spec.js is the half that loads it.
class VendoredLeafletTest < Minitest::Test
  ROOT   = File.expand_path("../..", __dir__)
  ENGINE = File.join(ROOT, "lib/studio/engine.rb")
  SCRIPT = File.join(ROOT, "app/assets/javascripts/studio/leaflet.js")
  STYLES = File.join(ROOT, "app/assets/stylesheets/studio/leaflet.css")
  MAP    = File.join(ROOT, "app/views/studio/site_footer/_map.html.erb")
  ASSETS = File.join(ROOT, "app/views/studio/site_footer/_map_assets.html.erb")
  HEAD   = File.join(ROOT, "app/views/layouts/studio/_head.html.erb")

  def test_both_files_are_precompiled
    engine = File.read(ENGINE)

    assert_match(%r{^\s*studio/leaflet\.js\s*$}, engine,
                 "studio/leaflet.js must be in the engine's assets.precompile list, or Sprockets " \
                 "hosts (mcritchie-studio, turf-monster) will not serve it")
    assert_match(%r{^\s*studio/leaflet\.css\s*$}, engine,
                 "studio/leaflet.css must be in the engine's assets.precompile list")
  end

  def test_the_vendored_script_is_leaflet_at_the_pinned_version
    body = File.read(SCRIPT)

    assert_operator body.bytesize, :>, 100_000, "the vendored file is too small to be a Leaflet build"
    assert_includes body, 't.version="1.9.4"', "the vendored build is not Leaflet 1.9.4"
    assert_includes body, "BSD 2-Clause License", "the licence notice must travel with the file"
    refute_includes body, "//# sourceMappingURL", "the source map is not shipped, so nothing may point at it"
  end

  def test_the_vendored_stylesheet_points_at_no_image_that_is_not_shipped
    body = File.read(STYLES)

    assert_includes body, ".leaflet-container", "the vendored file does not look like Leaflet's stylesheet"
    assert_includes body, "BSD 2-Clause License", "the licence notice must travel with the file"
    assert_empty body.scan(/url\((?!#)[^)]*\)/),
                 "the stylesheet references a file by url(). The engine ships no Leaflet images, and an " \
                 "asset pipeline that resolves url() (propshaft) reports each one as missing."
  end

  def test_the_map_addresses_leaflet_through_the_asset_pipeline
    map = File.read(MAP)

    assert_match(/data-leaflet-js="<%= asset_path\("studio\/leaflet\.js"\) %>"/, map)
    assert_match(/data-leaflet-css="<%= asset_path\("studio\/leaflet\.css"\) %>"/, map)
  end

  # A hard-coded path is what the hub's first version had (/vendor/leaflet-1.9.4/…
  # under its own public/), and it is exactly what a gem cannot rely on.
  def test_no_footer_view_hard_codes_a_leaflet_path_or_a_cdn
    Dir[File.join(ROOT, "app/views/studio/site_footer/*.erb")].each do |path|
      source = File.read(path).gsub(/<%#.*?%>/m, "")

      refute_match(%r{/vendor/leaflet}, source, "#{File.basename(path)} points at a consumer's public/vendor")
      refute_match(/unpkg\.com|cdnjs|jsdelivr/, source, "#{File.basename(path)} loads Leaflet from a CDN")
    end
  end

  def test_the_head_does_not_load_leaflet
    refute_match(/leaflet/i, File.read(HEAD).gsub(/<%#.*?%>/m, ""),
                 "Leaflet is fetched on demand by the map's own script. In the head, every page of every " \
                 "app would pay for it.")
  end

  def test_tiles_come_from_the_keyless_openstreetmap_host
    assert_includes File.read(File.join(ROOT, "app/javascript/studio/footer_map.js")),
                    'export const TILES = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"'
  end
end
