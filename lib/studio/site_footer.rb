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
#     { tagline: "Everything, by example",
#       address: { street: "123 Example St", city_line: "Washington, DC 20024",
#                  lat: 38.8894, lng: -77.0352 },
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

    # The engine's own booking page keeps the footer for a signed-in viewer.
    OWN_CONTROLLERS = %w[studio/bookings].freeze

    # The only schemes a footer href may carry. Anything else, notably
    # `javascript:` and `data:`, is never written into an href: the label is
    # printed unlinked and the rejection is reported once.
    SAFE_SCHEMES = %w[http https mailto tel].freeze
    REPORTED_LIMIT = 100

    class << self
      # Where a rejected href is reported: a callable taking the message. The
      # default writes one warning to the Rails log (or to stderr without Rails).
      attr_writer :reporter

      def reporter
        @reporter ||= lambda do |message|
          if defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger
            ::Rails.logger.warn(message)
          else
            warn(message)
          end
        end
      end

      def reported
        @reported ||= {}
      end

      def reset_reported!
        @reported = {}
      end
    end

    module_function

    # A relative path (no scheme), or one of SAFE_SCHEMES. A control character
    # anywhere fails it: browsers drop tabs and newlines inside a scheme, so
    # "java\tscript:" would otherwise read as a relative path here and as
    # script there.
    def safe_href?(href)
      string = href.to_s
      return false if string.match?(/[\x00-\x1f\x7f]/)

      scheme = string[/\A\s*([a-z][a-z0-9+.\-]*):/i, 1]
      scheme.nil? || SAFE_SCHEMES.include?(scheme.downcase)
    end

    # The href when it may be linked, else nil, reported once per value.
    def safe_href(value, where)
      raw = value.nil? || value == false ? nil : value.to_s
      return nil if raw.nil? || raw.strip.empty?
      return raw.strip if safe_href?(raw)

      key = "#{where}:#{raw}"
      unless SiteFooter.reported.key?(key) || SiteFooter.reported.size >= REPORTED_LIMIT
        SiteFooter.reported[key] = true
        SiteFooter.reporter.call(
          "[studio.site_footer] #{where} #{raw[0, 80].inspect} is not linked: only relative paths, " \
          "http:, https:, mailto: and tel: are allowed"
        )
      end
      nil
    end

    # True on the app's OWN booking page (Studio.booking_path), which keeps the
    # footer for a signed-in viewer as the engine's page does. Matched by the
    # request's path, because the app's controller could be named anything.
    def booking_page?(view, booking_path)
      return false if booking_path.nil?
      return false unless view.respond_to?(:request) && view.request.respond_to?(:path)

      Studio::Booking.same_path?(view.request.path, booking_path)
    end

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
    #   booking_path: the booking page's path (Studio.booking_path_for), or nil
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
        home_path: safe_href(facts[:home_path], "home_path") || "/",
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

    # The default rule, asked of a view: the answer Studio.site_footer_visible
    # gives until an app replaces it. An app narrowing the rule composes with it:
    #
    #   config.site_footer_visible = ->(view) {
    #     Studio::SiteFooter.default_visible?(view) && !view.controller_path.start_with?("app/")
    #   }
    #
    # `booking_path` is the app's own booking page (Studio.booking_path, resolved
    # for this view); the engine's page is exempt by its controller instead.
    def default_visible?(view, controllers: nil, booking_path: nil)
      controllers = Studio.site_footer_controllers if controllers.nil? && defined?(Studio.site_footer_controllers)
      if booking_path.nil? && Studio.respond_to?(:booking_path) && Studio.booking_path
        booking_path = Studio.booking_path_for(view)
      end
      return true if booking_page?(view, booking_path)

      visible?(
        logged_in: view.respond_to?(:logged_in?) && view.logged_in? ? true : false,
        controller_name: view.respond_to?(:controller_name) ? view.controller_name : nil,
        controller_path: view.respond_to?(:controller_path) ? view.controller_path : nil,
        controllers: Array(controllers) + OWN_CONTROLLERS
      )
    end

    def validate_visible!(rule)
      return if rule.respond_to?(:call)

      raise ArgumentError,
            "Studio.site_footer_visible must be a callable receiving the view (got #{rule.class}). " \
            "See docs/SITE_FOOTER.md."
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
        # A directions_url that may not be linked falls back to the default, so
        # the address and the map's no-script link still lead somewhere.
        directions_url: safe_href(source[:directions_url], "directions_url") ||
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

      { label: label, icon: (icon || label).to_s.downcase.to_sym, url: safe_href(url, "social url"),
        unlinked: !text(url).nil? && safe_href(url, "social url").nil? }
    end

    # [ heading, links ], [ heading, links, { width: 1.5 } ] or { heading:,
    # links:, width: }. `width` is an optional hint: this column's share of the
    # row against the others' 1 (see `tracks`).
    def column(row, booking_path)
      heading, links, options =
        if row.respond_to?(:to_h) && !row.is_a?(Array)
          hash = symbolize(row)
          [hash[:heading] || hash[:title], hash[:links], hash]
        else
          Array(row)
        end
      heading = text(heading)
      links = Array(links).filter_map { |link_row| link(link_row, booking_path) }
      return nil if heading.nil? && links.empty?

      options = options.respond_to?(:to_h) && !options.is_a?(Array) ? symbolize(options) : {}
      { heading: heading, links: links, width: column_width(options[:width]) }
    end

    # A column's width hint, or nil for the default share. Anything that is not a
    # number between MIN_COLUMN_WIDTH and MAX_COLUMN_WIDTH is no hint.
    MIN_COLUMN_WIDTH = 0.5
    MAX_COLUMN_WIDTH = 4

    def column_width(value)
      return nil unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite?
      return nil unless value >= MIN_COLUMN_WIDTH && value <= MAX_COLUMN_WIDTH

      value.to_f
    end

    # True for a label that is an address rather than words: no space in it, and
    # an "@", a "." or a "/". It is kept on one line (.ftr-link-solid).
    def solid_label?(label)
      string = label.to_s
      !string.match?(/\s/) && string.match?(%r{[@./]})
    end

    # THE LINK COLUMNS' GRID TRACKS from 768px, one per column: its `width:`
    # hint as an fr share, else FIRST_COLUMN_WIDTH for the first (the one that
    # usually holds an email address) and 1 for the rest. nil when there are no
    # columns, or more than MAX_ROW_COLUMNS: those wrap as equal tracks.
    FIRST_COLUMN_WIDTH = 1.5
    MAX_ROW_COLUMNS = 4

    def tracks(columns)
      columns = Array(columns)
      return nil if columns.empty? || columns.size > MAX_ROW_COLUMNS

      columns.each_with_index.map do |column, index|
        "#{format('%g', column[:width] || (index.zero? ? FIRST_COLUMN_WIDTH : 1))}fr"
      end.join(" ")
    end

    # [ label, href ], [ label, href, { booking: true } ] or { label:, href:,
    # booking: }. A nil href is a disabled label; an http(s) href opens in a new
    # tab; `booking: true`, or an href equal to the booking page's path, opens
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

      declared = text(href)
      href = safe_href(href, "link href")
      options = options.respond_to?(:to_h) ? symbolize(options) : {}
      booking = !href.nil? && (options[:booking] ? true : (!booking_path.nil? && href == booking_path))
      {
        label: label,
        href: href,
        # A nil href is a page that does not exist yet. A REFUSED href is not
        # that: the label prints plain, with no "coming soon".
        disabled: declared.nil?,
        unlinked: !declared.nil? && href.nil?,
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
