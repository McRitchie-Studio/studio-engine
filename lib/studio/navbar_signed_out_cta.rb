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
# Three optional keys (each absent, the CTA renders as it did in 0.113.0):
#
#   modal:         "auth", or { id: "auth", props: { step: "credentials" } }.
#                  The button opens that modal on the engine's modal host
#                  ($store.modals.open(id, props)) and path stays its href, the
#                  fallback with no script or no modal host. The expression is
#                  the engine's, built from this data: the id is a plain name
#                  and props must be JSON (strings, numbers, booleans, nil,
#                  arrays and hashes of them), so no host JavaScript reaches the
#                  page as a string.
#   sign_in_link:  false drops the quiet sign-in text link (desktop and phone
#                  row), for an app whose CTA IS its sign-in. Default true.
#   sign_in_path:  where the sign-in text link points. Default login_path.
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
    OPTIONAL_KEYS = %i[modal sign_in_link sign_in_path].freeze
    MODAL_ID = /\A[A-Za-z_][\w-]*\z/
    SETTING = "Studio.navbar_signed_out_cta"

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
      unknown = config.keys - KEYS - OPTIONAL_KEYS
      raise InvalidConfig, "#{SETTING} has unknown key :#{unknown.first}" if unknown.any?

      cta = KEYS.to_h { |key| [key, text(config[key], key)] }
      cta[:modal] = modal(config[:modal]) if config.key?(:modal) && !config[:modal].nil?
      if config.key?(:sign_in_link)
        unless [true, false].include?(config[:sign_in_link])
          raise InvalidConfig, "#{SETTING} :sign_in_link must be true or false (got #{config[:sign_in_link].inspect})"
        end

        cta[:sign_in_link] = config[:sign_in_link]
      end
      cta[:sign_in_path] = text(config[:sign_in_path], :sign_in_path) if config.key?(:sign_in_path) && !config[:sign_in_path].nil?
      cta
    end

    # A non-blank String or Symbol, as a plain stripped String. String.new drops
    # an html_safe flag, so ERB escapes whatever came back.
    def text(value, key)
      unless (value.is_a?(String) || value.is_a?(Symbol)) && !value.to_s.strip.empty?
        raise InvalidConfig, "#{SETTING} needs a non-blank :#{key} (got #{value.inspect})"
      end

      String.new(value.to_s).strip
    end

    # The modal to open, as { id: String, props: Hash }.
    def modal(value)
      value = { id: value } if value.is_a?(String) || value.is_a?(Symbol)
      unless value.is_a?(Hash)
        raise InvalidConfig, "#{SETTING} :modal must be a modal id or a Hash { id:, props: } (got #{value.class})"
      end

      value = value.to_h { |key, entry| [key.to_sym, entry] }
      unknown = value.keys - %i[id props]
      raise InvalidConfig, "#{SETTING} :modal has unknown key :#{unknown.first}" if unknown.any?

      id = value[:id].to_s
      unless (value[:id].is_a?(String) || value[:id].is_a?(Symbol)) && id.match?(MODAL_ID)
        raise InvalidConfig, "#{SETTING} :modal needs an :id that is a plain name (got #{value[:id].inspect})"
      end

      props = value.fetch(:props, nil) || {}
      raise InvalidConfig, "#{SETTING} :modal :props must be a Hash (got #{props.class})" unless props.is_a?(Hash)

      { id: String.new(id), props: json(props, "#{SETTING} :modal :props") }
    end

    # A JSON value: strings, numbers, booleans, nil, and arrays and hashes of
    # them. Hash keys become Strings.
    def json(value, where)
      case value
      when Hash
        value.to_h do |key, entry|
          raise InvalidConfig, "#{where} keys must be Strings or Symbols (got #{key.inspect})" unless key.is_a?(String) || key.is_a?(Symbol)

          [String.new(key.to_s), json(entry, "#{where}[#{key.inspect}]")]
        end
      when Array then value.each_with_index.map { |entry, index| json(entry, "#{where}[#{index}]") }
      when String, Symbol then String.new(value.to_s)
      when Integer, Float, true, false, nil then value
      else raise InvalidConfig, "#{where} must be JSON: strings, numbers, booleans, nil, arrays, hashes (got #{value.class})"
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
