# frozen_string_literal: true

module Studio
  # Emails the daily application health report (Studio::HealthReport). The
  # engine schedules nothing: a host turns it on by registering this job at
  # Studio.health_report_hour in Studio.health_report_zone AND naming a
  # recipient. docs/HEALTH_REPORT.md has both snippets.
  #
  # Best-effort, like mcritchie-studio's ContactFlaggedDigestJob: a failure is an
  # ErrorLog receipt (and so a line in tomorrow's report), never a retry storm.
  class HealthReportJob < (defined?(::ApplicationJob) ? ::ApplicationJob : ActiveJob::Base)
    queue_as :default

    def perform(now = Time.current)
      # QA boots RAILS_ENV=production with a copy of nothing anyone needs to hear about.
      return if Studio.qa_environment?

      recipients = Studio::HealthReport.recipients
      return if recipients.empty?

      to = recipients.join(", ")
      window_end = Studio::HealthReport.window(now).end
      Studio::Email.deliver(Studio::HealthReportMailer, :daily, window_end.iso8601, to, to: to)
    rescue StandardError => e
      ErrorLog.capture!(e)
    end
  end
end
