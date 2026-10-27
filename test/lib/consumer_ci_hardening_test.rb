# frozen_string_literal: true

# Guard for consumer-ci.yml's CREDENTIAL HYGIENE: what each job's tokens can do, and
# where they live after the step that used them.
#
# WHY. The consumer jobs clone five private repos and then run each one's entire test
# suite, bundle install and npm ci on the same runner. Before this guard:
#
#   · every actions/checkout left its token in the clone's .git/config, readable by any
#     later step, including third-party code in the consumers' dependency trees;
#   · the GitHub App token was minted for the whole McRitchie-Studio installation with
#     the app's full permission set, so a leaked consumer-tests token could write to
#     every repo the app can reach;
#   · the workflow declared no `permissions:`, so GITHUB_TOKEN carried the repository
#     default.
#
# Each is a one-line YAML property that a later edit can drop without any test going
# red, so this file reads the shipped workflow and pins all three.
#
# Run directly:
#   ruby -Itest test/lib/consumer_ci_hardening_test.rb
#
# One tier here (backend shape):
#   [unit] the invariants, read from the real workflow file.
# The [integration] tier is the PR's own consumer-ci run: a token scoped too tightly
# fails its checkout there.

require "bundler/setup"
require "minitest/autorun"
require "yaml"

class ConsumerCiHardeningTest < Minitest::Test
  ROOT     = File.expand_path("../..", __dir__)
  WORKFLOW = File.join(ROOT, ".github/workflows/consumer-ci.yml")

  def workflow = @workflow ||= YAML.safe_load_file(WORKFLOW, aliases: true)
  def jobs = workflow.fetch("jobs")

  def steps_using(action)
    jobs.flat_map do |name, job|
      job.fetch("steps").select { |s| s["uses"].to_s.start_with?("#{action}@") }.map { |s| [name, s] }
    end
  end

  def test_unit_the_workflow_token_is_read_only_contents
    assert_equal({ "contents" => "read" }, workflow["permissions"],
                 "top-level permissions: contents: read, so GITHUB_TOKEN cannot write anywhere")
  end

  def test_unit_no_job_widens_the_workflow_token_to_write
    jobs.each do |name, job|
      next unless job.key?("permissions")

      perms = job["permissions"]
      refute_equal "write-all", perms, "#{name} widens to write-all"
      next unless perms.is_a?(Hash)

      writes = perms.select { |_k, v| v == "write" }.keys
      assert_empty writes, "#{name} widens #{writes.join(', ')} to write; no consumer job writes to GitHub"
    end
  end

  def test_unit_every_checkout_drops_its_credentials
    checkouts = steps_using("actions/checkout")
    assert_operator checkouts.length, :>=, 5, "the consumer jobs check out the engine and the consumers"
    checkouts.each do |job, step|
      assert_equal false, step.dig("with", "persist-credentials"),
                   "#{job}: '#{step['name']}' leaves its token in .git/config for every later step"
    end
  end

  def test_unit_every_app_token_is_read_only
    mints = steps_using("actions/create-github-app-token")
    assert_equal jobs.keys.sort, %w[consumer-refs consumer-tests hub-browser hub-executed-set],
                 "a new job: decide its token scope and extend this guard"
    assert_equal 4, mints.length
    mints.each do |job, step|
      with = step.fetch("with")
      perms = with.select { |k, _| k.start_with?("permission-") }
      assert_equal({ "permission-contents" => "read", "permission-metadata" => "read" }, perms,
                   "#{job}: without permission-* inputs the token carries the app's FULL permission set")
    end
  end

  def mint(job) = steps_using("actions/create-github-app-token").find { |j, _| j == job }.last.fetch("with")
  def repos(job) = mint(job).fetch("repositories").to_s.split(/[,\n]/).map(&:strip).reject(&:empty?)

  def test_unit_each_token_reaches_only_the_repos_its_job_reads
    resolve = jobs.dig("consumer-refs", "steps").find { |s| s["id"] == "consumer-ref" }
    assert_equal resolve.dig("env", "CONSUMER_REPOS").split.sort, repos("consumer-refs").sort,
                 "consumer-refs resolves CONSUMER_REPOS, and its token reaches exactly those"
    assert_equal ["${{ matrix.repo }}"], repos("consumer-tests"),
                 "a consumer-tests cell clones one consumer; its token reaches that one"
    assert_equal ["mcritchie-studio"], repos("hub-executed-set")
    assert_equal ["mcritchie-studio"], repos("hub-browser")
  end

  def test_unit_every_private_checkout_uses_the_scoped_token
    steps_using("actions/checkout").each do |job, step|
      next unless step.dig("with", "repository")

      assert_equal "${{ steps.app-token.outputs.token }}", step.dig("with", "token"),
                   "#{job}: '#{step['name']}' must use this job's scoped app token"
    end
  end
end
