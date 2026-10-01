# frozen_string_literal: true

require "cgi"

# Resolves Studio.site_footer — the facts the site footer prints — for a view.
# Pure Ruby (no Rails dependency), so the unit suite exercises the rules without
# booting the dummy app. See docs/SITE_FOOTER.md.
#
# The declared value is a Hash, or a callable that receives the view (for route
# helpers). EVERY KEY IS OPTIONAL, and a missing key removes its part of the
# footer rather than printing a placeholder:
#
#   config.site_footer = ->(view) {
#     { tagline: "Software & Marketing Solutions",
#       address: { street: "3000 Lawrence St", city_line: "Denver, CO 80205",
#                  lat: 39.7614786, lng: -104.978957 },
#       email:   "team@example.com",
#       social:  [ [ "LinkedIn", :linkedin, "https://www.linkedin.com/in/someone/" ],
#                  [ "Instagram", :instagram, nil ] ],          # nil url: unlinked
#       columns: [ [ "Company", [ [ "Home", view.root_path ],
#                                 [ "Career", nil ],            # nil path: disabled
#                                 [ "Blog", "https://blog.example.com" ] ] ] ],
#       legal:   [ [ "Privacy Policy", "/privacy" ], [ "Terms of Service", "/terms" ] ] }
#   }
#
# Rows may be written as tuples (above) or as hashes ({ label:, href: }); both
# normalize to the same symbol-keyed shape, which is what the partials read.
module Studio
  module SiteFooter
    DEFAULT_BOOKING_LABEL = "Schedule a call"
    DEFAULT_ZOOM = 15

    module_function

    def validate!(declared)
      return if declared.nil? || declared.is_a?(Hash) || declared.respond_to?(:call)

      raise ArgumentError,
            "Studio.site_footer must be nil, a Hash, or a callable receiving the view " \
            "(got #{declared.class}). See docs/SITE_FOOTER.md."
    end

    # The normalized facts, or nil when the app declared no footer.
    #
    #   name:         the site name the engine resolved (the site identity's title)
    #   logo:         the logo the engine resolved (the navbar logo), or nil
    #   booking_path: the booking page's path when the engine draws it, or nil
    def resolve(declared, view, name: nil, logo: nil, booking_path: nil)
      raw = declared.respond_to?(:call) ? declared.call(view) : declared
      return nil if raw.nil?

      facts = symbolize(raw)
      site_name = text(facts[:name]) || text(name)
      booking = symbolize(facts[:booking] || {})

      {
        name: site_name,
        wordmark: wordmark(facts[:wordmark], site_name),
        logo: facts.key?(:logo) ? text(facts[:logo]) : text(logo),
        logo_invert: facts[:logo_invert] ? true : false,
        home_path: text(facts[:home_path]) || "/",
        tagline: text(facts[:tagline]),
        email: text(facts[:email]),
        address: address(facts),
        social: Array(facts[:social]).filter_map { |row| social(row) },
        columns: Array(facts[:columns]).filter_map { |row| column(row, booking_path) },
        legal: Array(facts[:legal]).filter_map { |row| link(row, booking_path) },
        booking_label: text(booking[:label]) || DEFAULT_BOOKING_LABEL,
        booking_title: text(booking[:title])
      }
    end

    # Where the footer shows. A visitor always gets it; a signed-in viewer gets
    # it only on the controllers the app lists, because every other signed-in
    # page is a working surface. `controllers` entries match the controller's
    # name ("landing") or its path ("studio/bookings").
    def visible?(logged_in:, controller_name:, controller_path: nil, controllers: [])
      return true unless logged_in

      listed = Array(controllers).map(&:to_s)
      listed.include?(controller_name.to_s) || (!controller_path.nil? && listed.include?(controller_path.to_s))
    end

    # ---- normalization ------------------------------------------------------

    # Two parts: everything but the last word, then the last word, which the
    # footer prints in the primary colour (the navbar splits app_name the same
    # way). A one-word name has an empty first part.
    def wordmark(declared, name)
      parts = Array(declared).map { |part| text(part) }.compact
      return [parts[0..-2].join(" "), parts.last] if parts.length >= 2

      words = (parts.first || name).to_s.split
      return nil if words.empty?

      [words[0..-2].join(" "), words.last]
    end

    # The address may be nested under :address or written flat (street:,
    # city_line:, lat:, lng:, directions_url:). No street and no city line means
    # no address at all: no Location band and no map.
    def address(facts)
      declared = facts[:address]
      source = declared.nil? ? facts : symbolize(declared)
      street = text(source[:street])
      city_line = text(source[:city_line])
      return nil if street.nil? && city_line.nil?

      full = [street, city_line].compact.join(", ")
      lat = coordinate(source[:lat])
      lng = coordinate(source[:lng])
      {
        street: street,
        city_line: city_line,
        full: full,
        lat: lat,
        lng: lng,
        map: !lat.nil? && !lng.nil?,
        zoom: (source[:zoom] || DEFAULT_ZOOM).to_i,
        directions_url: text(source[:directions_url]) ||
          "https://www.google.com/maps/dir/?api=1&destination=#{CGI.escape(full)}"
      }
    end

    def coordinate(value)
      return nil if value.nil? || value.to_s.strip.empty?

      Float(value)
    rescue ArgumentError, TypeError
      nil
    end

    # [ label, icon, url ] or { label:, icon:, url: }. A nil url renders the
    # icon unlinked.
    def social(row)
      label, icon, url =
        if row.respond_to?(:to_h) && !row.is_a?(Array)
          hash = symbolize(row)
          [hash[:label], hash[:icon], hash[:url] || hash[:href]]
        else
          Array(row)
        end
      label = text(label)
      return nil if label.nil?

      { label: label, icon: (icon || label).to_s.downcase.to_sym, url: text(url) }
    end

    # [ heading, links ] or { heading:, links: }.
    def column(row, booking_path)
      heading, links =
        if row.respond_to?(:to_h) && !row.is_a?(Array)
          hash = symbolize(row)
          [hash[:heading] || hash[:title], hash[:links]]
        else
          Array(row)
        end
      heading = text(heading)
      links = Array(links).filter_map { |link_row| link(link_row, booking_path) }
      return nil if heading.nil? && links.empty?

      { heading: heading, links: links }
    end

    # [ label, href ], [ label, href, { booking: true } ] or { label:, href:,
    # booking: }. A nil href is a disabled label; an http(s) href opens in a new
    # tab; `booking: true`, or an href equal to the engine's booking page, opens
    # the booking popup (the href stays as the fallback).
    def link(row, booking_path = nil)
      label, href, options =
        if row.respond_to?(:to_h) && !row.is_a?(Array)
          hash = symbolize(row)
          [hash[:label], hash[:href] || hash[:path] || hash[:url], hash]
        else
          Array(row)
        end
      label = text(label)
      return nil if label.nil?

      href = text(href)
      options = options.respond_to?(:to_h) ? symbolize(options) : {}
      booking = !href.nil? && (options[:booking] ? true : (!booking_path.nil? && href == booking_path))
      {
        label: label,
        href: href,
        disabled: href.nil?,
        external: !href.nil? && href.match?(%r{\Ahttps?://}i),
        booking: booking
      }
    end

    def text(value)
      string = value.to_s.strip
      value.nil? || value == false || string.empty? ? nil : string
    end

    def symbolize(hash)
      hash.to_h.each_with_object({}) { |(key, value), out| out[key.to_sym] = value }
    end
  end
end
