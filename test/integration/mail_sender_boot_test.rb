# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "rbconfig"

# [integration] The production placeholder-sender guard, against a BOOTED host.
# voicebox and moms-app shipped the Rails scaffold's
# `default from: "from@example.com"`, whose ApplicationMailer shadows the
# engine's, and Resend refused every magic link. Each case boots
# test/support/mail_sender_boot_probe.rb in its own process with the case's own
# config/initializers/studio.rb and, when it has one, its own
# app/mailers/application_mailer.rb, and reads back what the app got:
#   - production with the scaffold shadow, or with RESEND_MAILER_FROM on
#     example.com, REFUSES THE BOOT naming the fix;
#   - production with the shadow re-pointed at Studio.mailer_from boots;
#   - with no RESEND_MAILER_FROM and no resend_from:, the app sends as
#     "<app_name> <team@mcritchie.studio>", ses_from: or not;
#   - outside production the guard stands aside.
class MailSenderBootTest < Minitest::Test
  PROBE = File.expand_path("../support/mail_sender_boot_probe.rb", __dir__)
  ENGINE_ROOT = File.expand_path("../..", __dir__)

  SCAFFOLD_MAILER = <<~RUBY
    class ApplicationMailer < ActionMailer::Base
      default from: "from@example.com"
      layout "mailer"
    end
  RUBY

  FIXED_MAILER = <<~RUBY
    class ApplicationMailer < ActionMailer::Base
      default from: -> { Studio.mailer_from.presence || "Probe App <team@mcritchie.studio>" }
      layout "mailer"
    end
  RUBY

  # The initializer every consumer that still passes the retired keyword has.
  SES_FROM_INITIALIZER = <<~RUBY
    config.app_name = "Probe App"
    config.mailer_from = Studio.mailer_from_for_transport(ses_from: "Old SES <team@retired.example>")
  RUBY

  CLEARED = %w[RESEND_MAILER_FROM RESEND_MARKETING_FROM MAILER_FROM RESEND_API_KEY MAIL_TRANSPORT
               DATABASE_URL SECRET_KEY_BASE_DUMMY AGENT_WORKTREE LOCAL_EMAIL_CAPTURE].to_h { |name| [name, nil] }

  def probe(env: "production", vars: {}, studio: SES_FROM_INITIALIZER, mailer: nil)
    Dir.mktmpdir("studio-mail-sender-probe") do |root|
      FileUtils.mkdir_p(File.join(root, "config/initializers"))
      # host_schema_check off: the probe's in-memory database has no tables.
      File.write(File.join(root, "config/initializers/studio.rb"),
                 "Studio.configure do |config|\n  config.host_schema_check = false\n  #{studio}\nend\n")
      if mailer
        FileUtils.mkdir_p(File.join(root, "app/mailers"))
        File.write(File.join(root, "app/mailers/application_mailer.rb"), mailer)
      end
      result = File.join(root, "result.json")
      process_env = CLEARED.merge(vars).merge(
        "RAILS_ENV" => env, "PROBE_ROOT" => root, "PROBE_RESULT" => result,
        "BUNDLE_GEMFILE" => File.join(ENGINE_ROOT, "Gemfile")
      )
      output = IO.popen(process_env, [RbConfig.ruby, PROBE], err: %i[child out], &:read)
      assert $?.success?, "the #{env} probe crashed:\n#{output}"
      assert File.exist?(result), "the #{env} probe wrote no result:\n#{output}"
      JSON.parse(File.read(result))
    end
  end

  def assert_booted(result)
    assert result["booted"], "boot refused: #{result['error_class']}: #{result['error']}"
  end

  def assert_refused(result)
    refute result["booted"], "the production boot should have been refused, got #{result.inspect}"
    assert_equal "Studio::MailSender::PlaceholderSenderError", result["error_class"]
  end

  def test_production_refuses_the_scaffold_shadow
    result = probe(mailer: SCAFFOLD_MAILER)

    assert_refused(result)
    assert_includes result["error"], "ApplicationMailer sends from \"from@example.com\""
    assert_includes result["error"], "app/mailers/application_mailer.rb"
    assert_includes result["error"], "Probe App <team@mcritchie.studio>", "the refusal names the sender to use"
  end

  def test_production_refuses_an_example_com_resend_mailer_from
    assert_refused(probe(vars: { "RESEND_MAILER_FROM" => "Probe <hello@mail.example.org>" }))
  end

  def test_production_boots_with_the_shadow_re_pointed_at_studio_mailer_from
    result = probe(mailer: FIXED_MAILER)

    assert_booted(result)
    assert_equal "Probe App <team@mcritchie.studio>", result["application_mailer_from"]
    assert_equal "Probe App <team@mcritchie.studio>", result["user_mailer_from"], "the magic link inherits it"
  end

  def test_an_app_with_no_sender_set_sends_as_itself_from_team
    result = probe

    assert_booted(result)
    assert_equal "Probe App <team@mcritchie.studio>", result["mailer_from"], "ses_from: is ignored"
    assert_equal "Probe App <team@mcritchie.studio>", result["application_mailer_from"]
    assert_equal "Probe App <team@mcritchie.studio>", result["user_mailer_from"]
  end

  def test_resend_mailer_from_still_wins_over_the_default
    result = probe(vars: { "RESEND_MAILER_FROM" => "Client <hello@client-domain.test>" })

    assert_booted(result)
    assert_equal "Client <hello@client-domain.test>", result["application_mailer_from"]
  end

  def test_outside_production_the_guard_stands_aside
    result = probe(env: "test", mailer: SCAFFOLD_MAILER)

    assert_booted(result)
    assert_equal "from@example.com", result["application_mailer_from"]
  end
end
