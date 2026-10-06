# frozen_string_literal: true

# A host booted in its own process, in the environment the caller names, to
# answer one question for test/integration/component_gallery_production_test.rb:
# what of the component gallery does this app serve? Rails.env and the app
# singleton are per process, so production cannot be asked from the dummy.
#
# The host is as thin as the question allows: no ActiveRecord (nothing here
# reads a user), importmap-rails as every consumer has it, and Studio.routes
# drawn the way a consumer draws them.
#
#   PROBE_LOOKBOOK=1      sets Studio.lookbook_in_production, as a host
#                         initializer does, before the draw
#   PROBE_LOOKBOOK_GEM=1  the host's bundle has lookbook: it is required after
#                         studio-engine, as Bundler.require does. Otherwise
#                         lookbook is taken off the load path before anything
#                         loads, so a require of it would fail exactly as it
#                         does in a bundle without it.
require "bundler/setup"
LOOKBOOK_IN_BUNDLE = ENV["PROBE_LOOKBOOK_GEM"] == "1"
$LOAD_PATH.reject! { |path| path.include?("/lookbook-") } unless LOOKBOOK_IN_BUNDLE
require "json"
require "rails"
require "active_model/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "importmap-rails"
require "studio"
require "lookbook" if LOOKBOOK_IN_BUNDLE

ROOT = ENV.fetch("PROBE_ROOT")
RESULT = ENV.fetch("PROBE_RESULT")

module ComponentGalleryProbe
  class Application < ::Rails::Application
    config.root = ROOT
    config.load_defaults 8.1
    config.eager_load = ENV["PROBE_EAGER"] == "1"
    config.secret_key_base = "studio-engine-component-gallery-probe-not-a-real-secret"
    config.logger = ActiveSupport::Logger.new(IO::NULL)
    config.log_level = :fatal
    config.hosts.clear

    assets = ActiveSupport::OrderedOptions.new
    assets.precompile = []
    assets.paths = []
    config.assets = assets

    # What a host's config/initializers/studio.rb does. Here rather than in a
    # file because the probe has no initializers directory; it runs in the same
    # phase, after the engine's own initializers.
    initializer "probe.studio_config", after: :load_config_initializers do
      Studio.lookbook_in_production = ENV["PROBE_LOOKBOOK"] == "1"
    end
  end
end

ComponentGalleryProbe::Application.initialize!
Rails.application.routes.draw { Studio.routes(self) }

paths = Rails.application.routes.routes.map { |route| route.path.spec.to_s }
File.write(RESULT, JSON.generate(
  "env" => Rails.env,
  "lookbook_constant" => defined?(::Lookbook) ? true : false,
  "lookbook_files" => $LOADED_FEATURES.count { |path| path.include?("/lookbook-") },
  "lookbook_requirable" => begin
    Gem::Specification.find_by_name("lookbook") && $LOAD_PATH.any? { |path| path.include?("/lookbook-") }
  rescue Gem::MissingSpecError
    false
  end,
  "rss_mb" => (3.times { GC.start }; `ps -o rss= -p #{Process.pid}`.to_i / 1024.0),
  "mounted" => Studio.lookbook_mounted?,
  "gallery_routes" => paths.select { |path| path.start_with?(Studio::ComponentGallery::MOUNT_PATH) },
  "asset_routes" => paths.select { |path| path.start_with?(Studio::ComponentGallery::ASSETS_PATH) },
  "preview_routes" => paths.select { |path| path.include?("view_components") || path.start_with?(Studio::ComponentGallery::PREVIEWS_ROUTE) },
  "rack_static" => Rails.application.middleware.any? { |middleware| middleware.klass == Rack::Static },
  "importmap_pins" => Rails.application.importmap.send(:expanded_packages_and_directories).keys
))
