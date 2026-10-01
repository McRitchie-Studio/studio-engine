# frozen_string_literal: true

# Studio.booking_url — the app's Google Calendar appointment schedule — the two
# URLs the booking primitives derive from it, and the frame's crop
# (Studio.booking_crop). Pure Ruby. See docs/BOOKING.md.
#
# The configured value is the schedule's PUBLIC page, the URL Google gives you
# to share, without `?gv=true`:
#
#   config.booking_url = "https://calendar.google.com/calendar/appointments/schedules/EXAMPLE-SCHEDULE-ID"
#
# `gv=true` is what makes Google serve the embeddable page, so the frame and the
# popup add it; the "open the booking page" link does not.
module Studio
  module Booking
    EMBED_PARAM = "gv=true"

    # THE CROP. At rest the inline frame can show only Google's "Select an
    # appointment time" box, with Google's header above it and its credit lines
    # below clipped away. Where that box sits is a fact about ONE schedule (its
    # header is as tall as its title, description and meeting line; its box is as
    # tall as its fullest day), so the app measures its own and declares it:
    #
    #   config.booking_crop = { top: 200, bottom: 600, frame_height: 720 }
    #
    # All three are pixels in Google's own page, at 640px wide or more:
    #
    #   top:          the box's top edge. Stable for a schedule.
    #   bottom:       the box's bottom edge ON ITS FULLEST DAY. Not stable: the box
    #                 grows a row per appointment slot, so it is shorter on a day
    #                 with fewer slots left. Declare the tallest it gets.
    #   frame_height: the whole page's height on that fullest day. The frame is
    #                 this tall once it opens.
    #
    # `bin/booking-crop-measure <booking url>` prints the Hash.
    #
    # The window is [top - CROP_MARGIN, bottom + CROP_MARGIN], held inside the
    # frame. Because `bottom` is the tallest the box gets, a day with fewer slots
    # shows a strip of Google's credit lines under a shorter box; it never cuts
    # the box. A value that cannot be a crop (not a number, negative, bottom not
    # below top, a box that ends outside the frame, a window that hides nothing)
    # is reported once and the frame shows whole.
    CROP_MARGIN = 6
    CROP_KEYS = %i[top bottom frame_height].freeze
    REPORTED_LIMIT = 100

    class << self
      # Where a refused crop is reported: a callable taking the message. The
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
    end

    module_function

    def validate_crop!(declared)
      return if declared.nil? || declared == false || declared.is_a?(Hash)

      raise ArgumentError,
            "Studio.booking_crop must be nil, false, or a Hash of top:, bottom: and frame_height: " \
            "(got #{declared.inspect}). See docs/BOOKING.md."
    end

    # The crop to render: { offset:, window:, frame_height: } in whole pixels, or
    # nil for the whole frame at rest. `offset` is how far the frame is pulled up
    # behind its wrapper and `window` is the wrapper's height.
    def crop(declared)
      return nil if declared.nil? || declared == false
      return refuse_crop(declared, "it is not a Hash") unless declared.is_a?(Hash)

      values = CROP_KEYS.to_h { |key| [key, declared[key] || declared[key.to_s]] }
      missing = values.reject { |_key, value| value.is_a?(Numeric) && value.respond_to?(:round) && value.finite? }.keys
      return refuse_crop(declared, "#{missing.join(', ')} must be a number") unless missing.empty?

      top, bottom, frame_height = values.values_at(*CROP_KEYS).map(&:round)
      return refuse_crop(declared, "top is negative") if top.negative?
      return refuse_crop(declared, "bottom is not below top") unless bottom > top
      return refuse_crop(declared, "bottom is outside the frame") if bottom > frame_height

      offset = [top - CROP_MARGIN, 0].max
      window = [bottom + CROP_MARGIN, frame_height].min - offset
      return refuse_crop(declared, "the window is the whole frame") unless window < frame_height

      { offset: offset, window: window, frame_height: frame_height }
    end

    # The crop as the custom properties the wrapper carries, so two frames with
    # different crops can share a page (studio/booking/_assets reads them).
    def crop_style(crop)
      return nil if crop.nil?

      "--booking-crop-offset: #{crop[:offset]}px; --booking-crop-window: #{crop[:window]}px; " \
        "--booking-frame-height: #{crop[:frame_height]}px"
    end

    def refuse_crop(declared, why)
      message = "[studio.booking] booking crop #{declared.inspect} is ignored (#{why}); the frame shows whole. " \
                "See docs/BOOKING.md."
      seen = Studio::Booking.reported
      unless seen.key?(message)
        seen[message] = true if seen.size < REPORTED_LIMIT
        Studio::Booking.reporter.call(message)
      end
      nil
    end

    # Studio.booking_path: nil, a path, or a callable receiving the view.
    def validate_path!(declared)
      return if declared.nil? || declared.respond_to?(:call)
      return if declared.is_a?(String) && (declared.strip.empty? || declared.strip.start_with?("/"))

      raise ArgumentError,
            "Studio.booking_path must be nil, a path beginning with \"/\", or a callable receiving the view " \
            "(got #{declared.inspect}). See docs/BOOKING.md."
    end

    # True when `current` (a request path) is the page `declared` names. A query
    # string, a fragment and a trailing slash on either side do not count.
    def same_path?(current, declared)
      a, b = [current, declared].map { |path| path.to_s.strip.sub(/[?#].*\z/m, "").sub(%r{(?<=.)/+\z}, "") }
      !a.empty? && a == b
    end

    def validate!(url)
      return if url.nil? || url.to_s.strip.empty?
      return if url.to_s.strip.match?(%r{\Ahttps://\S+\z})

      raise ArgumentError,
            "Studio.booking_url must be an https URL (got #{url.inspect}). Use the appointment " \
            "schedule's public link. See docs/BOOKING.md."
    end

    # The public page, with any embed parameter removed. nil when unset.
    def page_url(url)
      string = url.to_s.strip
      return nil if string.empty?

      base, query = string.split("?", 2)
      kept = query.to_s.split("&").reject { |pair| pair.empty? || pair == EMBED_PARAM }
      kept.empty? ? base : "#{base}?#{kept.join('&')}"
    end

    # The embeddable page: the public page plus gv=true. nil when unset.
    def embed_url(url)
      page = page_url(url)
      return nil if page.nil?

      "#{page}#{page.include?('?') ? '&' : '?'}#{EMBED_PARAM}"
    end
  end
end
