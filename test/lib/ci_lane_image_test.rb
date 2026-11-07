# frozen_string_literal: true

# Guard: NO CI STEP FETCHES FROM AN APT MIRROR. The jobs that need system packages
# (consumer-tests, hub-browser, the engine's playwright lane) run inside the hub's
# lane image, ghcr.io/mcritchie-studio/ci-rails, built weekly by the hub's
# mirror-ci-images.yml from its .github/ci-image/Dockerfile with every package
# pre-installed.
#
# WHY. The apt mirror stalling in "Install system packages" was this repo's top
# red-then-green cause: 35 job-steps in two weeks (refactor-review-2026-11-06,
# lane-health 2f). The cache, inline timeouts and three bounded attempts made it
# rarer, never absent, and a red a re-run turns green is a defect with a cause (Alex
# McRitchie, 2026-11-06), not something to retry. This guard replaced
# test/lib/ci_apt_install_hardening_test.rb. Task: deterministic-ci.
require "bundler/setup"
require "minitest/autorun"
require "yaml"

class CiLaneImageTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  WORKFLOWS = Dir[File.join(ROOT, ".github/workflows/*.yml")].sort
  IMAGE = "ghcr.io/mcritchie-studio/ci-rails:24.04"
  IMAGE_JOBS = { "consumer-ci.yml" => %w[consumer-tests hub-browser], "engine-ci.yml" => %w[playwright] }.freeze

  def self.apt_fetch?(run)
    r = run.to_s.gsub(/\\\n\s*/, " ")
    r.include?("--with-deps") || r.match?(/\bapt(?:-get)?\b[^\n]*\b(?:install|update|upgrade|dist-upgrade)\b/)
  end

  def load(name) = YAML.safe_load_file(File.join(ROOT, ".github/workflows", name), aliases: true)

  def test_no_workflow_step_fetches_from_apt
    refute_empty WORKFLOWS
    offenders = WORKFLOWS.flat_map do |path|
      (YAML.safe_load_file(path, aliases: true)["jobs"] || {}).flat_map do |name, job|
        Array(job["steps"]).select { |s| self.class.apt_fetch?(s["run"]) }.map { |s| "#{File.basename(path)} #{name}: #{s['name']}" }
      end
    end
    assert_empty offenders, "these steps fetch from an apt mirror; the package belongs in the hub's lane image"
  end

  def test_the_package_jobs_run_in_the_lane_image_with_the_run_token
    IMAGE_JOBS.each do |file, names|
      doc = load(file)
      assert_equal "read", doc.dig("permissions", "packages"), "#{file} must let the token read ghcr.io"
      names.each do |name|
        container = doc.dig("jobs", name, "container") || flunk("#{file} #{name} runs on the bare runner")
        assert_equal IMAGE, container["image"]
        assert_equal "${{ github.token }}", container.dig("credentials", "password")
        assert_includes container["options"].to_s, "--init", "#{name} needs a PID 1 that reaps killed children"
      end
    end
  end

  # Inside a container the services answer by their labels, and `github.workspace`
  # names the HOST path, which the container cannot see.
  def test_container_jobs_reach_services_by_label_and_use_relative_paths
    IMAGE_JOBS.each_key do |file|
      text = File.read(File.join(ROOT, ".github/workflows", file))
      refute_match(/@localhost:5432|redis:\/\/localhost/, text, file)
      refute_includes text, "github.workspace", file
    end
  end

  def test_the_classifier_sees_each_apt_spelling
    assert self.class.apt_fetch?("sudo timeout 120 apt-get update")
    assert self.class.apt_fetch?("npx playwright install --with-deps chromium")
    refute self.class.apt_fetch?("npx playwright install chromium")
  end
end
