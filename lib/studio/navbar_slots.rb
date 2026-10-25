# frozen_string_literal: true

# Resolves the engine navbar's two partial slots. Pure Ruby, so the unit suite
# covers it without the dummy app.
#
#   Studio.navbar_items         partials rendered after Studio.navbar_links, in
#                               the desktop bar AND the phone row
#   Studio.navbar_avatar_badge  one partial rendered over the signed-in avatar's
#                               upper-left corner (components/_user_nav, Div 3)
#   Studio.navbar_header_bars   partials rendered INSIDE the pinned header, above
#                               its row, so they never scroll away (a control
#                               bar such as an impersonation escape)
#   Studio.navbar_menu_trigger  one partial the icon rail and the phone row
#                               render in place of the admin dropdown
#
# A partial spec is one of:
#
#   "components/geo_badge"                          a partial path
#   { partial: "shared/wallet_signal",              a path with locals
#     locals: { tone: "muted" } }
#
# navbar_items and navbar_header_bars are Arrays of specs, navbar_avatar_badge
# and navbar_menu_trigger one spec or nil, and
# either may instead be a callable receiving the view that answers the same
# (nil meaning nothing for that render). Both defaults render nothing, so the
# navbar stays byte-identical until an app opts in.
#
# A bad static setting raises InvalidConfig at assignment; a callable's answer
# is checked when it resolves and raises the same error. A callable that RAISES
# is a runtime fault, not a shape fault: the slot renders nothing and the
# failure is reported once per process per setting per error class, so a layout
# never 500s over a badge. (Studio.navbar_signed_out_cta follows the same rules.)
module Studio
  module NavbarSlots
    class InvalidConfig < ArgumentError; end

    SPEC_KEYS = %i[partial locals].freeze
    ITEMS = "Studio.navbar_items"
    BADGE = "Studio.navbar_avatar_badge"
    HEADER_BARS = "Studio.navbar_header_bars"
    MENU_TRIGGER = "Studio.navbar_menu_trigger"

    @reported = {}
    @reported_lock = Mutex.new

    module_function

    # The item specs for one render, in order; [] renders nothing.
    def resolve_items(config, view, setting = ITEMS)
      answer = call(config, view, setting) { return [] }
      items(answer, setting)
    end

    # The badge spec for one render, or nil for no badge.
    def resolve_badge(config, view, setting = BADGE)
      answer = call(config, view, setting) { return nil }
      answer.nil? ? nil : spec(answer, setting)
    end

    # The header bar specs for one render, in order; [] renders nothing.
    def resolve_header_bars(config, view)
      resolve_items(config, view, HEADER_BARS)
    end

    # The menu trigger spec for one render, or nil for the admin dropdown.
    def resolve_menu_trigger(config, view)
      resolve_badge(config, view, MENU_TRIGGER)
    end

    # Shape checks without a view: a static setting fails at boot, not on the
    # first page render. A callable is checked when it resolves.
    def validate_items!(config, setting = ITEMS)
      items(config, setting) unless config.respond_to?(:call)
      nil
    end

    def validate_badge!(config, setting = BADGE)
      spec(config, setting) unless config.nil? || config.respond_to?(:call)
      nil
    end

    def validate_header_bars!(config) = validate_items!(config, HEADER_BARS)
    def validate_menu_trigger!(config) = validate_badge!(config, MENU_TRIGGER)

    def items(list, setting = ITEMS)
      return [] if list.nil?
      unless list.is_a?(Array)
        raise InvalidConfig, "#{setting} must be an Array of partial specs or a callable returning one " \
                             "(got #{list.class})"
      end

      list.each_with_index.map { |entry, index| spec(entry, "#{setting}[#{index}]") }
    end

    # One spec, as { partial: String, locals: Hash }.
    def spec(entry, where)
      entry = { partial: entry } if entry.is_a?(String) || entry.is_a?(Symbol)
      unless entry.is_a?(Hash)
        raise InvalidConfig, "#{where} must be a partial path or a Hash { partial:, locals: } (got #{entry.class})"
      end

      entry = entry.to_h { |key, value| [key.to_sym, value] }
      unknown = entry.keys - SPEC_KEYS
      raise InvalidConfig, "#{where} has unknown key :#{unknown.first}" if unknown.any?

      partial = entry[:partial]
      unless (partial.is_a?(String) || partial.is_a?(Symbol)) && !partial.to_s.strip.empty?
        raise InvalidConfig, "#{where} needs a non-blank :partial (got #{partial.inspect})"
      end

      locals = entry.fetch(:locals, nil) || {}
      raise InvalidConfig, "#{where} :locals must be a Hash (got #{locals.class})" unless locals.is_a?(Hash)

      { partial: partial.to_s.strip, locals: locals.to_h { |key, value| [key.to_sym, value] } }
    end

    # Forget what was reported, so a reconfigured callable reports its own failure.
    def reset_reported!
      @reported_lock.synchronize { @reported.clear }
    end

    # The setting itself, or a callable's answer for this view. A raise is
    # reported and hands control to the block, which returns the fallback.
    def call(config, view, setting)
      return config unless config.respond_to?(:call)

      config.call(view)
    rescue StandardError => e
      report_once(e, setting)
      yield
    end

    def report_once(error, setting)
      key = "#{setting} #{error.class.name}"
      first = @reported_lock.synchronize { @reported[key] ? false : (@reported[key] = true) }
      return unless first

      if defined?(::ErrorLog) && ::ErrorLog.respond_to?(:capture!)
        ::ErrorLog.capture!(error)
      elsif defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger
        ::Rails.logger.warn("[studio-navbar] #{setting} failed, rendering nothing in its place: " \
                            "#{error.class}: #{error.message}")
      end
    rescue StandardError
      nil # reporting is best-effort: the navbar still renders
    end
  end
end
