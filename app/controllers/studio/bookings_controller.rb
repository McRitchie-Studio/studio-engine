# frozen_string_literal: true

module Studio
  # /schedule — the app's booking page: Google Calendar's appointment page
  # inline (studio/booking/_frame), inside the host's own layout.
  #
  # Public by design: it is where every "Schedule a call" link lands when the
  # popup cannot open, so it skips the host's sign-in gate
  # (mcritchie-industries and cyvasse gate every controller through
  # Studio::ErrorHandling). It inherits the host's ApplicationController so the
  # page renders in the app's layout, navbar and theme.
  #
  # Drawn only when the host opts in (Studio.draw_booking_routes). With no
  # Studio.booking_url there is nothing to book, and it answers 404.
  class BookingsController < ::ApplicationController
    skip_before_action :require_authentication, raise: false

    def show
      head :not_found if Studio.booking_url.blank?
    end
  end
end
