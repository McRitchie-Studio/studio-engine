# frozen_string_literal: true

# Guard: every engine migration passes the lint a HOST runs on it.
#
# WHY THIS FILE EXISTS. A host installs the engine's migrations by copying
# db/migrate/*.rb into its own db/migrate as *.studio_engine.rb. From then on
# the file is the host's code, and the host's RuboCop lints it. moms-app runs
# rubocop-rails-omakase, which wants `[ "a" ]`, not `["a"]`; the copied
# 20261108160000_require_slugs_on_engine_tables migration turned its release
# static check red (release rel-20261109-900044, fixed in the host by hand).
# The engine has no RuboCop config of its own, so nothing here could see it.
#
# This runs RuboCop in-process with the omakase config, unmodified, over
# db/migrate ONLY. The rest of the engine keeps its own style; a migration is
# the one engine file a host lints as its own.
#
# The second test is the control: the same check over a lint-red migration
# must report the offense, so a broken config or an empty glob cannot pass
# vacuously.
#
# Run directly:
#   ruby -Itest test/lib/migrations_host_lint_test.rb
#
# One tier (library shape):
#   [unit] RuboCop omakase over db/migrate reports no offense.

# bundler/setup FIRST: the engine's suite guard refuses a test file that
# reaches minitest before the bundle is set up.
require "bundler/setup"
require "minitest/autorun"
require "rubocop"
require "stringio"
require "tmpdir"

class MigrationsHostLintTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  MIGRATIONS = File.join(ROOT, "db/migrate")
  # The host's own .rubocop.yml (moms-app's generated file), plus the Ruby a
  # host parses with. A host reads its TargetRubyVersion from its own
  # .ruby-version; the config here sits in a temp dir with none, and RuboCop
  # would fall back to a 2.7 parser that cannot read endless methods. Hosts
  # and the engine run the same Ruby, so the running one stands in.
  HOST_CONFIG = <<~YAML
    inherit_gem: { rubocop-rails-omakase: rubocop.yml }
    AllCops:
      TargetRubyVersion: #{RUBY_VERSION[/\A\d+\.\d+/]}
  YAML

  def test_every_engine_migration_passes_the_hosts_omakase_lint
    files = Dir.glob(File.join(MIGRATIONS, "*.rb"))
    refute_empty files, "db/migrate has no migrations; the glob is broken"

    status, report = lint(files)

    assert_equal 0, status,
      "An engine migration fails rubocop-rails-omakase. Hosts copy it as " \
      "*.studio_engine.rb and lint it as their own, so this turns a host's " \
      "release red. Fix it here (bundle exec rubocop -a with the omakase " \
      "config, whitespace only):\n#{report}"
  end

  def test_the_check_reports_a_lint_red_migration
    Dir.mktmpdir do |dir|
      path = File.join(dir, "20990101000000_lint_red.rb")
      File.write(path, <<~RUBY)
        class LintRed < ActiveRecord::Migration[7.2]
          def change
            add_index :studio_links, [:kind, :slug]
          end
        end
      RUBY

      status, report = lint([ path ])

      refute_equal 0, status, "the check passed a lint-red migration:\n#{report}"
      assert_includes report, "Layout/SpaceInsideArrayLiteralBrackets"
    end
  end

  private

  def lint(files)
    Dir.mktmpdir do |dir|
      config = File.join(dir, ".rubocop.yml")
      File.write(config, HOST_CONFIG)
      out = StringIO.new
      $stdout, saved = out, $stdout
      begin
        status = RuboCop::CLI.new.run(
          [ "--config", config, "--cache", "false", "--format", "simple", "--force-exclusion", *files ]
        )
      ensure
        $stdout = saved
      end
      [ status, out.string ]
    end
  end
end
