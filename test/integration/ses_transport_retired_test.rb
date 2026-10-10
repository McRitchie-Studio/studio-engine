# frozen_string_literal: true

require "bundler/setup"
ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"
require "minitest/autorun"
require "active_support/test_case"
require "rake"

# [integration] SES was retired with AWS on 2026-10-10, and the engine dropped
# its SES transport. Proved against the BOOTED engine, not the hand-written
# Studio mirror in test/test_helper.rb (test/lib/studio_test.rb exercises the
# mirror; a sender rule asserted only there would pass with lib/studio.rb broken).
#
#   - Every consumer initializer still passes `ses_from:` to
#     Studio.mailer_from_for_transport / marketing_from_for_transport, so the
#     keyword must stay ACCEPTED. It is IGNORED: even MAIL_TRANSPORT=ses with the
#     old SMTP pair set answers the Resend sender.
#   - MAIL_TRANSPORT=ses selects Resend when RESEND_API_KEY is set, never SMTP.
#   - The ses:* rake tasks are gone, and so is Studio.ses_transport_ready?.
class SesTransportRetiredTest < ActiveSupport::TestCase
  STALE_SES_ENV = {
    "MAIL_TRANSPORT" => "ses",
    "SES_SMTP_USERNAME" => "user",
    "SES_SMTP_PASSWORD" => "pass",
    "MAILER_FROM" => "Old SES Sender <team@example.com>",
    "MARKETING_MAILER_FROM" => "Old SES Marketing <alex@example.com>"
  }.freeze

  FakeMailer = Struct.new(:delivery_method, :smtp_settings)

  test "mailer_from_for_transport accepts ses_from and answers the Resend sender" do
    env = STALE_SES_ENV.merge("RESEND_MAILER_FROM" => "Turf Monster <team@turfmonster.media>")

    assert_equal "Turf Monster <team@turfmonster.media>",
                 Studio.mailer_from_for_transport(env: env, ses_from: "Ignored <team@example.com>")
    assert_equal "Resend Arg <team@example.com>",
                 Studio.mailer_from_for_transport(env: STALE_SES_ENV, ses_from: "Ignored <team@example.com>",
                                                  resend_from: "Resend Arg <team@example.com>")
  end

  test "marketing_from_for_transport accepts ses_from and answers the Resend sender" do
    env = STALE_SES_ENV.merge("RESEND_MARKETING_FROM" => "Alex from Turf Monster <alex@turfmonster.media>")

    assert_equal "Alex from Turf Monster <alex@turfmonster.media>",
                 Studio.marketing_from_for_transport(env: env, ses_from: "Ignored <alex@example.com>")
  end

  test "ses_from is optional now" do
    assert_equal Studio.resend_mailer_from, Studio.mailer_from_for_transport(env: {})
    assert_equal Studio.resend_mailer_from, Studio.marketing_from_for_transport(env: {})
  end

  test "MAIL_TRANSPORT=ses with the old SMTP pair configures Resend, never SMTP" do
    mailer = FakeMailer.new(:smtp, {})
    log = StringIO.new

    result = Studio::MailTransport.configure!(
      env: STALE_SES_ENV.merge("RESEND_API_KEY" => "rk_test"),
      rails_env: "production",
      action_mailer: mailer,
      logger: Logger.new(log),
      resend_loader: -> {},
      resend_configurer: ->(_key) {}
    )

    assert_equal :resend, result.transport
    assert_equal :resend, mailer.delivery_method
    assert_equal({}, mailer.smtp_settings, "no SES SMTP settings may be written")
    assert_match(/MAIL_TRANSPORT=ses is no longer supported/, log.string)
  end

  test "the SES API and rake tasks are gone" do
    refute Studio.respond_to?(:ses_transport_ready?)
    refute Studio::MailTransport.respond_to?(:configure_ses!)

    Rake.application = Rake::Application.new
    Studio::Engine.instance.load_tasks
    assert Rake::Task.task_defined?("studio:trash:list"), "the engine's tasks loaded at all"
    %w[ses:check ses:verify_domain].each do |name|
      refute Rake::Task.task_defined?(name), "#{name} is still registered"
    end
  ensure
    Rake.application = Rake::Application.new
  end
end
