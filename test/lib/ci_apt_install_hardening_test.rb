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
# Asserted over every workflow file and every step that can FETCH from apt: a
# direct `apt-get`/`apt` install or update (continuation lines joined first, so a
# multi-line invocation counts) and `playwright install --with-deps`, which runs
# its own apt-get underneath. A step added tomorrow is enrolled without anyone
# remembering to. Review of 2026-10-26 showed the first cut of this guard stayed
# green on all three of those shapes; FETCH below is the fix.
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

  # The same three settings as apt.conf lines, for a machine-wide hardening step
  # (`Acquire::Retries "5";` in /etc/apt/apt.conf.d/) that covers a fetch whose
  # apt-get the workflow does not spell out itself, such as `--with-deps`.
  CONF_KEYS = %w[Acquire::Retries Acquire::http::Timeout Acquire::https::Timeout].freeze

  def self.joined(run)
    run.to_s.gsub(/\\\n\s*/, " ")
  end

  def self.fetch?(run)
    r = joined(run)
    r.match?(/\bapt(?:-get)?\b[^\n]*\b(?:install|update|upgrade|dist-upgrade)\b/) || r.include?("--with-deps")
  end

  def self.conf_hardening?(run)
    r = run.to_s
    r.include?("/etc/apt/apt.conf.d/") && CONF_KEYS.all? { |k| r.include?(k) }
  end

  def apt_jobs
    Dir[File.join(ROOT, ".github/workflows/*.yml")].sort.flat_map do |path|
      jobs = (YAML.load_file(path, aliases: true) || {})["jobs"] || {}
      jobs.filter_map do |name, job|
        next unless job.is_a?(Hash)

        steps = Array(job["steps"]).select { |s| s.is_a?(Hash) }
        fetches = steps.select { |s| self.class.fetch?(s["run"]) }
        next if fetches.empty?

        # The hand-rolled loops: a direct apt-get install, not a tool's --with-deps.
        installs = fetches.reject { |s| self.class.joined(s["run"]).include?("--with-deps") }
        { where: "#{File.basename(path)} :: #{name}", steps: steps, fetches: fetches, installs: installs }
      end
    end
  end

  def test_the_guard_sees_the_consumer_install
    assert apt_jobs.any? { |j| j[:where].start_with?("consumer-ci.yml") && j[:installs].any? },
           "no apt-get install found in consumer-ci.yml — the guard is looking in the wrong place"
    assert apt_jobs.any? { |j| j[:where].start_with?("engine-ci.yml") && j[:fetches].any? { |s| s["run"].include?("--with-deps") } },
           "no `--with-deps` fetch found in engine-ci.yml — the guard is looking in the wrong place"
  end

  def test_the_fetch_matcher_sees_every_shape
    assert self.class.fetch?("sudo apt-get \\\n  install -y ffmpeg"), "multi-line apt-get install"
    assert self.class.fetch?("sudo apt install -y ffmpeg"), "`apt install`"
    assert self.class.fetch?("npx playwright install --with-deps chromium"), "--with-deps"
    refute self.class.fetch?("sudo apt-get autoclean"), "autoclean fetches nothing"
  end

  def test_every_fetch_is_hardened_and_bounded
    offenders = apt_jobs.flat_map do |job|
      job[:fetches].filter_map do |step|
        at = job[:steps].index(step)
        inline = REQUIRED_OPTIONS.all? { |opt| step["run"].to_s.include?(opt) }
        machine = job[:steps][0...at].any? { |s| self.class.conf_hardening?(s["run"]) }
        missing = []
        missing << "Acquire retry/timeout options (inline, or an earlier apt.conf.d step)" unless inline || machine
        missing << "a step timeout-minutes" unless step["timeout-minutes"]
        "#{job[:where]} :: #{step['name']} lacks #{missing.join(' and ')}" unless missing.empty?
      end
    end

    assert_empty offenders,
                 "these apt fetches hang on a stalled mirror until the 45-minute job bound kills " \
                 "them, unretried:\n  " + offenders.join("\n  ")
  end

  def test_every_hand_rolled_install_bounds_and_retries_its_attempts
    offenders = apt_jobs.flat_map do |job|
      job[:installs].flat_map do |step|
        run = step["run"].to_s
        missing = []
        missing << "timeout -k" unless run.match?(/timeout\s+-k\s+\d+/)
        missing << "3 attempts" unless run.match?(/for attempt in 1 2 3\b/)
        missing.empty? ? [] : ["#{job[:where]} :: #{step['name']} lacks #{missing.join(', ')}"]
      end
    end

    assert_empty offenders,
                 "these hand-rolled apt loops lose their per-attempt bound or their retries:\n  " +
                 offenders.join("\n  ")
  end

  def test_every_install_reads_a_deb_cache
    offenders = apt_jobs.select { |j| j[:installs].any? }.reject do |job|
      cache = job[:steps].index { |s| s["uses"].to_s.start_with?("actions/cache") && s.dig("with", "path").to_s.include?("apt-archives") }
      first_install = job[:steps].index(job[:installs].first)
      cache && cache < first_install && job[:installs].all? { |s| s["run"].include?("Dir::Cache::Archives") }
    end

    assert_empty offenders.map { |j| j[:where] },
                 "these jobs install apt packages without restoring the ~/apt-archives cache first " \
                 "(and pointing Dir::Cache::Archives at it), so every run re-downloads from the mirror"
  end

  def test_a_failed_install_still_saves_its_progress
    # A crawling mirror (2026-10-26: ~40 KB/s, 71 -> 41 MB left after three
    # attempts) never trips the inactivity timeout. actions/cache saves only on
    # success, so without an always() save a rerun starts from zero every time.
    offenders = apt_jobs.select { |j| j[:installs].any? }.reject do |job|
      install = job[:steps].index(job[:installs].last)
      save = job[:steps].index do |s|
        s["uses"].to_s.start_with?("actions/cache/save") && s["if"].to_s.include?("always()") &&
          s.dig("with", "path").to_s.include?("apt-archives")
      end
      save && save > install
    end

    assert_empty offenders.map { |j| j[:where] },
                 "these jobs lose a failed install's downloaded .debs: add an actions/cache/save step " \
                 "with `if: always()` after the install, keyed apart from the complete set"
  end
end
