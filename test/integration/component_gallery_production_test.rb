# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "json"
require "tmpdir"
require "rbconfig"

# [integration] Where the component gallery is drawn, and what an app that does
# not want it pays. Each case boots test/support/component_gallery_probe.rb in
# its own process, because Rails.env and the loaded gems are fixed per process.
#
# Lookbook is opt-in by bundle: the engine never requires it. So:
#   - production without lookbook in the bundle (turf, cyvasse, industries,
#     moms) loads no Lookbook constant and no Lookbook file, and draws no
#     gallery route, asset route, ViewComponent preview route or Rack::Static;
#   - production with lookbook bundled but no flag draws none of them either;
#   - production with lookbook and Studio.lookbook_in_production draws the
#     gallery and its assets, and still no ViewComponent preview route;
#   - development draws the gallery only when the bundle has lookbook;
#   - a bundle that loads lookbook before studio-engine draws no gallery and
#     prints what to change.
# The engine's importmap pins reach the host in every case.
class ComponentGalleryProductionTest < Minitest::Test
  PROBE = File.expand_path("../support/component_gallery_probe.rb", __dir__)
  ENGINE_ROOT = File.expand_path("../..", __dir__)

  def probe(env:, gem: false, flag: false, eager: env == "production")
    Dir.mktmpdir("studio-gallery-probe") do |root|
      result = File.join(root, "result.json")
      vars = {
        "RAILS_ENV" => env, "PROBE_ROOT" => root, "PROBE_RESULT" => result,
        "PROBE_LOOKBOOK" => flag ? "1" : "0", "PROBE_LOOKBOOK_GEM" => { true => "1", false => "0" }.fetch(gem, gem.to_s),
        "PROBE_EAGER" => eager ? "1" : "0", "BUNDLE_GEMFILE" => File.join(ENGINE_ROOT, "Gemfile")
      }
      output = IO.popen(vars, [RbConfig.ruby, PROBE], err: %i[child out], &:read)
      assert $?.success?, "the #{env} probe failed to boot:\n#{output}"
      JSON.parse(File.read(result)).merge("output" => output)
    end
  end

  def assert_no_gallery(result)
    refute result["mounted"]
    assert_empty result["gallery_routes"], "the gallery is drawn"
    assert_empty result["asset_routes"], "Lookbook's assets are routed"
    refute result["rack_static"], "a Rack::Static serves /lookbook-assets"
    assert_includes result["importmap_pins"], "studio/local_path"
  end

  def test_production_without_lookbook_in_the_bundle_loads_none_of_it
    result = probe(env: "production")

    refute result["lookbook_requirable"], "the probe meant to boot without lookbook on the load path"
    refute result["lookbook_constant"], "a Lookbook constant is defined"
    assert_equal 0, result["lookbook_files"], "Lookbook files were loaded"
    assert_empty result["preview_routes"], "ViewComponent's preview pages are drawn in production"
    assert_no_gallery(result)
  end

  # The control for the case above: the same boot with lookbook in the bundle
  # does load it, so "no Lookbook" above is the bundle and not a broken probe.
  def test_control_production_with_lookbook_bundled_but_no_flag_loads_it_and_draws_nothing
    result = probe(env: "production", gem: true)

    assert result["lookbook_constant"]
    assert_operator result["lookbook_files"], :>, 0
    assert_empty result["preview_routes"]
    assert_no_gallery(result)
  end

  def test_production_with_lookbook_and_the_flag_draws_the_gallery_behind_the_wall
    result = probe(env: "production", gem: true, flag: true)

    assert result["mounted"]
    refute_empty result["gallery_routes"], "the flag drew no gallery"
    refute_empty result["asset_routes"], "the gallery's assets are not routed"
    assert_empty result["preview_routes"], "ViewComponent's preview pages are drawn in production"
    refute result["rack_static"]
  end

  def test_development_without_lookbook_draws_no_gallery
    result = probe(env: "development")

    refute result["lookbook_constant"]
    assert_no_gallery(result)
  end

  def test_development_with_lookbook_draws_the_gallery_without_the_flag
    result = probe(env: "development", gem: true)

    assert result["mounted"]
    refute_empty result["gallery_routes"]
    refute_empty result["preview_routes"], "ViewComponent's preview pages, behind the wall, are drawn in development"
    assert(result["preview_routes"].all? { |path| path.start_with?("/admin/style/previews") },
           "a preview route sits outside /admin/style: #{result['preview_routes'].inspect}")
    refute result["rack_static"]
  end

  # The same boot as the case above with the two requires swapped.
  def test_lookbook_loaded_before_the_engine_draws_no_gallery_and_says_why
    result = probe(env: "development", gem: :first)

    assert result["lookbook_constant"], "the probe meant to load lookbook"
    assert_no_gallery(result)
    assert_includes result["output"], 'Move `gem "lookbook"` below `gem "studio-engine"` in the Gemfile'
    assert_includes result["output"], "NOT mounted"
    refute_includes probe(env: "development", gem: true)["output"], "NOT mounted", "control: in order, no warning"
  end

  # What Lookbook costs a production process that loads it. Reported, not
  # asserted against a number: resident size varies by machine. It is the
  # figure behind keeping lookbook out of the runtime dependencies.
  def test_report_the_memory_lookbook_costs_a_production_process
    without = probe(env: "production")["rss_mb"]
    with = probe(env: "production", gem: true)["rss_mb"]
    puts format("\n[memory] production probe RSS: %.1f MB without lookbook, %.1f MB with it (%+.1f MB)",
                without, with, with - without)
    assert_operator without, :>, 0
  end
end
