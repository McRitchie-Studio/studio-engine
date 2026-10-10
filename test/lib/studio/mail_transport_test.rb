# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../lib/studio/mail_transport"

class MailTransportTest < Minitest::Test
  FakeMailer = Struct.new(:delivery_method, :smtp_settings)

  class RecordingLogger
    attr_reader :lines

    def initialize
      @lines = []
    end

    %i[info warn].each do |level|
      define_method(level) { |message| @lines << [level, message] }
    end
  end

  # SES was retired 2026-10-10. A stale MAIL_TRANSPORT=ses, even with the old
  # SMTP pair still set, selects Resend and writes no SMTP settings.
  def test_ses_value_falls_through_to_resend_and_warns
    mailer = FakeMailer.new(:smtp, {})
    logger = RecordingLogger.new
    env = {
      "MAIL_TRANSPORT" => "ses",
      "SES_REGION" => "us-east-2",
      "SES_SMTP_USERNAME" => "user",
      "SES_SMTP_PASSWORD" => "pass",
      "RESEND_API_KEY" => "rk_test"
    }

    result = Studio::MailTransport.configure!(env: env, rails_env: "development", action_mailer: mailer, logger: logger,
                                              resend_loader: -> {}, resend_configurer: ->(_key) {})

    assert_equal :resend, result.transport
    assert_equal :resend, mailer.delivery_method
    assert_equal({}, mailer.smtp_settings)
    assert(logger.lines.any? { |level, line| level == :warn && line.include?("MAIL_TRANSPORT=ses is no longer supported") })
  end

  def test_ses_value_without_resend_keeps_the_default_transport
    mailer = FakeMailer.new(:smtp, {})
    env = { "MAIL_TRANSPORT" => "ses", "SES_SMTP_USERNAME" => "user", "SES_SMTP_PASSWORD" => "pass" }

    result = Studio::MailTransport.configure!(env: env, rails_env: "development", action_mailer: mailer, logger: nil)

    assert_equal :default, result.transport
    assert_equal :smtp, mailer.delivery_method
    assert_equal({}, mailer.smtp_settings, "no SES SMTP settings may be written")
  end

  def test_resend_value_is_known_and_logs_no_warning
    mailer = FakeMailer.new(:smtp, {})
    logger = RecordingLogger.new

    Studio::MailTransport.configure!(env: { "MAIL_TRANSPORT" => "resend", "RESEND_API_KEY" => "rk_test" },
                                     rails_env: "development", action_mailer: mailer, logger: logger,
                                     resend_loader: -> {}, resend_configurer: ->(_key) {})

    assert_empty(logger.lines.select { |level, _| level == :warn })
  end

  def test_uses_resend_when_api_key_present
    mailer = FakeMailer.new(:smtp, {})
    configured_key = nil
    loaded = false

    result = Studio::MailTransport.configure!(
      env: { "RESEND_API_KEY" => "rk_test" },
      rails_env: "development",
      action_mailer: mailer,
      logger: nil,
      resend_loader: -> { loaded = true },
      resend_configurer: ->(key) { configured_key = key }
    )

    assert_equal :resend, result.transport
    assert_equal :resend, mailer.delivery_method
    assert_equal "rk_test", configured_key
    assert loaded
  end

  def test_test_environment_does_not_change_delivery_method
    mailer = FakeMailer.new(:test, {})

    result = Studio::MailTransport.configure!(
      env: {
        "MAIL_TRANSPORT" => "ses",
        "SES_SMTP_USERNAME" => "user",
        "SES_SMTP_PASSWORD" => "pass"
      },
      rails_env: "test",
      action_mailer: mailer,
      logger: nil
    )

    assert_equal :test, result.transport
    assert_equal :test, mailer.delivery_method
    assert_equal({}, mailer.smtp_settings)
  end

  def test_default_when_no_transport_configured
    mailer = FakeMailer.new(:smtp, {})

    result = Studio::MailTransport.configure!(env: {}, rails_env: "development", action_mailer: mailer, logger: nil)

    assert_equal :default, result.transport
    assert_equal :smtp, mailer.delivery_method
  end
end
