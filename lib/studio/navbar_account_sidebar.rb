# frozen_string_literal: true

# Resolves Studio.navbar_account_sidebar: the host sidebar the signed-in user
# nav's account control (the name and the avatar, one control) opens, in place
# of linking to the account page or opening the engine's link sidebar. Pure
# Ruby, so the unit suite covers it without the dummy app.
#
# Studio.navbar_account_sidebar is one of:
#
#   nil                     the default: the account control links to the
#                           account page or opens the link sidebar, as before
#   { flag: "gearOpen",     the control is a button that toggles
#     store: "sidebars",    $store.<store>.<flag> (store defaults to "sidebars")
#     controls: "gear-sidebar gear-sidebar-mobile" }
#                           and names the panels it opens in aria-controls
#                           (a String of ids or an Array of them)
#   ->(view) { ... }        a callable receiving the view; nil keeps the default
#
# The toggle expression is the engine's, built from these names, which must be
# plain JavaScript identifiers; no host JavaScript reaches the page as a string.
# :controls may not name the engine's own link sidebar (studio-link-sidebar,
# studio-link-sidebar-mobile): studio/link_sidebar would claim the click.
# The button also carries data-profile-image-toggle, so a host's capture-phase
# handler that claims its sidebar's triggers before Alpine binds (as
# studio/link_sidebar does for the link sidebar) claims this one too.
#
# A bad static Hash raises InvalidConfig at assignment; a callable's answer is
# checked when it resolves. A callable that RAISES renders the default and is
# reported once per process per error class, so a layout never 500s.
module Studio
  module NavbarAccountSidebar
    class InvalidConfig < ArgumentError; end

    SETTING = "Studio.navbar_account_sidebar"
    KEYS = %i[flag store controls].freeze
    IDENTIFIER = /\A[A-Za-z_$][\w$]*\z/
    DOM_ID = /\A[A-Za-z][\w:.-]*\z/
    # The engine's link sidebar panels: components/_link_sidebar renders them, and
    # app/javascript/studio/link_sidebar.js (LINK_SIDEBAR_PANELS) is the source of
    # truth; test/lib/navbar_account_sidebar_test.rb holds this list to it.
    # studio/link_sidebar claims a click on any trigger whose aria-controls names
    # them, so a host sidebar control that named one would open the engine's
    # panel, not the host's.
    ENGINE_LINK_SIDEBAR_IDS = %w[studio-link-sidebar studio-link-sidebar-mobile].freeze

    @reported = {}
    @reported_lock = Mutex.new

    module_function

    # The sidebar for one render, as { store:, flag:, controls: } with plain
    # Strings, or nil for the default account control.
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

    def validate!(config)
      normalize(config) unless config.nil? || config.respond_to?(:call)
      nil
    end

    def normalize(config)
      unless config.is_a?(Hash)
        raise InvalidConfig, "#{SETTING} must be nil, a Hash { flag:, store:, controls: } " \
                             "or a callable returning one (got #{config.class})"
      end

      config = config.to_h { |key, value| [key.to_sym, value] }
      unknown = config.keys - KEYS
      raise InvalidConfig, "#{SETTING} has unknown key :#{unknown.first}" if unknown.any?

      { store: identifier(config.fetch(:store, nil) || "sidebars", :store),
        flag: identifier(config[:flag], :flag),
        controls: controls(config[:controls]) }
    end

    def identifier(value, key)
      name = value.to_s
      unless (value.is_a?(String) || value.is_a?(Symbol)) && name.match?(IDENTIFIER)
        raise InvalidConfig, "#{SETTING} :#{key} must be a plain JavaScript name (got #{value.inspect})"
      end

      String.new(name)
    end

    def controls(value)
      ids = value.is_a?(Array) ? value : value.to_s.split
      ids = ids.map { |id| id.is_a?(Symbol) ? id.to_s : id }
      if ids.empty? || !ids.all? { |id| id.is_a?(String) && id.match?(DOM_ID) }
        raise InvalidConfig, "#{SETTING} :controls must name the panel ids it opens (got #{value.inspect})"
      end
      if (engine = ids & ENGINE_LINK_SIDEBAR_IDS).any?
        raise InvalidConfig, "#{SETTING} :controls names #{engine.join(' and ')}, the engine's link sidebar: " \
                             "studio/link_sidebar would take the click and open its panel, not the host's. " \
                             "Name the host's own panel ids, or leave the setting nil to keep the link sidebar"
      end

      ids.join(" ")
    end

    def reset_reported!
      @reported_lock.synchronize { @reported.clear }
    end

    def report_once(error)
      first = @reported_lock.synchronize { @reported[error.class.name] ? false : (@reported[error.class.name] = true) }
      return unless first

      if defined?(::ErrorLog) && ::ErrorLog.respond_to?(:capture!)
        ::ErrorLog.capture!(error)
      elsif defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger
        ::Rails.logger.warn("[studio-navbar] #{SETTING} failed, rendering the default account control: " \
                            "#{error.class}: #{error.message}")
      end
    rescue StandardError
      nil # reporting is best-effort: the navbar still renders
    end
  end
end
