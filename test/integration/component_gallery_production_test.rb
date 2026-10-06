# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "json"
require "tmpdir"
require "rbconfig"

# [integration] Where the component gallery is drawn: every app in development,
# in production only the app that opts in (Studio.lookbook_in_production, the
# hub). Each case boots test/support/component_gallery_probe.rb in its own
# process, because Rails.env is fixed per process.
#
# Production without the flag (turf, cyvasse, industries, moms) serves nothing
# of Lookbook: no gallery route, no asset route, no ViewComponent preview route,
# no Rack::Static. With the flag the gallery and its assets are drawn and the
# ViewComponent preview pages still are not. The engine's importmap pins reach
# the host in every case.
class ComponentGalleryProductionTest < Minitest::Test
  PROBE = File.expand_path("../support/component_gallery_probe.rb", __dir__)
  ENGINE_ROOT = File.expand_path("../..", __dir__)

  def probe(env:, lookbook: false, eager: false)
    Dir.mktmpdir("studio-gallery-probe") do |root|
      result = File.join(root, "result.json")
      vars = {
        "RAILS_ENV" => env, "PROBE_ROOT" => root, "PROBE_RESULT" => result,
        "PROBE_LOOKBOOK" => lookbook ? "1" : "0", "PROBE_EAGER" => eager ? "1" : "0",
        "BUNDLE_GEMFILE" => File.join(ENGINE_ROOT, "Gemfile")
      }
      output = IO.popen(vars, [RbConfig.ruby, PROBE], err: %i[child out], &:read)
      assert $?.success?, "the #{env} probe failed to boot:\n#{output}"
      JSON.parse(File.read(result))
    end
  end

  def test_production_without_the_flag_serves_nothing_of_lookbook
    result = probe(env: "production", eager: true)

    refute result["mounted"]
    assert_empty result["gallery_routes"], "the gallery is drawn in production without the flag"
    assert_empty result["asset_routes"], "Lookbook's assets are routed in production without the flag"
    assert_empty result["preview_routes"], "ViewComponent's preview pages are drawn in production"
    refute result["rack_static"], "Lookbook's Rack::Static serves /lookbook-assets in production"
    assert_includes result["importmap_pins"], "studio/local_path"
  end

  def test_production_with_the_flag_draws_the_gallery_behind_the_wall
    result = probe(env: "production", lookbook: true, eager: true)

    assert result["mounted"]
    refute_empty result["gallery_routes"], "the hub's flag drew no gallery"
    refute_empty result["asset_routes"], "the gallery's assets are not routed"
    assert_empty result["preview_routes"], "ViewComponent's preview pages are drawn in production"
    refute result["rack_static"]
  end

  def test_development_draws_the_gallery_without_the_flag
    result = probe(env: "development")

    assert result["mounted"]
    refute_empty result["gallery_routes"]
    refute_empty result["preview_routes"], "ViewComponent's preview pages, behind the wall, are drawn in development"
    assert(result["preview_routes"].all? { |path| path.start_with?("/admin/style/previews") },
           "a preview route sits outside /admin/style: #{result['preview_routes'].inspect}")
    refute result["rack_static"]
  end
end
