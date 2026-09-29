# frozen_string_literal: true

# Resolves Studio.navbar_links, the links the engine navbar renders in its
# desktop bar and phone row. Pure Ruby, so the unit suite covers it without
# the dummy app.
#
# Declared as an Array or a callable (receives the view context, so a badge can
# read current_user). Each entry resolves to:
#
#   { label: "Contests", href: "/contests", active: true, badge: "#12" }
#
# `active` may be true/false, a Regexp or a callable matched against
# request.path; omitted, it is true when the path equals the href's path.
# `badge` is optional short text. A bad entry raises InvalidLink by index.
module Studio
  module NavbarLinks
    class InvalidLink < ArgumentError; end

    KEYS = %i[label href active badge].freeze

    module_function

    def resolve(declared, view)
      links = declared.respond_to?(:call) ? declared.call(view) : declared
      path = request_path(view)
      entries(links).each_with_index.map do |link, index|
        link = check!(link, index)
        { label: link[:label].to_s, href: link[:href].to_s,
          active: active?(link, path), badge: badge(link[:badge]) }
      end
    end

    # Shape check without a request: a static list fails at boot, not on the
    # first page render. A callable is checked when it resolves.
    def validate!(declared)
      return nil if declared.respond_to?(:call)

      entries(declared).each_with_index { |link, index| check!(link, index) }
      nil
    end

    def entries(links)
      return [] if links.nil?
      return links if links.is_a?(Array)

      raise InvalidLink, "Studio.navbar_links must be an Array or a callable returning an Array " \
                         "(got #{links.class})"
    end

    def check!(link, index)
      where = "Studio.navbar_links[#{index}]"
      raise InvalidLink, "#{where} must be a Hash (got #{link.class})" unless link.is_a?(Hash)

      link = link.to_h { |key, value| [key.to_sym, value] }
      unknown = link.keys - KEYS
      raise InvalidLink, "#{where} has unknown key :#{unknown.first}" if unknown.any?

      %i[label href].each do |key|
        raise InvalidLink, "#{where} needs a :#{key}" if link[key].to_s.strip.empty?
      end
      unless [nil, true, false].include?(link[:active]) || link[:active].is_a?(Regexp) ||
             link[:active].respond_to?(:call)
        raise InvalidLink, "#{where} :active must be true, false, a Regexp or a callable"
      end
      unless link[:badge].nil? || [String, Symbol, Numeric].any? { |type| link[:badge].is_a?(type) }
        raise InvalidLink, "#{where} :badge must be short text"
      end

      link
    end

    def active?(link, path)
      case (rule = link[:active])
      when true, false then rule
      when nil then !path.nil? && path == link[:href].to_s.split(/[?#]/).first
      when Regexp then !path.nil? && rule.match?(path)
      else !path.nil? && rule.call(path) ? true : false
      end
    end

    def badge(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end

    def request_path(view)
      return nil unless view.respond_to?(:request)

      view.request&.path
    end
  end
end
