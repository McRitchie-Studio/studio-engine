# frozen_string_literal: true

require_relative "../../test_helper"

class EmailSmokeTest < Minitest::Test
  def setup
    Studio.mailer_from = nil
    Studio.local_email_capture = nil
    ENV.delete("LOCAL_EMAIL_CAPTURE")
    ENV.delete("AGENT_WORKTREE")
  end

  def test_deliver_sends_with_resend_transport
    mailer = FakeActionMailer.new(delivery_method: :resend, perform_deliveries: true)
    Studio.mailer_from = "App <team@example.com>"

    result = Studio::EmailSmoke.deliver(
      to: "alex@example.com",
      action_mailer: mailer,
      env: {},
      app_name: "App",
      clock: FakeClock
    )

    assert_equal "resend", result.transport
    assert_equal "App <team@example.com>", result.from
    assert_equal "msg-123@example.test", result.message_id
    assert_equal true, result.external_delivery
    assert_equal "alex@example.com", mailer.sent.fetch(:to)
    assert_includes mailer.sent.fetch(:body), "Transport: resend"
  end

  def test_result_labels_the_delivery_method_even_with_a_stale_ses_env
    mailer = FakeActionMailer.new(delivery_method: :smtp, perform_deliveries: true)
    env = {
      "MAIL_TRANSPORT" => "ses",
      "SES_SMTP_USERNAME" => "user",
      "SES_SMTP_PASSWORD" => "pass"
    }

    result = Studio::EmailSmoke.result_for(
      app_name: "App",
      to: "alex@example.com",
      from: "App <team@example.com>",
      subject: "App email smoke test",
      action_mailer: mailer,
      env: env
    )

    assert_equal "smtp", result.transport, "SES is retired; the label is the real delivery method"
    assert_equal true, result.external_delivery
  end

  def test_deliver_rejects_capture_mode_by_default
    mailer = FakeActionMailer.new(delivery_method: :resend, perform_deliveries: true)
    Studio.local_email_capture = true

    error = assert_raises Studio::EmailSmoke::NonExternalDeliveryError do
      Studio::EmailSmoke.deliver(to: "alex@example.com", action_mailer: mailer, env: {}, app_name: "App")
    end

    assert_equal "capture", error.result.transport
    assert_equal false, error.result.external_delivery
    assert_nil mailer.sent
  end

  def test_deliver_rejects_perform_deliveries_false_by_default
    mailer = FakeActionMailer.new(delivery_method: :resend, perform_deliveries: false)

    error = assert_raises Studio::EmailSmoke::NonExternalDeliveryError do
      Studio::EmailSmoke.deliver(to: "alex@example.com", action_mailer: mailer, env: {}, app_name: "App")
    end

    assert_equal false, error.result.perform_deliveries
    assert_equal false, error.result.external_delivery
    assert_nil mailer.sent
  end

  def test_deliver_can_allow_non_external_proof
    mailer = FakeActionMailer.new(delivery_method: :test, perform_deliveries: true)

    result = Studio::EmailSmoke.deliver(
      to: "alex@example.com",
      action_mailer: mailer,
      env: {},
      app_name: "App",
      require_external: false
    )

    assert_equal "test", result.transport
    assert_equal false, result.external_delivery
    assert_equal "alex@example.com", mailer.sent.fetch(:to)
  end

  class FakeClock
    def self.now
      Time.utc(2026, 6, 14, 20, 0, 0)
    end
  end

  class FakeActionMailer
    attr_accessor :delivery_method, :perform_deliveries
    attr_reader :sent

    def initialize(delivery_method:, perform_deliveries:)
      @delivery_method = delivery_method
      @perform_deliveries = perform_deliveries
    end

    def mail(to:, from:, subject:, body:)
      @sent = { to: to, from: from, subject: subject, body: body }
      FakeMessage.new
    end
  end

  class FakeMessage
    def deliver_now
      self
    end

    def message_id
      "msg-123@example.test"
    end
  end
end
