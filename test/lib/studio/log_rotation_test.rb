# frozen_string_literal: true

require_relative "../../test_helper"

# UNIT tier for the local-log-cap decision. Fast, one branch at a time, no Rails.
#
# This half answers "what cap, if any". The other half — running EARLY enough in
# the boot for the answer to reach the logger at all — cannot be asserted here
# and is covered by test/integration/log_rotation_test.rb, which boots real Rails
# apps and watches the file rotate on disk. Neither tier substitutes for the
# other: this one would stay green with the initializer wired at the wrong point
# in the chain, which is precisely the way this change can fail.
class LogRotationTest < Minitest::Test
  MB = 1024 * 1024

  def test_development_gets_the_development_cap
    assert_equal 16 * MB, Studio::LogRotation.cap_for(env: "development")
  end

  def test_test_gets_the_smaller_test_cap
    assert_equal 8 * MB, Studio::LogRotation.cap_for(env: "test")
  end

  def test_production_is_left_alone
    assert_nil Studio::LogRotation.cap_for(env: "production"),
               "production hands its stream to the platform; never point it at a file"
  end

  def test_an_unknown_environment_is_left_alone
    assert_nil Studio::LogRotation.cap_for(env: "staging"),
               "only the environments we know to be plain local files get a cap"
  end

  def test_a_symbol_or_environment_inquirer_works_like_a_string
    assert_equal 8 * MB, Studio::LogRotation.cap_for(env: :test)
  end

  def test_a_host_that_named_its_own_logger_is_never_overridden
    assert_nil Studio::LogRotation.cap_for(env: "development", host_logger: Object.new)
  end

  def test_false_opts_out_entirely
    assert_nil Studio::LogRotation.cap_for(env: "development", override: false),
               "false must mean 'leave Rails' own default in place', not 'use ours'"
  end

  def test_an_integer_override_wins_over_the_default
    assert_equal 2 * MB, Studio::LogRotation.cap_for(env: "development", override: 2 * MB)
    assert_equal 2 * MB, Studio::LogRotation.cap_for(env: "test", override: 2 * MB),
                 "a host-chosen cap should apply in every capped environment"
  end

  def test_nil_override_falls_back_to_the_engine_default
    assert_equal 16 * MB, Studio::LogRotation.cap_for(env: "development", override: nil)
  end

  # The caps only bound disk if they are well under what Rails would do on its
  # own; a cap at or above Rails' default would be decoration.
  def test_both_caps_sit_below_rails_own_100mb_default
    rails_default = 100 * MB
    assert_operator Studio::LogRotation::DEVELOPMENT_MAX_BYTES, :<, rails_default
    assert_operator Studio::LogRotation::TEST_MAX_BYTES, :<, Studio::LogRotation::DEVELOPMENT_MAX_BYTES
  end
end
