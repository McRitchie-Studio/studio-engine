# frozen_string_literal: true

module Studio
  # The site footer and the booking primitives, as view helpers. See
  # docs/SITE_FOOTER.md.
  #
  #   <%= studio_site_footer %>             the footer, where it should show
  #   <%= studio_booking_frame %>           Google's booking page, inline
  #   <%= studio_booking_link "Book a call", class: "btn btn-primary" %>
  #   <%= studio_booking_popup %>           the dialog those links open
  #   <%= studio_footer_map %>              the map alone, e.g. on a contact page
  #
  # Every one of them renders NOTHING when its configuration is absent
  # (Studio.site_footer, Studio.booking_url), so a layout or a shared view can
  # call them before an app has declared anything.
  #
  # Prefixed names for the reason Studio::GeoHelper gives: every helper module is
  # included into every view.
  module SiteFooterHelper
    # The resolved facts (Studio::SiteFooter.resolve), or nil. Resolved once per
    # request.
    #
    # A callable that RAISES must not take every page down with it, because the
    # footer is in the layout. In production the error is logged once per process
    # and the page renders with no footer; locally it raises, so whoever wrote the
    # callable sees it.
    def studio_site_footer_facts
      return @_studio_site_footer_facts if defined?(@_studio_site_footer_facts)

      @_studio_site_footer_facts =
        begin
          Studio.site_footer_for(self)
        rescue StandardError => error
          raise if studio_site_footer_raise?

          studio_site_footer_report(error)
          nil
        end
    end

    # Where the footer shows: Studio.site_footer_visible, asked of this view. By
    # default that is every page for a visitor and, for a signed-in viewer, only
    # the controllers in Studio.site_footer_controllers (plus the engine's booking
    # page). Always false for an app that declared no footer.
    def studio_show_site_footer?
      return false if studio_site_footer_facts.nil?

      Studio.site_footer_visible.call(self) ? true : false
    end

    # The one layout line. Renders the footer (and, with a booking_url, the
    # booking popup) where studio_show_site_footer? says it belongs.
    def studio_site_footer
      return unless studio_show_site_footer?

      render "studio/site_footer/footer", facts: studio_site_footer_facts
    end

    # The live map alone. With no arguments it maps the footer's address;
    # pass lat:/lng: (and street:/city_line:/directions_url:) to map another.
    # `class:` and `style:` size it: the element has no height of its own.
    def studio_footer_map(address = nil, **options)
      address = address ? Studio::SiteFooter.address(Studio::SiteFooter.symbolize(address)) : studio_site_footer_facts&.dig(:address)
      return unless address && address[:map]

      render "studio/site_footer/map", address: address, classes: options[:class], style: options[:style],
                                       zoom: options[:zoom], controls: options.fetch(:controls, true)
    end

    # ---- booking ------------------------------------------------------------

    def studio_booking? = Studio.booking_url.present?

    # Google's embeddable page for the configured schedule (with gv=true).
    def studio_booking_embed_url = Studio::Booking.embed_url(Studio.booking_url)

    # Where a booking link goes when the popup cannot open (scripts off, a
    # modified click, a page with no dialog): the app's booking page when the
    # engine draws it, else Google's own page.
    def studio_booking_fallback_path
      return studio_booking_path if Studio.draw_booking_routes && respond_to?(:studio_booking_path)

      Studio.booking_url
    end

    # The frame's accessible name.
    def studio_booking_title(title = nil)
      title.presence || studio_site_footer_facts&.dig(:booking_title) ||
        "#{studio_booking_label} with #{studio_site_footer_name}"
    end

    # What the booking links, the popup and the booking page call the act.
    def studio_booking_label
      studio_site_footer_facts&.dig(:booking_label) || Studio::SiteFooter::DEFAULT_BOOKING_LABEL
    end

    # The site's name: the footer's, else the site identity's title.
    def studio_site_footer_name
      studio_site_footer_facts&.dig(:name) || Studio.site_identity[:title]
    end

    # The inline booking frame. `crop: false` shows Google's whole page at rest.
    def studio_booking_frame(title: nil, crop: true)
      return unless studio_booking?

      render "studio/booking/frame", title: studio_booking_title(title), crop: crop
    end

    # The booking dialog, once per page however often it is asked for. The
    # footer renders it; call this yourself only on a page that has booking
    # links and no footer.
    def studio_booking_popup(label: nil, title: nil)
      return unless studio_booking?
      return if @_studio_booking_popup_rendered

      @_studio_booking_popup_rendered = true
      render "studio/booking/popup",
             label: label.presence || studio_booking_label,
             title: studio_booking_title(title)
    end

    # A link that opens the booking popup in place. Its href is the fallback, so
    # it is an ordinary link wherever the popup is unavailable. With no
    # booking_url and no href there is nowhere to go, and it renders nothing.
    #
    #   <%= studio_booking_link %>                                  "Schedule a call"
    #   <%= studio_booking_link "Book a call", class: "btn btn-primary" %>
    #   <%= studio_booking_link "Book a call", contact_path %>      your own fallback
    def studio_booking_link(name = nil, href = nil, html_options = nil, **options, &block)
      html_options, href = href, nil if href.is_a?(Hash)
      html_options, name = name, nil if name.is_a?(Hash)
      html_options = (html_options || {}).merge(options)
      href ||= studio_booking_fallback_path
      return if href.blank?

      html_options[:data] = { booking_popup: true }.merge(html_options[:data] || {}) if studio_booking?
      content = block ? capture(&block) : (name || studio_booking_label)
      link_to(content, href, html_options)
    end

    # ---- once-per-page assets -----------------------------------------------

    def studio_site_footer_assets
      return if @_studio_site_footer_assets_rendered

      @_studio_site_footer_assets_rendered = true
      render "studio/site_footer/assets"
    end

    def studio_booking_assets
      return if @_studio_booking_assets_rendered

      @_studio_booking_assets_rendered = true
      render "studio/booking/assets"
    end

    private

    def studio_site_footer_raise?
      defined?(Rails) && Rails.respond_to?(:env) && (Rails.env.development? || Rails.env.test?)
    end

    def studio_site_footer_report(error)
      return if Studio::SiteFooterHelper.reported

      Studio::SiteFooterHelper.reported = true
      if defined?(::ErrorLog) && ::ErrorLog.respond_to?(:capture!)
        ::ErrorLog.capture!(error)
      elsif defined?(Rails.logger) && Rails.logger
        Rails.logger.error("[studio.site_footer] #{error.class}: #{error.message}")
      end
    rescue StandardError
      nil
    end

    class << self
      attr_accessor :reported
    end
  end
end
