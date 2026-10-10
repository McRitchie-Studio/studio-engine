# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../app/helpers/studio_email_delivery_helper"

class StudioEmailDeliveryHelperTest < Minitest::Test
  include StudioEmailDeliveryHelper

  FakeActionMailerBase = Struct.new(:delivery_method, :perform_deliveries, keyword_init: true)

  def setup
    @original_action_mailer = Object.const_get(:ActionMailer) if Object.const_defined?(:ActionMailer)
    Object.send(:remove_const, :ActionMailer) if Object.const_defined?(:ActionMailer)

    @original_local_email_capture = Studio.local_email_capture
    Studio.local_email_capture = false
    ENV.delete("MAIL_TRANSPORT")
    ENV.delete("SES_SMTP_USERNAME")
    ENV.delete("SES_SMTP_PASSWORD")
  end

  def teardown
    Object.send(:remove_const, :ActionMailer) if Object.const_defined?(:ActionMailer)
    Object.const_set(:ActionMailer, @original_action_mailer) if @original_action_mailer
    Studio.local_email_capture = @original_local_email_capture
    ENV.delete("MAIL_TRANSPORT")
    ENV.delete("SES_SMTP_USERNAME")
    ENV.delete("SES_SMTP_PASSWORD")
  end

  def test_reports_resend_real_send
    install_action_mailer(:resend, true)

    assert_equal "EMAIL SEND true · resend", email_delivery_banner_status
    assert_equal({
      connector: "resend",
      connector_label: "Resend",
      email_state: "Sending",
      provider_icon: "resend-favicon.png",
      sends_email: true,
      status_icon: "✅",
      tooltip: "Connector: Resend · Emails: Sending",
      transport: "resend"
    }, email_delivery_banner_details)
  end

  # SES was retired 2026-10-10: a stale MAIL_TRANSPORT=ses with the old SMTP
  # pair no longer labels the banner SES; it reports the real delivery method.
  def test_a_stale_ses_env_reports_the_real_delivery_method
    install_action_mailer(:smtp, true)
    ENV["MAIL_TRANSPORT"] = "ses"
    ENV["SES_SMTP_USERNAME"] = "user"
    ENV["SES_SMTP_PASSWORD"] = "pass"

    assert_equal "EMAIL SEND true · smtp", email_delivery_banner_status
    assert_nil email_delivery_banner_details.fetch(:provider_icon)
    assert_equal "Connector: Unknown · Emails: Sending", email_delivery_banner_details.fetch(:tooltip)
  end

  def test_reports_capture_when_local_capture_is_enabled
    install_action_mailer(:resend, true)
    Studio.local_email_capture = true

    assert_equal "EMAIL SEND false · capture", email_delivery_banner_status
    assert_equal "resend", email_delivery_banner_details.fetch(:connector)
    assert_equal "Captured", email_delivery_banner_details.fetch(:email_state)
    assert_equal "Connector: Resend · Emails: Captured", email_delivery_banner_details.fetch(:tooltip)
  end

  def test_reports_false_for_non_delivering_methods
    install_action_mailer(:test, true)

    assert_equal "EMAIL SEND false · test", email_delivery_banner_status
    assert_nil email_delivery_banner_details.fetch(:provider_icon)
    assert_equal "Connector: Unknown · Emails: Captured", email_delivery_banner_details.fetch(:tooltip)
  end

  def test_reports_false_when_perform_deliveries_is_disabled
    install_action_mailer(:resend, false)

    assert_equal "EMAIL SEND false · resend", email_delivery_banner_status
  end

  private

  def install_action_mailer(delivery_method, perform_deliveries)
    action_mailer = Module.new
    action_mailer.const_set(:Base, FakeActionMailerBase.new(
      delivery_method: delivery_method,
      perform_deliveries: perform_deliveries
    ))
    Object.const_set(:ActionMailer, action_mailer)
  end
end
