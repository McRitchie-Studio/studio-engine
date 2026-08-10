# frozen_string_literal: true

require "bundler/setup"

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"

# BEHAVIORAL test for the engine's `studio.logger` initializer.
#
# It asserts the PROPERTY — a booted host app's local log file actually rotates
# once it passes the engine's cap — not the spelling of the config that is meant
# to produce it. A test that greps lib/studio/engine.rb for "log_file_size", or
# that reads back the config value it just set, keeps passing after someone
# reorders the initializer and breaks the behavior outright. That failure is not
# hypothetical: an ordinary engine initializer CANNOT set the logger at all,
# because Rails' `:initialize_logger` is a bootstrap initializer and has already
# built Rails.logger by then.
#
# Each case boots a real Rails app (with the real Studio::Engine) in its own
# process via test/support/log_rotation_probe.rb, because Rails.env and the
# application singleton are per-process and the caps differ by environment.
#
# The `opt_out` case is the mutation control: same 17 MB log, engine cap
# switched off, and it must NOT rotate. Without it, "rotated: true" would also
# be satisfied by Rails' own 100 MB default and this file would prove nothing.
class LogRotationBootTest < Minitest::Test
  MB = 1024 * 1024
  PROBE = File.expand_path("../support/log_rotation_probe.rb", __dir__)
  ENGINE_ROOT = File.expand_path("../..", __dir__)
  RAILS_DEFAULT_CAP = 100 * MB # config.load_defaults "7.1", when Rails.env.local?

  def test_development_log_rotates_at_the_engine_cap_not_rails_100mb
    result = probe(env: "development", seed: 17 * MB)

    assert_equal 16 * MB, result["cap"],
                 "expected the booted development logger to carry the engine's 16 MB cap"
    refute_equal RAILS_DEFAULT_CAP, result["cap"],
                 "the booted cap is still Rails' 100 MB default — studio.logger did not take effect"
    assert_equal "development.log", result["log_basename"]
    assert result["rotated"],
           "a 17 MB development.log must have rotated to development.log.0 on the first write"
    assert_operator result["env_log_bytes"], :<, MB,
                    "after rotating, development.log should start over near empty"
  end

  def test_test_log_rotates_at_the_engine_cap
    result = probe(env: "test", seed: 9 * MB)

    assert_equal 8 * MB, result["cap"],
                 "expected the booted test logger to carry the engine's 8 MB cap"
    assert_equal "test.log", result["log_basename"]
    assert result["rotated"],
           "a 9 MB test.log must have rotated to test.log.0 on the first write"
  end

  def test_one_rotated_sibling_is_kept_so_the_cap_bounds_total_disk
    result = probe(env: "test", seed: 9 * MB)

    assert_equal 1, result["shift_age"],
                 "shift_age must be 1: the cap only bounds disk if exactly one rotated file is kept"
  end

  # MUTATION CONTROL. Identical to the first case except the engine's cap is
  # switched off — so what remains is Rails' own 100 MB default. If this rotates,
  # the assertions above are measuring Rails, not this engine.
  def test_without_the_engine_cap_a_17mb_log_does_not_rotate
    result = probe(env: "development", seed: 17 * MB, scenario: "opt_out")

    assert_equal RAILS_DEFAULT_CAP, result["cap"],
                 "opting out should leave Rails' own 100 MB default in place"
    refute result["rotated"],
           "control failed: a 17 MB log rotated WITHOUT the engine cap, so the rotation " \
           "assertions above prove nothing about this engine"
  end

  def test_a_host_can_choose_its_own_cap
    result = probe(env: "development", seed: 3 * MB, scenario: "custom_size")

    assert_equal 2 * MB, result["cap"], "Studio.local_log_max_bytes should win over the engine default"
    assert result["rotated"], "a 3 MB log must rotate under a host-chosen 2 MB cap"
  end

  def test_a_host_chosen_logger_is_never_clobbered
    result = probe(env: "development", seed: 17 * MB, scenario: "host_logger")

    assert_equal "host-chosen.log", result["log_basename"],
                 "the engine must not replace a logger the host named itself"
    assert_equal 0, result["shift_age"],
                 "the host built its logger without rotation (shift_age 0); leave it that way"
    refute result["rotated"],
           "the engine must not have re-pointed logging at development.log"
    assert_operator result["host_log_bytes"].to_i, :>, 0,
                    "the host's own logger should be the one receiving writes"
  end

  # Production is the environment that was never broken: every production.rb in
  # the ecosystem hands its stream to STDOUT for the platform to take.
  def test_production_logging_is_left_entirely_alone
    result = probe(env: "production", seed: 0, scenario: "stdout_host")

    assert_nil result["config_log_file_size"],
               "the engine must not set a file cap in production"
    assert_nil result["log_basename"],
               "production must still log to the STDOUT stream, not to a file"
    refute result["env_log_exists"], "no log/production.log should have been created"
  end

  private

  def probe(env:, seed:, scenario: "default")
    Dir.mktmpdir("studio-log-probe") do |root|
      result_path = File.join(root, "result.json")
      env_vars = {
        "RAILS_ENV" => env,
        "PROBE_ROOT" => root,
        "PROBE_SCENARIO" => scenario,
        "PROBE_SEED" => seed.to_s,
        "PROBE_RESULT" => result_path
      }

      out = IO.popen(env_vars, [RbConfig.ruby, "-I#{File.join(ENGINE_ROOT, 'lib')}", PROBE], err: [:child, :out], &:read)
      assert $?.success?, "probe boot failed (#{scenario}/#{env}):\n#{out}"
      assert File.exist?(result_path), "probe wrote no result (#{scenario}/#{env}):\n#{out}"

      JSON.parse(File.read(result_path))
    end
  end
end
