# frozen_string_literal: true

module Studio
  class MailTransport
    Result = Struct.new(:transport, :delivery_method, :message, keyword_init: true)

    class << self
      def configure!(env: ENV,
                     rails_env: defined?(Rails) && Rails.respond_to?(:env) ? Rails.env : "development",
                     action_mailer: defined?(ActionMailer) ? ActionMailer::Base : nil,
                     logger: defined?(Rails) && Rails.respond_to?(:logger) ? Rails.logger : nil,
                     mailer_from: defined?(Studio) && Studio.respond_to?(:mailer_from) ? Studio.mailer_from : nil,
                     resend_loader: method(:load_resend!),
                     resend_configurer: method(:configure_resend!))
        raise ArgumentError, "action_mailer is required" unless action_mailer

        if rails_env.to_s == "test"
          return Result.new(transport: :test, delivery_method: action_mailer.delivery_method, message: "test environment skipped")
        end

        selected = env["MAIL_TRANSPORT"].to_s.downcase
        ses_ready = selected == "ses" && present?(env["SES_SMTP_USERNAME"]) && present?(env["SES_SMTP_PASSWORD"])

        if selected == "ses" && !ses_ready
          log(logger, :warn, "[mail] MAIL_TRANSPORT=ses but SES_SMTP_USERNAME/PASSWORD missing - keeping fallback transport")
        elsif present?(selected) && !%w[ses resend].include?(selected)
          log(logger, :warn, "[mail] unknown MAIL_TRANSPORT=#{selected.inspect} - keeping fallback transport")
        end

        if ses_ready
          configure_ses!(env: env, action_mailer: action_mailer)
          region = env.fetch("SES_REGION", "us-east-2")
          log(logger, :info, "[mail] transport=SES region=#{region} from=#{mailer_from}")
          return Result.new(transport: :ses, delivery_method: action_mailer.delivery_method, message: "SES SMTP active")
        end

        if present?(env["RESEND_API_KEY"])
          resend_loader.call
          resend_configurer.call(env["RESEND_API_KEY"])
          action_mailer.delivery_method = :resend
          log(logger, :info, "[mail] transport=Resend from=#{mailer_from}")
          return Result.new(transport: :resend, delivery_method: action_mailer.delivery_method, message: "Resend active")
        end

        Result.new(transport: :default, delivery_method: action_mailer.delivery_method, message: "no transactional transport configured")
      end

      def configure_ses!(env:, action_mailer:)
        region = env.fetch("SES_REGION", "us-east-2")
        action_mailer.delivery_method = :smtp
        action_mailer.smtp_settings = {
          address: env.fetch("SES_SMTP_HOST", "email-smtp.#{region}.amazonaws.com"),
          port: env.fetch("SES_SMTP_PORT", 587).to_i,
          user_name: env["SES_SMTP_USERNAME"],
          password: env["SES_SMTP_PASSWORD"],
          authentication: :login,
          enable_starttls_auto: true
        }
      end

      def load_resend!
        require "resend"
      end

      def configure_resend!(api_key)
        Resend.api_key = api_key
      end

      private

      def present?(value)
        !value.to_s.strip.empty?
      end

      def log(logger, level, message)
        return unless logger

        logger.public_send(level, message)
      end
    end
  end
end
