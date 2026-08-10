# frozen_string_literal: true

require "bundler/setup"

# Boot probe for test/integration/log_rotation_test.rb.
#
# Boots a throwaway Rails app — with the REAL Studio::Engine loaded — in a
# tmpdir the parent owns, under one scenario, then reports what the BOOTED
# logger actually is and whether the log file actually rotated. It runs as its
# own process because Rails.env and the app singleton are per-process, and the
# engine's caps differ by environment.
#
# Every fact reported here is read off the live logger object or off the
# filesystem after a real write — never off the config we hoped was applied.
#
# Contract (all via ENV, so the parent stays in charge):
#   PROBE_ROOT      Rails.root for the throwaway app (parent-created tmpdir)
#   PROBE_SCENARIO  default | opt_out | custom_size | host_logger | stdout_host
#   PROBE_SEED      bytes to pre-size log/<env>.log to before boot (sparse, so
#                   "17 MB" costs no disk); the first write then rotates iff the
#                   booted cap is below it
#   PROBE_RESULT    file to write the JSON result to (stdout stays free for the
#                   scenarios whose host logger writes to stdout)
#   RAILS_ENV       the environment to boot

require "json"
require "fileutils"
require "rails"
# lib/studio.rb declares defaults like `15.minutes` at require time, before
# Rails' own :load_active_support initializer would have run.
require "active_support/all"
require "action_controller/railtie"
require "action_view/railtie"

ROOT     = ENV.fetch("PROBE_ROOT")
SCENARIO = ENV.fetch("PROBE_SCENARIO", "default")
SEED     = ENV.fetch("PROBE_SEED", "0").to_i
RESULT   = ENV.fetch("PROBE_RESULT")

FileUtils.mkdir_p(File.join(ROOT, "log"))
LOG_PATH = File.join(ROOT, "log", "#{Rails.env}.log")
HOST_LOG = File.join(ROOT, "log", "host-chosen.log")

# Pre-size the log sparsely: stat.size is what Logger::LogDevice checks before
# each write, so this reproduces "the log grew past the cap" without writing
# tens of megabytes.
File.open(LOG_PATH, "w") { |f| f.truncate(SEED) } if SEED.positive?

require "studio" # defines Studio::Engine and registers it as a railtie

module ProbeApp
  class Application < ::Rails::Application
    config.root = ROOT
    config.load_defaults 8.1
    config.eager_load = false
    config.secret_key_base = "studio-engine-log-rotation-probe-not-a-real-secret"

    # The host app's choices, made HERE because config/application.rb and
    # config/environments/*.rb are the real seams a host would use — both load
    # before the engine's studio.logger initializer runs.
    case SCENARIO
    when "opt_out"
      Studio.local_log_max_bytes = false
    when "custom_size"
      Studio.local_log_max_bytes = 2 * 1024 * 1024
    when "host_logger"
      config.logger = ActiveSupport::Logger.new(HOST_LOG)
    when "stdout_host"
      # What every production.rb in the ecosystem does.
      config.logger = ActiveSupport::Logger.new($stdout)
    end

    # No asset-pipeline gem in this throwaway app; seed the shim the engine's
    # studio.assets initializer appends to (test/dummy does the same).
    assets = ActiveSupport::OrderedOptions.new
    assets.precompile = []
    config.assets = assets
  end
end

ProbeApp::Application.initialize!

# Unwrap Rails' BroadcastLogger -> the logger that owns the log device.
inner  = Rails.logger.respond_to?(:broadcasts) ? Rails.logger.broadcasts.first : Rails.logger
logdev = inner.instance_variable_get(:@logdev)

# The behavioral act: one real write through the booted Rails logger. `error`
# rather than `info` so no environment's log_level can swallow it.
Rails.logger.error("studio-engine log rotation probe")

File.write(RESULT, JSON.generate(
  scenario: SCENARIO,
  env: Rails.env.to_s,
  # Read off the live log device, not off config.
  cap: logdev&.instance_variable_get(:@shift_size),
  shift_age: logdev&.instance_variable_get(:@shift_age),
  log_basename: logdev&.filename && File.basename(logdev.filename),
  config_log_file_size: Rails.application.config.log_file_size,
  # Read off the filesystem, after the write.
  rotated: File.exist?("#{LOG_PATH}.0"),
  env_log_bytes: File.exist?(LOG_PATH) ? File.size(LOG_PATH) : nil,
  env_log_exists: File.exist?(LOG_PATH),
  host_log_bytes: File.exist?(HOST_LOG) ? File.size(HOST_LOG) : nil
))
