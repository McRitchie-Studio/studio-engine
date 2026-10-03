# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "json"
require "tmpdir"
require "rbconfig"

# [integration] A FOOTER-ONLY CONSUMER boots, eager-loads, renders the footer,
# and survives the release sweep's migration install, with no ActiveRecord and
# none of the workarounds the rantly pilot needed.
#
# The app is test/support/footer_only_probe.rb, booted in its own process
# (Rails.env and the app singleton are per process, and the dummy app every
# other suite boots loads ActiveRecord). The header of that file lists what it
# does NOT do; this file proves the engine no longer needs it to:
#
#   1. Integer#minutes at require time: the engine requires its own core_ext
#   2. the user-contract check: skipped when the host loads no ActiveRecord
#   3. eager loading: the engine's ActiveRecord-dependent roots (controllers,
#      models, mailers, jobs, services and both concerns roots) are not eager
#      loaded without ActiveRecord; its helpers still are
#   4. `studio_engine:install:migrations`: a clean no-op, exit 0, nothing written
#   7. a footer with no address names no Leaflet: no map script, no map CSS
#
# The ActiveRecord half (the engine unchanged for a host WITH a database) is the
# rest of the suite: every other integration test boots test/dummy, which loads
# active_record/railtie.
class FooterOnlyConsumerTest < Minitest::Test
  ENGINE_ROOT = File.expand_path("../..", __dir__)
  PROBE = File.expand_path("../support/footer_only_probe.rb", __dir__)

  # The engine's eager-load roots that need a framework a footer-only app does
  # not load (ActiveRecord, ActionMailer, ActiveJob) or a host contract it does
  # not meet (ApplicationController's require_authentication).
  SKIPPED_ROOTS = %w[
    app/controllers app/controllers/concerns app/models app/models/concerns
    app/mailers app/jobs app/services
  ].freeze

  def test_development_boot_renders_the_footer
    result = probe(env: "development", eager: false)

    refute result["active_record_loaded"], "the probe must stay an app with no ActiveRecord"
    refute result["engine_active_record"], "Studio.active_record? must read false with no ActiveRecord railtie"
    assert_footer_rendered(result)
  end

  def test_production_like_eager_boot_renders_the_footer
    result = probe(env: "production", eager: true)

    assert result["eager_load"], "the probe was meant to boot with eager_load = true"
    refute result["active_record_loaded"],
           "eager loading pulled in ActiveRecord: #{result['loaded_engine_files'].first(5).inspect}"
    assert_footer_rendered(result)

    loaded = result["loaded_engine_files"]
    SKIPPED_ROOTS.each do |root|
      offenders = loaded.select { |path| path.start_with?("#{root}/") && SKIPPED_ROOTS.none? { |r| r != root && r.start_with?("#{root}/") && path.start_with?("#{r}/") } }
      assert_empty offenders, "#{root} was eager loaded in an app with no ActiveRecord"
    end
    helpers = loaded.select { |path| path.start_with?("app/helpers/") }
    assert_includes helpers, "app/helpers/studio/site_footer_helper.rb", "the footer helper must still eager load"
    expected_helpers = Dir.glob("app/helpers/**/*.rb", base: ENGINE_ROOT)
    assert_equal expected_helpers.sort, helpers.sort, "every engine helper must eager load without ActiveRecord"
  end

  def test_install_migrations_is_a_clean_no_op_without_active_record
    result = probe(env: "development", eager: false, action: "rake")

    assert result["task_defined"], "the release sweep runs studio_engine:install:migrations; it must exist"
    assert_equal "ok", result["invoke"], "the task raised: #{result['invoke']}"
    refute result["migrate_dir_exists"], "no db/migrate may be created in an app with no database"
    assert_empty result["files_under_root"], "the task wrote files: #{result['files_under_root'].inspect}"
    assert_match(/no ActiveRecord/i, result["output"])
  end

  # The same task, run as the release sweep runs it: `bin/rails <task>` in the
  # member's tree, read by its exit status (mcritchie-studio bin/release.rb,
  # install_engine_migrations!). Rake's own handler turns a raise into exit 1.
  def test_install_migrations_exits_zero_from_the_rake_command_line
    Dir.mktmpdir("studio-footer-only") do |root|
      rakefile = File.join(root, "Rakefile")
      File.write(rakefile, <<~RUBY)
        ENV["PROBE_ACTION"] = "none"
        ENV["PROBE_RESULT"] = File.join(#{root.inspect}, "result.json")
        ENV["PROBE_ROOT"] = #{root.inspect}
        load #{PROBE.inspect}
        Rails.application.load_tasks
      RUBY
      env = { "RAILS_ENV" => "development", "BUNDLE_GEMFILE" => File.join(ENGINE_ROOT, "Gemfile") }
      out = IO.popen(env, [RbConfig.ruby, "-I#{File.join(ENGINE_ROOT, 'lib')}", "-S", "rake", "-f", rakefile,
                           "studio_engine:install:migrations"], chdir: root, err: %i[child out], &:read)

      assert $?.success?, "rake studio_engine:install:migrations exited #{$?.exitstatus}:\n#{out}"
      refute File.exist?(File.join(root, "db", "migrate")), "no db/migrate may be created"
    end
  end

  private

  def assert_footer_rendered(result)
    assert_equal 200, result["status"], "the page did not render:\n#{result['html'].to_s[0, 2000]}"
    html = result["html"]
    assert_includes html, "data-site-footer", "the footer did not render"
    assert_includes html, "Footer Only"
    assert_includes html, "A site with no database"
    # 7. No address, so no map: the page must not name Leaflet at all, neither
    # its files nor its classes nor the mount script.
    assert_no_leaflet(html)
  end

  def assert_no_leaflet(html)
    refute_match(/leaflet/i, html, "a footer with no address must not name Leaflet")
    refute_includes html, "__studioFooterMapsArmed", "a footer with no address must not ship the map script"
    refute_includes html, ".ftr-map", "a footer with no address must not ship the map's CSS"
  end

  def probe(env:, eager:, action: "render")
    Dir.mktmpdir("studio-footer-only") do |root|
      result_path = File.join(root, "result.json")
      env_vars = {
        "RAILS_ENV" => env,
        "PROBE_ROOT" => root,
        "PROBE_EAGER" => eager ? "1" : "0",
        "PROBE_ACTION" => action,
        "PROBE_RESULT" => result_path,
        "BUNDLE_GEMFILE" => File.join(ENGINE_ROOT, "Gemfile")
      }
      out = IO.popen(env_vars, [RbConfig.ruby, "-I#{File.join(ENGINE_ROOT, 'lib')}", PROBE], err: %i[child out], &:read)

      assert $?.success?, "footer-only probe failed (#{action}/#{env}, eager=#{eager}):\n#{out}"
      assert File.exist?(result_path), "probe wrote no result:\n#{out}"
      JSON.parse(File.read(result_path))
    end
  end
end
