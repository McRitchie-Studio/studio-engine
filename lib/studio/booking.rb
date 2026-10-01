# frozen_string_literal: true

# Studio.booking_url — the app's Google Calendar appointment schedule — and the
# two URLs the booking primitives derive from it. Pure Ruby. See
# docs/SITE_FOOTER.md.
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

    module_function

    def validate!(url)
      return if url.nil? || url.to_s.strip.empty?
      return if url.to_s.strip.match?(%r{\Ahttps://\S+\z})

      raise ArgumentError,
            "Studio.booking_url must be an https URL (got #{url.inspect}). Use the appointment " \
            "schedule's public link. See docs/SITE_FOOTER.md."
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
