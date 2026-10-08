# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

# [integration] A host's importmap carries the engine's pins with no host edit.
#
# The dummy host has importmap-rails and NO config/importmap.rb of its own: it
# writes nothing to get the pins. The studio.importmap initializer
# (lib/studio/engine.rb) adds the engine's config/importmap.rb ahead of the
# host's, which this holds:
#
#   1. every module under app/javascript/studio is pinned as studio/<name>, and
#      the rendered importmap tags carry it, preloading only the boot graph
#      (studio/application and what it imports) and @hotwired/stimulus;
#   2. the engine's map is drawn before the host's, so a host pin of the same
#      name wins (the control: the same draw with the engine's map last loses);
#   3. each module resolves as an asset: on the asset paths and in sprockets'
#      precompile list, and its logical path is not one of the classic scripts
#      in app/assets/javascripts/studio.
class EngineImportmapPinsTest < ActiveSupport::TestCase
  ENGINE_ROOT = Studio::Engine.root
  ENGINE_MAP = ENGINE_ROOT.join("config/importmap.rb")
  MODULE_ROOT = ENGINE_ROOT.join("app/javascript")

  # The engine's own modules. A vendored library (studio/vendor/) is pinned
  # under its package name instead, asserted below.
  def engine_modules
    Dir[MODULE_ROOT.join("studio/**/*.js").to_s].sort.map do |path|
      Pathname(path).relative_path_from(MODULE_ROOT).to_s.delete_suffix(".js")
    end.reject { |name| name.start_with?("studio/vendor/") }
  end

  def pins(map = Rails.application.importmap)
    map.send(:expanded_packages_and_directories)
  end

  test "the host writes nothing: no config/importmap.rb of its own" do
    refute File.exist?(Rails.root.join("config/importmap.rb")),
           "the dummy host has its own importmap, so it no longer proves 'no host edit'"
    assert_includes Rails.application.config.importmap.paths.map(&:to_s), ENGINE_MAP.to_s
  end

  def boot_graph = Studio::Engine.javascript_boot_graph

  test "every engine module is pinned as studio/<name>, and only the boot graph is preloaded" do
    refute_empty engine_modules, "the engine ships no module under app/javascript/studio"

    engine_modules.each do |name|
      pin = pins[name]
      refute_nil pin, "#{name} is not in the host's importmap"
      assert_equal "#{name}.js", pin.path
      assert_equal boot_graph.include?(name), pin.preload,
                   boot_graph.include?(name) ? "#{name} is in the boot graph but not preloaded" : "#{name} is preloaded on every page"
    end
    assert_equal "studio/vendor/stimulus.js", pins["@hotwired/stimulus"].path
    assert_equal true, pins["@hotwired/stimulus"].preload
    assert_nil pins["studio/vendor/stimulus"], "a vendored library is pinned by its package name only"
  end

  test "the boot graph follows studio/application's static imports" do
    assert_equal %w[studio/alpine_shims studio/alpine_stores studio/application studio/controllers/modal_host_controller
                    studio/controllers/nav_collapse_controller studio/controllers/toast_controller studio/head_chrome
                    studio/modal_host studio/nav_collapse studio/pinned_stack studio/toast], boot_graph
    refute_includes boot_graph, "studio/local_path", "a module nothing in the boot imports is not preloaded"
  end

  test "the rendered importmap tags carry the pins and preload only the boot graph" do
    html = ActionController::Base.helpers.javascript_importmap_tags("application")
    doc = Nokogiri::HTML.fragment(html)

    imports = JSON.parse(doc.at_css("script[type=importmap]").text).fetch("imports")
    engine_modules.each { |name| assert imports.key?(name), "#{name} is missing from the rendered import map" }

    preloads = doc.css("link[rel=modulepreload]").map { |link| link["href"] }
    engine_modules.each do |name|
      preloaded = preloads.any? { |href| href.include?("/#{name}.js") || href.include?("/#{name}-") }
      assert_equal boot_graph.include?(name), preloaded, "#{name}: preloaded #{preloaded}, in the boot graph #{boot_graph.include?(name)}"
    end
  end

  # Drawn the way importmap-rails draws: every path in config.importmap.paths,
  # in order. The host's map is the last one.
  def draw(paths)
    paths.each_with_object(Importmap::Map.new) { |path, map| map.draw(path) }
  end

  test "a host pin of the same name wins, because the engine's map is drawn first" do
    name = engine_modules.first
    Dir.mktmpdir("host-importmap") do |dir|
      host_map = File.join(dir, "importmap.rb")
      File.write(host_map, %(pin "#{name}", to: "host_override.js"\n))

      engine_first = Rails.application.config.importmap.paths.index { |path| path.to_s == ENGINE_MAP.to_s }
      host_slot = Rails.application.config.importmap.paths.index { |path| path.to_s == Rails.root.join("config/importmap.rb").to_s }
      assert_operator engine_first, :<, host_slot, "the engine's map is not drawn before the host's"

      assert_equal "host_override.js", pins(draw([ENGINE_MAP, host_map]))[name].path

      # The control: drawn the other way round, the engine's pin wins. So the
      # order above is what lets the host override.
      assert_equal "#{name}.js", pins(draw([host_map, ENGINE_MAP]))[name].path
    end
  end

  test "each module resolves as an asset and does not shadow a classic script" do
    assert_includes Rails.application.config.assets.paths.map(&:to_s), MODULE_ROOT.to_s
    classic = Dir[ENGINE_ROOT.join("app/assets/javascripts/studio/*.js").to_s].map { |path| "studio/#{File.basename(path)}" }

    engine_modules.each do |name|
      assert_includes Rails.application.config.assets.precompile, "#{name}.js"
      refute_includes classic, "#{name}.js", "#{name}.js is also a classic script's logical path"
    end
  end
end
