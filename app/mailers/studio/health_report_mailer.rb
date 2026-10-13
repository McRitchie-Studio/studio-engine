# frozen_string_literal: true

module Studio
  # The daily application health report. Namespaced so a host's own mailers
  # cannot shadow it (see Studio::NewsletterMailer).
  #
  # It takes the window's END as an ISO-8601 string, not a built report, so the
  # outbox stores a plain string and a retry re-reads the SAME day.
  class HealthReportMailer < ApplicationMailer
    # The report is an operator memo, not a branded email: its own plain
    # document, whatever mailer layout the host's ApplicationMailer sets.
    layout false

    def daily(window_end, to)
      finish = Time.iso8601(window_end.to_s)
      @report = Studio::HealthReport.build(window: Studio::HealthReport.window_ending(finish))
      mail(to: to, subject: @report.subject)
    end
  end
end
