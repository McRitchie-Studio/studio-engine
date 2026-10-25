# frozen_string_literal: true

# Studio.navbar_brand: the engine navbar's logo image and title words, for an
# app whose brand is not "the Navbar Logo theme image plus app_name with the
# last word in text-primary". Pure Ruby, so the unit suite covers it without
# the dummy app.
#
# nil, the default, renders the navbar byte-identical to before. A Hash:
#
#   config.navbar_brand = {
#     logo: "/icon-192.png",            # the image (default: Studio.logo_for("Navbar Logo"))
#     logo_size: 48,                    # width and height attributes, in px (optional)
#     alt: "Turf Monster",              # the image's alt (default: Studio.app_name)
#     words: [{ text: "Turf", class: "text-heading" },
#             { text: "Monster", class: "tm-wordmark" }]   # the title, one span each
#   }
#
# Every key is optional. words replaces the app_name split: each word is a
# String or { text:, class: }, drawn as its own truncating span in the title
# with the host's class and nothing else (no text-primary), so a split
# wordmark styles each half. Studio.navbar_wordmark, a one-piece lockup image,
# wins over this when both are set.
module Studio
  module NavbarBrand
    class InvalidConfig < ArgumentError; end

    SETTING = "Studio.navbar_brand"
    KEYS = %i[logo logo_size alt words].freeze
    WORD_KEYS = %i[text class].freeze

    module_function

    # The config as a Hash with only the keys given, or nil when unset.
    def normalize(config)
      return nil if config.nil?
      raise InvalidConfig, "#{SETTING} must be nil or a Hash (got #{config.class})" unless config.is_a?(Hash)

      config = config.to_h { |key, value| [key.to_sym, value] }
      unknown = config.keys - KEYS
      raise InvalidConfig, "#{SETTING} has unknown key :#{unknown.first}" if unknown.any?

      brand = {}
      brand[:logo] = text(config[:logo], "#{SETTING}[:logo]") unless config[:logo].nil?
      brand[:alt] = text(config[:alt], "#{SETTING}[:alt]") unless config[:alt].nil?
      unless config[:logo_size].nil?
        size = config[:logo_size]
        unless size.is_a?(Integer) && size.positive?
          raise InvalidConfig, "#{SETTING}[:logo_size] must be a positive Integer of px (got #{size.inspect})"
        end

        brand[:logo_size] = size
      end
      brand[:words] = words(config[:words]) unless config[:words].nil?
      brand.freeze
    end

    def words(list)
      unless list.is_a?(Array) && list.any?
        raise InvalidConfig, "#{SETTING}[:words] must be a non-empty Array (got #{list.inspect})"
      end

      list.each_with_index.map do |word, index|
        where = "#{SETTING}[:words][#{index}]"
        word = { text: word } if word.is_a?(String)
        raise InvalidConfig, "#{where} must be a String or a Hash { text:, class: } (got #{word.class})" unless word.is_a?(Hash)

        word = word.to_h { |key, value| [key.to_sym, value] }
        unknown = word.keys - WORD_KEYS
        raise InvalidConfig, "#{where} has unknown key :#{unknown.first}" if unknown.any?

        { text: text(word[:text], "#{where}[:text]"),
          class: word[:class].nil? ? nil : text(word[:class], "#{where}[:class]") }.freeze
      end.freeze
    end

    # A non-blank String, stripped. String.new drops an html_safe flag, so ERB
    # escapes whatever came back.
    def text(value, where)
      raise InvalidConfig, "#{where} must be a non-blank String (got #{value.inspect})" unless value.is_a?(String) && !value.strip.empty?

      String.new(value).strip.freeze
    end
  end
end
