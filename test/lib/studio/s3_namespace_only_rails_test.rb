# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../lib/studio/s3"

# [unit] Studio::S3 must survive a Rails CONSTANT that is not a Rails APPLICATION.
#
# THE TRAP, measured rather than imagined. `environment` used to read
# `defined?(Rails) && Rails.env.production?`. That looks like "am I running inside
# Rails", and it is not: rails-html-sanitizer — a transitive dependency of
# action_view, which arrives long before any application does — defines a
# NAMESPACE-ONLY `module Rails` in its own version.rb. It is a bare Module with no
# singleton methods at all. Against it the guard reads TRUE and the very next call
# raises NoMethodError: undefined method `env` for module Rails.
#
# HOW IT WAS FOUND. Adding ONE require to test/test_helper.rb for a file that needs
# action_view took test/lib/studio/email_catalog_test.rb from 40 runs / 0 errors to
# 40 runs / 2 errors, both raised out of Studio::S3#environment through
# EmailCatalog#uploads_available?. Nothing about email uploads had changed. The
# whole cost of that guard was the half-hour spent looking in the wrong file.
#
# NO STUB HERE, ON PURPOSE. Every other S3 test defines `Rails.env` so it can drive
# the production branch; this one must NOT, because the absence of that accessor IS
# the condition under test. bin/release-check runs each test file in its own process
# (`ruby -Itest <file>`), so the sibling that installs the accessor cannot reach
# this one — and requiring test_helper above is what pulls action_view in, which is
# what defines the bare constant. The fixture is the real dependency graph rather
# than a hand-written double of it.
class S3NamespaceOnlyRailsTest < Minitest::Test
  def setup
    @previous_prefix = Studio.s3_bucket_prefix
    @previous_qa = ENV["QA_ENV"]
    Studio.s3_bucket_prefix = "mcritchie-industries"
    ENV.delete("QA_ENV")
  end

  def teardown
    Studio.s3_bucket_prefix = @previous_prefix
    @previous_qa.nil? ? ENV.delete("QA_ENV") : ENV["QA_ENV"] = @previous_qa
  end

  # THE PRECONDITION, asserted rather than assumed. If this ever goes false the two
  # tests below stop testing anything and would pass for the wrong reason — a guard
  # that cannot fire is the failure mode this whole file exists to catch elsewhere.
  def test_the_fixture_really_is_a_rails_constant_without_an_env
    assert defined?(Rails),
           "loading action_view's HELPERS tree should have defined a bare " \
           "`module Rails` — a bare `require \"action_view\"` does not; without it " \
           "the assertions below are inert"
    refute Rails.respond_to?(:env),
           "this file must NOT stub Rails.env — the missing accessor is the condition " \
           "under test, and a sibling's stub leaking in would hide the bug"
  end

  # DRIVEN THROUGH .bucket RATHER THAN #environment, which is private — and which is
  # also the honest route, because .bucket is the caller that actually broke:
  # EmailCatalog#uploads_available? reaches it, which is how a guard about Rails
  # surfaced as two red assertions about email images.
  def test_a_namespace_only_rails_resolves_dev_instead_of_raising
    assert_equal "mcritchie-industries-dev", Studio::S3.bucket,
                 "a Rails constant with no application behind it is not production; " \
                 "guarding on `defined?(Rails)` alone raises NoMethodError here"
  end
end
