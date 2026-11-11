# frozen_string_literal: true

# Dependency updates are reactive, not scheduled (Alex McRitchie's ruling,
# 2026-11-10, task ci-runs-reactive-and-once). A bump starts from the
# `dependency-update` SOP (mcritchie-studio/docs/agents/modules/dependency-update.md):
# a security advisory, a red bundler-audit, a builder who needs a newer gem, or
# drift reported at release.
#
# This repo kept ONE scheduled check longer than the rest: a daily Dependabot
# bump of solana-studio alone, with an auto-merge lane (engine-lock-automerge.yml,
# bin/lock-bump-mergeable), because bin/gem-drift-check reddens every open engine
# PR while this lock trails the released gem. Its replacement fires on each
# release instead of once a day: `bin/release ship` moves this lock to the final
# on `accepted` (mcritchie-studio bin/release.rb#bump_producer_locks_for_accepted,
# ship step 5d). So neither the config nor the lane that merged its PRs may come
# back quietly. Bringing either back is a deliberate act that deletes this test.
#
# Run directly:
#   ruby -Itest test/lib/scheduled_dependabot_off_test.rb

# bundler/setup FIRST — the engine's suite guard refuses a test file that reaches
# minitest before the bundle is set up.
require "bundler/setup"
require "minitest/autorun"

class ScheduledDependabotOffTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_unit_no_scheduled_dependabot_version_updates
    refute File.exist?(File.join(ROOT, ".github/dependabot.yml")),
           ".github/dependabot.yml is back. Each solana-studio release bumps this lock " \
           "(bin/release.rb#bump_producer_locks_for_accepted); other bumps follow the " \
           "dependency-update SOP"
  end

  def test_unit_no_lane_auto_merges_a_bot_lock_bump
    leftovers = %w[.github/workflows/engine-lock-automerge.yml bin/lock-bump-mergeable]
                .select { |path| File.exist?(File.join(ROOT, path)) }

    assert_empty leftovers, "the Dependabot auto-merge lane has nothing to merge; delete #{leftovers.inspect}"
  end
end
