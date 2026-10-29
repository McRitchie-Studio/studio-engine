# frozen_string_literal: true

require "time"

module Studio
  class EmailSmoke
    NON_EXTERNAL_METHODS = %w[test file].freeze

    Result = Struct.new(
      :app_name,
      :to,
      :from,
      :subject,
      :transport,
      :delivery_method,
      :perform_deliveries,
      :external_delivery,
      :message_id,
      keyword_init: true
    ) do
      def report_lines
        [
          "Email smoke -> #{external_delivery ? 'sent' : 'not externally sent'}",
          "  app=#{app_name}",
          "  to=#{to}",
          "  from=#{from}",
          "  subject=#{subject}",
          "  transport=#{transport}",
          "  delivery_method=#{delivery_method}",
          "  perform_deliveries=#{perform_deliveries}",
          "  external_delivery=#{external_delivery}",
          "  message_id=#{message_id || '(none)'}"
        ]
      end
    end

    class NonExternalDeliveryError < StandardError
      attr_reader :result

      def initialize(result)
        @result = result
        super("email smoke would not send externally")
      end
    end

    class << self
      def deliver(to:,
                  action_mailer: defined?(ActionMailer) ? ActionMailer::Base : nil,
                  env: ENV,
                  app_name: defined?(Studio) && Studio.respond_to?(:app_name) ? Studio.app_name : "Studio",
                  require_external: true,
                  clock: Time)
        raise ArgumentError, "action_mailer is required" unless action_mailer

        recipient = to.to_s.strip
        raise ArgumentError, "recipient email is required" if recipient.empty?

        from = sender(env)
        subject = "#{app_name} email smoke test"
        body = body_for(
          app_name: app_name,
          to: recipient,
          from: from,
          transport: transport_label(action_mailer: action_mailer, env: env),
          delivery_method: action_mailer.delivery_method,
          perform_deliveries: action_mailer.perform_deliveries,
          sent_at: clock.now.utc
        )
        result = result_for(
          app_name: app_name,
          to: recipient,
          from: from,
          subject: subject,
          action_mailer: action_mailer,
          env: env
        )

        if require_external && !result.external_delivery
          raise NonExternalDeliveryError, result
        end

        message = action_mailer.mail(
          to: recipient,
          from: from,
          subject: subject,
          body: body
        )
        delivered = message.deliver_now
        result.message_id = delivered.message_id if delivered.respond_to?(:message_id)
        result
      end

      def result_for(app_name:, to:, from:, subject:, action_mailer:, env: ENV)
        delivery_method = action_mailer.delivery_method.to_s
        Result.new(
          app_name: app_name,
          to: to,
          from: from,
          subject: subject,
          transport: transport_label(action_mailer: action_mailer, env: env),
          delivery_method: delivery_method,
          perform_deliveries: !!action_mailer.perform_deliveries,
          external_delivery: external_delivery?(action_mailer: action_mailer, env: env)
        )
      end

      def sender(env = ENV)
        studio_value(:mailer_from) ||
          env_value(env, "MAILER_FROM") ||
          default_sender
      end

      def transport_label(action_mailer:, env: ENV)
        return "capture" if studio_local_email_capture?

        delivery_method = action_mailer.delivery_method.to_s
        return "resend" if delivery_method == "resend"

        delivery_method.empty? ? "unknown" : delivery_method
      end

      def external_delivery?(action_mailer:, env: ENV)
        return false if studio_local_email_capture?

        delivery_method = action_mailer.delivery_method.to_s
        !!action_mailer.perform_deliveries && !NON_EXTERNAL_METHODS.include?(delivery_method)
      end

      private

      def default_sender
        if defined?(Studio) && Studio.respond_to?(:default_mailer_from)
          Studio.default_mailer_from
        else
          "McRitchie Studio <team@mcritchie.studio>"
        end
      end

      def body_for(app_name:, to:, from:, transport:, delivery_method:, perform_deliveries:, sent_at:)
        <<~TEXT
          Email smoke test for #{app_name}

          This message was sent by studio-engine's shared email smoke task.

          To: #{to}
          From: #{from}
          Transport: #{transport}
          Delivery method: #{delivery_method}
          perform_deliveries: #{perform_deliveries}
          Sent at: #{sent_at.iso8601}

          If you did not expect this message, no account action was performed.
        TEXT
      end

      def env_value(env, key)
        value = env[key]
        value if value && !value.to_s.strip.empty?
      end

      def studio_value(method)
        return unless defined?(Studio) && Studio.respond_to?(method)

        value = Studio.public_send(method)
        value if value && !value.to_s.strip.empty?
      end

      def studio_local_email_capture?
        defined?(Studio) && Studio.respond_to?(:local_email_capture?) && Studio.local_email_capture?
      end
    end
  end
end
