# frozen_string_literal: true

# Resolves the two words the engine navbar says about who is (or is not) signed
# in: the signed-in user's name (Studio.navbar_user_name) and the signed-out
# button's label (Studio.sign_in_label). Pure Ruby, so the unit suite covers it
# without the dummy app.
#
# Studio.navbar_user_name is one of:
#
#   nil                     the default: user.display_name, as before
#   :player_name            a method called on the user ("player_name" works too)
#   ->(user, view) { ... }  a callable; a one-argument callable gets the user only
#
# A layout must not 500 over a name. When the configured method or callable
# RAISES, the navbar prints display_name and the failure is reported once per
# process per error class (ErrorLog when the host has it, else Rails.logger),
# not once per page view. A BLANK answer falls back to display_name quietly:
# a user with no player name yet is data, not a fault.
#
# The name comes back as a plain String, never an html_safe buffer, so ERB
# escapes whatever a host's method or callable returned.
module Studio
  module NavbarIdentity
    class InvalidConfig < ArgumentError; end

    DEFAULT_SIGN_IN_LABEL = "Log in"

    @reported = {}
    @reported_lock = Mutex.new

    module_function

    def user_name(user, view = nil, config: Studio.navbar_user_name)
      fallback = user.display_name # outside the rescue: the default path is not ours to swallow
      return fallback if config.nil?

      begin
        text = plain_text(configured_name(config, user, view))
      rescue StandardError => e
        report_once(e)
        return fallback
      end
      text.empty? ? fallback : text
    end

    def validate_name!(config)
      return nil if config.nil? || config.respond_to?(:call)
      return nil if (config.is_a?(Symbol) || config.is_a?(String)) && !config.to_s.strip.empty?

      raise InvalidConfig, "Studio.navbar_user_name must be nil, a method name (Symbol) or a callable " \
                           "->(user, view) (got #{config.inspect})"
    end

    def validate_label!(label)
      return nil if label.is_a?(String) && !label.strip.empty?

      raise InvalidConfig, "Studio.sign_in_label must be non-blank text (got #{label.inspect})"
    end

    # Forget what was reported, so a reconfigured name reports its own failure.
    def reset_reported!
      @reported_lock.synchronize { @reported.clear }
    end

    def configured_name(config, user, view)
      return user.public_send(config.to_sym) unless config.respond_to?(:call)

      config.respond_to?(:arity) && config.arity == 1 ? config.call(user) : config.call(user, view)
    end

    # String.new drops an html_safe flag: SafeBuffer#to_s returns the buffer
    # itself, which ERB would print raw.
    def plain_text(value)
      String.new(value.to_s).strip
    end

    def report_once(error)
      first = @reported_lock.synchronize { @reported[error.class.name] ? false : (@reported[error.class.name] = true) }
      return unless first

      if defined?(::ErrorLog) && ::ErrorLog.respond_to?(:capture!)
        ::ErrorLog.capture!(error)
      elsif defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger
        ::Rails.logger.warn("[studio-navbar] Studio.navbar_user_name failed, showing display_name: " \
                            "#{error.class}: #{error.message}")
      end
    rescue StandardError
      nil # reporting is best-effort: the navbar still renders
    end
  end
end
