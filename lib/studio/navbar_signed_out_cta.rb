# frozen_string_literal: true

# Resolves Studio.navbar_signed_out_cta, the call to action the engine navbar's
# signed-out primary button carries in place of sign-in. Pure Ruby, so the unit
# suite covers it without the dummy app.
#
# Studio.navbar_signed_out_cta is one of:
#
#   nil                              the default: the button is the sign-in
#                                    button (Studio.sign_in_label -> login_path),
#                                    byte-identical to before the setting
#   { label: "Build App", path: "/build" }
#                                    the button carries this label and path, and
#                                    a quiet sign-in text link sits beside it
#   ->(view) { { label:, path: } }   a callable receiving the view; answering nil
#                                    keeps the default for that render
#
# It is separate from Studio.sign_in_label on purpose: that label also words the
# engine's own auth pages (lib/studio/auth_labels.rb), so it cannot be bent into
# a marketing CTA. The sign-in link always keeps it.
#
# A bad static Hash raises InvalidConfig at assignment; a callable's answer is
# checked when it resolves and raises the same error. A callable that RAISES
# is a runtime fault, not a shape fault: the navbar falls back to the sign-in
# button and the failure is reported once per process per error class, so a
# layout never 500s over a CTA.
module Studio
  module NavbarSignedOutCta
    class InvalidConfig < ArgumentError; end

    KEYS = %i[label path].freeze

    @reported = {}
    @reported_lock = Mutex.new

    module_function

    # The CTA for one render, as { label:, path: } with plain String values, or
    # nil for the default sign-in button.
    def resolve(config, view)
      return nil if config.nil?
      return normalize(config) unless config.respond_to?(:call)

      begin
        answer = config.call(view)
      rescue StandardError => e
        report_once(e)
        return nil
      end
      answer.nil? ? nil : normalize(answer)
    end

    # Shape check without a view: a static Hash fails at boot, not on the first
    # signed-out page. A callable is checked when it resolves.
    def validate!(config)
      return nil if config.nil? || config.respond_to?(:call)

      normalize(config)
      nil
    end

    def normalize(config)
      unless config.is_a?(Hash)
        raise InvalidConfig, "Studio.navbar_signed_out_cta must be nil, a Hash { label:, path: } " \
                             "or a callable returning one (got #{config.class})"
      end

      config = config.to_h { |key, value| [key.to_sym, value] }
      unknown = config.keys - KEYS
      raise InvalidConfig, "Studio.navbar_signed_out_cta has unknown key :#{unknown.first}" if unknown.any?

      KEYS.to_h do |key|
        value = config[key]
        unless (value.is_a?(String) || value.is_a?(Symbol)) && !value.to_s.strip.empty?
          raise InvalidConfig, "Studio.navbar_signed_out_cta needs a non-blank :#{key} (got #{value.inspect})"
        end

        # String.new drops an html_safe flag, so ERB escapes whatever came back.
        [key, String.new(value.to_s).strip]
      end
    end

    # Forget what was reported, so a reconfigured callable reports its own failure.
    def reset_reported!
      @reported_lock.synchronize { @reported.clear }
    end

    def report_once(error)
      first = @reported_lock.synchronize { @reported[error.class.name] ? false : (@reported[error.class.name] = true) }
      return unless first

      if defined?(::ErrorLog) && ::ErrorLog.respond_to?(:capture!)
        ::ErrorLog.capture!(error)
      elsif defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger
        ::Rails.logger.warn("[studio-navbar] Studio.navbar_signed_out_cta failed, showing the sign-in button: " \
                            "#{error.class}: #{error.message}")
      end
    rescue StandardError
      nil # reporting is best-effort: the navbar still renders
    end
  end
end
