# frozen_string_literal: true

require "uri"

module Studio
  # The "Email image generator" link at the top of /admin/emails: where an
  # operator goes to make a new banner with the app's own artwork. Each app
  # points it at its own generator, from config/initializers/studio.rb:
  #
  #   config.email_image_generator_url = "https://example.com/email-art"
  #   # or, worked out per request:
  #   config.email_image_generator_url = ->(request) { "#{request.base_url}/admin/email-art" }
  #
  #   config.email_image_generator_label       = "Header generator"   # optional
  #   config.email_image_generator_description = "Open it, copy ..."  # optional
  #
  # Unset, nil or blank means no link, and the page renders exactly as it did
  # before the setting existed.
  #
  # The URL is written into an href, so only an absolute http or https URL with
  # a host is accepted. A configured String that is anything else (a
  # `javascript:` URL, a relative path, a bare word) raises at boot, where the
  # mistake is cheap to see. A callable is judged on what it RETURNS, at render
  # time, and an unusable answer renders no link rather than breaking the page.
  #
  # Pure Ruby, so it loads and unit-tests without Rails.
  module EmailImageGenerator
    DEFAULT_LABEL = "Email image generator"

    # Generic on purpose: every consuming app shows it unless it says otherwise.
    DEFAULT_DESCRIPTION = "Make a new header with %<app>s's character model: " \
                          "open the generator, copy the prompt, paste it into Claude Code."

    SCHEMES = %w[http https].freeze

    # Whitespace or a control character anywhere. URI's parser tolerates some of
    # these, and a browser strips tab and newline from an href, so a URL that
    # carries one is refused rather than reasoned about.
    UNSAFE_CHARACTER = /[\x00-\x20\x7f]/

    # The link to render: url, label and description, all plain strings (the
    # view escapes them).
    Link = Struct.new(:url, :label, :description, keyword_init: true)

    module_function

    # An absolute http(s) URL with a host.
    def web_url?(value)
      return false unless value.is_a?(String)

      string = value.strip
      return false if string.empty? || string.match?(UNSAFE_CHARACTER)

      uri = URI.parse(string)
      SCHEMES.include?(uri.scheme.to_s.downcase) && !uri.host.to_s.empty?
    rescue URI::InvalidURIError
      false
    end

    # The setter's check. nil, a blank String and a callable pass; any other
    # value must be a web URL.
    def validate_url!(value)
      return if value.nil? || value.respond_to?(:call)
      return if value.is_a?(String) && value.strip.empty?
      return if web_url?(value)

      raise ArgumentError,
            "Studio.email_image_generator_url must be an http(s) URL, a callable returning one, " \
            "or nil (got #{value.inspect})."
    end

    # What the setter stores: nil for blank, a stripped String, or the callable.
    def normalize_url(value)
      validate_url!(value)
      return value if value.respond_to?(:call)

      string = value.to_s.strip
      string.empty? ? nil : string
    end

    # The URL for this request, or nil when there is no usable one. A callable
    # receives the request (or nothing, if it takes no argument).
    def resolve_url(configured, request = nil)
      value =
        if configured.respond_to?(:call)
          arity = configured.respond_to?(:arity) ? configured.arity : 1
          arity.zero? ? configured.call : configured.call(request)
        else
          configured
        end
      web_url?(value) ? value.strip : nil
    end

    # The Link to render, or nil when no link is configured.
    def link(url:, label: nil, description: nil, app_name: nil, request: nil)
      resolved = resolve_url(url, request)
      return nil if resolved.nil?

      Link.new(
        url: resolved,
        label: present(label) || DEFAULT_LABEL,
        description: present(description) || format(DEFAULT_DESCRIPTION, app: present(app_name) || "this app")
      )
    end

    def present(value)
      string = value.to_s.strip
      string.empty? ? nil : string
    end
  end
end
