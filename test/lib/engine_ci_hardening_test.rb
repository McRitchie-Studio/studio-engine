# frozen_string_literal: true

# Guard for engine-ci.yml's CREDENTIAL HYGIENE: the same settings consumer-ci.yml carries
# (test/lib/consumer_ci_hardening_test.rb), held to that workflow so the two cannot drift.
#
# WHY. engine-ci runs bin/release-check, npm ci and Playwright on the same runner as its
# checkout. Without `persist-credentials: false` the checkout leaves GITHUB_TOKEN in
# .git/config for every later step, including third-party code in the npm and gem trees;
# without a top-level `permissions:` block that token carries the repository default.
# No step here talks to GitHub with git: artifacts ride the runner's own runtime token.
#
# Run directly:
#   ruby -Itest test/lib/engine_ci_hardening_test.rb
#
# One tier here (backend shape):
#   [unit] the invariants, read from both real workflow files.
# The [integration] tier is the PR's own Engine CI run: a checkout or an artifact step
# that needed the dropped credential fails there.

require "bundler/setup"
require "minitest/autorun"
require "yaml"

class EngineCiHardeningTest < Minitest::Test
  ROOT        = File.expand_path("../..", __dir__)
  ENGINE_CI   = File.join(ROOT, ".github/workflows/engine-ci.yml")
  CONSUMER_CI = File.join(ROOT, ".github/workflows/consumer-ci.yml")

  def load(path) = YAML.safe_load_file(path, aliases: true)
  def engine = @engine ||= load(ENGINE_CI)
  def consumer = @consumer ||= load(CONSUMER_CI)

  def checkouts(workflow)
    workflow.fetch("jobs").flat_map do |name, job|
      job.fetch("steps").select { |s| s["uses"].to_s.start_with?("actions/checkout@") }.map { |s| [name, s] }
    end
  end

  def test_unit_engine_ci_declares_the_consumer_workflow_token_permissions
    refute_nil consumer["permissions"], "consumer-ci.yml lost its top-level permissions; this guard holds engine-ci to it"
    assert_equal consumer["permissions"], engine["permissions"],
                 "engine-ci.yml's top-level permissions must match consumer-ci.yml's (contents: read)"
    assert_equal({ "contents" => "read" }, engine["permissions"])
  end

  def test_unit_no_engine_ci_job_widens_the_token
    engine.fetch("jobs").each do |name, job|
      assert_nil job["permissions"], "#{name} declares its own permissions; no engine-ci job writes to GitHub"
    end
  end

  def test_unit_every_engine_ci_checkout_drops_its_credentials
    list = checkouts(engine)
    assert_equal engine.fetch("jobs").length, list.length, "every engine-ci job checks the engine out once"
    list.each do |job, step|
      assert_equal false, step.dig("with", "persist-credentials"),
                   "#{job}: '#{step['name']}' leaves its token in .git/config for every later step"
    end
  end

  def test_unit_both_workflows_set_the_same_credential_setting_on_every_checkout
    settings = (checkouts(engine) + checkouts(consumer)).map { |_, s| s.dig("with", "persist-credentials") }.uniq
    assert_equal [false], settings, "one credential setting across both workflows"
  end
end
