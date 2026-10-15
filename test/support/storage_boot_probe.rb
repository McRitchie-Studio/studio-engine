# frozen_string_literal: true

# A host booted in its own process, in the environment the caller names, to
# answer one question for test/integration/storage_boot_test.rb: what storage
# does an app get from the engine (Studio::Storage)? Rails.env, ENV and the app
# singleton are fixed per process, so production cannot be asked from the dummy.
#
# The host is what a consumer is: Active Record and Active Storage loaded, its
# own config/storage.yml and config/initializers/studio.rb, both written under
# PROBE_ROOT by the test, which is what lets each case hand the app a different
# file. It records what it booted into PROBE_RESULT, or the boot error.
require "bundler/setup"
require "json"
require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "active_storage/engine"
require "importmap-rails"
require "studio"

ROOT = ENV.fetch("PROBE_ROOT")
RESULT = ENV.fetch("PROBE_RESULT")
ENV["DATABASE_URL"] ||= "sqlite3::memory:"

module StorageBootProbe
  class Application < ::Rails::Application
    config.root = ROOT
    config.load_defaults 8.1
    config.eager_load = false
    config.secret_key_base = "studio-engine-storage-probe-not-a-real-secret"
    config.logger = ActiveSupport::Logger.new(IO::NULL)
    config.log_level = :fatal
    config.hosts.clear

    assets = ActiveSupport::OrderedOptions.new
    assets.precompile = []
    assets.paths = []
    config.assets = assets

    # What config/environments/<env>.rb selects in a consumer.
    config.active_storage.service = ENV.fetch("PROBE_SERVICE", "test").to_sym
  end
end

def write_result(payload)
  File.write(RESULT, JSON.generate(payload))
end

begin
  Rails.application.initialize!
rescue StandardError => error
  write_result("booted" => false, "error_class" => error.class.name, "error" => error.message)
  exit 0
end

result = {
  "booted" => true,
  "rails_env" => Rails.env.to_s,
  "s3_endpoint" => Studio.s3_endpoint,
  "s3_region" => Studio.s3_region,
  "s3_public_url" => Studio.s3_public_url,
  "s3_access_key_id_set" => !Studio.s3_access_key_id.to_s.empty?
}

begin
  ActiveStorage::Blob # loading Blob runs Active Storage's service registry hook
  result["default_service"] = ActiveStorage::Blob.service.class.name
  result["services"] = %w[test amazon amazon_dev].to_h do |name|
    service = ActiveStorage::Blob.services.fetch(name.to_sym) { nil }
    entry = service && { "class" => service.class.name }
    entry["bucket"] = service.bucket.name if service.respond_to?(:bucket)
    [name, entry]
  end
rescue StandardError => error
  result["services_error"] = "#{error.class}: #{error.message}"
end

write_result(result)
