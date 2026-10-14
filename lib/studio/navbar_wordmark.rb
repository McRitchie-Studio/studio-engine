# frozen_string_literal: true

# Studio.navbar_wordmark: an opt-in brand lockup image (an icon plus the app's
# words, made as one piece of artwork) that the engine navbar draws in place of
# the "Navbar Logo" image and the app_name text. Pure Ruby, so the unit suite
# covers it without the dummy app.
#
# The config is nil (the default, and the navbar renders as it always has) or
# a Hash naming one file per theme:
#
#   config.navbar_wordmark = { light: "/brand/navbar-light.svg",
#                              dark:  "/brand/navbar-dark.svg" }
#
# light is the artwork drawn on a LIGHT page, dark the artwork drawn on a DARK
# page (the root carries the `dark` class). Both images render; engine.css hides
# the one that does not match the theme, so a toggle swaps them with no script.
module Studio
  module NavbarWordmark
    class InvalidConfig < ArgumentError; end

    THEMES = %i[light dark].freeze

    module_function

    # The config as { light: String, dark: String }, or nil when unset.
    def normalize(config)
      return nil if config.nil?

      validate!(config)
      THEMES.to_h { |theme| [theme, fetch(config, theme).strip] }
    end

    def validate!(config)
      return nil if config.nil?

      unless config.is_a?(Hash)
        raise InvalidConfig, "Studio.navbar_wordmark must be nil or a Hash of " \
                             "{ light: path, dark: path } (got #{config.inspect})"
      end

      extra = config.keys.map(&:to_sym) - THEMES
      raise InvalidConfig, "Studio.navbar_wordmark takes only :light and :dark (got #{extra.inspect})" if extra.any?

      THEMES.each do |theme|
        value = fetch(config, theme)
        next if value.is_a?(String) && !value.strip.empty?

        raise InvalidConfig, "Studio.navbar_wordmark[:#{theme}] must be a non-blank path (got #{value.inspect})"
      end
      nil
    end

    def fetch(config, theme)
      config.key?(theme) ? config[theme] : config[theme.to_s]
    end
  end
end
