# frozen_string_literal: true

# Guard: every apt install in CI fails a stalled connection fast, retries, and
# reads its .debs from a cache.
#
# WHY. On 2026-10-26 consumer-ci run 40380540695 (release 0.114.2) failed six
# reruns at "Install system packages" on mcritchie_studio shard 4/4: apt-get
# update answered, then the ~41 MB download stalled mid-transfer, `timeout 240`
# killed it twice, and the job exited 1 with no test reached. It blocked a
# production release. A step bound alone turns a hang into a red; these options
# turn it into a retry, and the cache keeps a warm run off the mirror entirely.
#
# Asserted over every workflow file and every step that runs `apt-get install`,
# so a step added tomorrow is enrolled without anyone remembering to.
require "bundler/setup"
require "minitest/autorun"
require "yaml"

class CiAptInstallHardeningTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  REQUIRED_OPTIONS = %w[
    Acquire::Retries=
    Acquire::http::Timeout=
    Acquire::https::Timeout=
  ].freeze

  def apt_jobs
    Dir[File.join(ROOT, ".github/workflows/*.yml")].sort.flat_map do |path|
      jobs = (YAML.load_file(path, aliases: true) || {})["jobs"] || {}
      jobs.filter_map do |name, job|
        next unless job.is_a?(Hash)

        steps = Array(job["steps"]).select { |s| s.is_a?(Hash) }
        installs = steps.select { |s| s["run"].to_s.match?(/apt-get\b[^\n]*\binstall\b/) }
        next if installs.empty?

        { where: "#{File.basename(path)} :: #{name}", steps: steps, installs: installs }
      end
    end
  end

  def test_the_guard_sees_the_consumer_install
    assert apt_jobs.any? { |j| j[:where].start_with?("consumer-ci.yml") },
           "no apt-get install found in consumer-ci.yml — the guard is looking in the wrong place"
  end

  def test_every_install_fails_a_stall_fast_and_retries
    offenders = apt_jobs.flat_map do |job|
      job[:installs].flat_map do |step|
        run = step["run"].to_s
        missing = REQUIRED_OPTIONS.reject { |opt| run.include?(opt) }
        missing << "timeout -k" unless run.match?(/timeout\s+-k\s+\d+/)
        missing << "3 attempts" unless run.match?(/for attempt in 1 2 3\b/)
        missing.empty? ? [] : ["#{job[:where]} :: #{step['name']} lacks #{missing.join(', ')}"]
      end
    end

    assert_empty offenders,
                 "a stalled Ubuntu mirror hangs these installs until the outer timeout kills them, " \
                 "instead of apt dropping the dead socket in 30s and re-fetching:\n  " + offenders.join("\n  ")
  end

  def test_every_install_reads_a_deb_cache
    offenders = apt_jobs.reject do |job|
      cache = job[:steps].index { |s| s["uses"].to_s.start_with?("actions/cache") && s.dig("with", "path").to_s.include?("apt-archives") }
      first_install = job[:steps].index(job[:installs].first)
      cache && cache < first_install && job[:installs].all? { |s| s["run"].include?("Dir::Cache::Archives") }
    end

    assert_empty offenders.map { |j| j[:where] },
                 "these jobs install apt packages without restoring the ~/apt-archives cache first " \
                 "(and pointing Dir::Cache::Archives at it), so every run re-downloads from the mirror"
  end
end
