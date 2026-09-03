# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../lib/studio/s3"

# [unit] Studio::S3 picks its bucket from the SAME signal Active Storage does.
#
# THE DEFECT THIS PINS. `environment` read only `Rails.env.production?`. No QA app
# sets RAILS_ENV, so every QA app boots as production and Studio::S3 handed the
# DEV key the PRODUCTION bucket. Meanwhile config/storage.yml in the consumer keys
# Active Storage off Studio.qa_environment?, so the two writers disagreed.
#
# MEASURED on a live mcritchie-industries-qa dyno, 2026-09-02:
#   rails_env=production  qa_flag=true
#   active_storage_bucket=mcritchie-industries-dev        <- correct
#   studio_s3_bucket=mcritchie-industries-production      <- wrong
#   write=REFUSED: Aws::S3::Errors::AccessDenied
#
# The refusal is not caught: knowledge_docs_controller rescues only NotConfigured
# and MissingTable, and /admin/knowledge is the confidential data room. It also let
# QA LIST 61 objects out of the production bucket — an app whose safety profile is
# `auth-gated-confidential-deal-data`.
#
# RAILS IS NOT DEFINED in the engine's unit env, so the production branch is
# unreachable without a stub. bin/release-check runs each test file in its own
# process (`ruby -Itest <file>`), so defining Rails here cannot leak into a sibling.
module Rails
  class << self
    attr_accessor :env
  end

  FakeEnv = Struct.new(:name) do
    def production? = name == "production"
  end
end

class S3QaEnvironmentTest < Minitest::Test
  def setup
    @previous_prefix = Studio.s3_bucket_prefix
    @previous_qa = ENV["QA_ENV"]
    Studio.s3_bucket_prefix = "mcritchie-industries"
    Rails.env = Rails::FakeEnv.new("production")
  end

  def teardown
    Studio.s3_bucket_prefix = @previous_prefix
    @previous_qa.nil? ? ENV.delete("QA_ENV") : ENV["QA_ENV"] = @previous_qa
    Rails.env = nil
  end

  # THE FIX. A QA app runs Rails in production mode by design; QA_ENV is the only
  # thing separating it from real production, and it is the signal Active Storage
  # and the environment banner already read.
  def test_a_qa_app_running_rails_production_resolves_the_dev_bucket
    ENV["QA_ENV"] = "true"

    assert_equal "mcritchie-industries-dev", Studio::S3.bucket,
                 "a QA app holds the DEV key; handing it the production bucket is an " \
                 "AccessDenied on every write and a LIST of production's confidential objects"
  end

  # The guard that matters most: real production must be untouched. Getting this
  # wrong would point production at the dev bucket, which is far worse than the bug.
  def test_real_production_still_resolves_the_production_bucket
    ENV.delete("QA_ENV")

    assert_equal "mcritchie-industries-production", Studio::S3.bucket,
                 "with no QA marker this is real production and must be unchanged"
  end

  # QA_ENV present but FALSY is production. EnvironmentBanner.truthy? owns that
  # reading, and this asserts S3 defers to it rather than testing mere presence.
  def test_a_falsy_qa_marker_is_production_not_qa
    ENV["QA_ENV"] = "false"

    assert_equal "mcritchie-industries-production", Studio::S3.bucket,
                 "presence is not truth — `QA_ENV=false` must read as production"
  end

  # Non-production Rails (a developer's machine) was already dev and stays dev,
  # with or without the marker.
  def test_a_non_production_rails_env_is_dev_either_way
    Rails.env = Rails::FakeEnv.new("development")

    ENV.delete("QA_ENV")
    assert_equal "mcritchie-industries-dev", Studio::S3.bucket
    ENV["QA_ENV"] = "true"
    assert_equal "mcritchie-industries-dev", Studio::S3.bucket
  end
end
