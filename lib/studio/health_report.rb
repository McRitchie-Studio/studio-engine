# frozen_string_literal: true

require "active_support"
require "active_support/time"
require "active_support/core_ext/module/attribute_accessors"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/try"
require "active_support/core_ext/string/filters"
require "active_support/security_utils"
require "digest"
require "time"
require_relative "version"

# The daily application health report: signups, errors and (optionally) contact
# messages from the last day, emailed at 07:00 in the app's zone. The full
# adoption guide is docs/HEALTH_REPORT.md.
#
# OFF BY DEFAULT, TWICE. Nothing sends until a host both SCHEDULES
# Studio::HealthReportJob (config/recurring.yml or sidekiq-cron) and NAMES a
# recipient (config.health_report_to, else ENV["STUDIO_HEALTH_REPORT_TO"]). The
# engine registers no schedule of its own, and with no recipient the job returns
# before it reads a row.
#
# THE WINDOW IS 07:00 TO 07:00 ON THE APP'S WALL CLOCK, end excluded, copied from
# mcritchie-studio's ContactFlaggedDigestJob. `24.hours.ago` would drop an hour
# on the fall-back day (a 25-hour day) and report an hour twice on the
# spring-forward one. Anchoring on the hour also makes the report a function of
# the DAY, not the run: a run that lands late, or a retry, reports exactly the
# window an on-time run would have, and a row at 07:00:00 belongs to one report.
#
# The config lives HERE rather than in lib/studio.rb so the unit suite loads it
# with the rules it governs; `Studio.configure` sets it like any other setting.
module Studio
  # Who gets the report. A String (comma-separated is fine), an Array, or a
  # callable returning either. nil or blank falls through to
  # ENV["STUDIO_HEALTH_REPORT_TO"]; nobody there either means no email.
  mattr_accessor :health_report_to, default: nil

  # The wall clock the window is cut on, and the hour that opens it. Schedule
  # the job at this hour in this zone; running it later reports the same day.
  mattr_accessor :health_report_zone, default: "America/Denver"
  mattr_accessor :health_report_hour, default: 7

  # Where signups come from: a callable taking the window (a Range of times)
  # and returning a relation, an Array, or an Integer count. The default reads
  # the host's `User` by created_at, which is every consumer today; an app whose
  # accounts live elsewhere points this at that model. nil omits the section.
  mattr_accessor :health_report_signups, default: :default

  # Contact-form submissions, OPTIONAL: nil (the default) omits the section,
  # because the engine has no contact model and each app names its own, e.g.
  #   config.health_report_contacts = ->(window) { ContactSubmission.where(created_at: window) }
  mattr_accessor :health_report_contacts, default: nil

  # The bearer token the hub presents to GET /_studio/health_report, the JSON
  # copy of this report that McRitchie Studio pulls from every app at 07:00 and
  # posts to Discord. nil or blank falls through to ENV["STUDIO_HEALTH_TOKEN"],
  # read on every request; blank there too means the endpoint answers 404.
  mattr_writer :health_report_token, default: nil

  def self.health_report_token
    class_variable_get(:@@health_report_token).presence || ENV.fetch(HealthReport::TOKEN_ENV_KEY, nil).presence
  end

  module HealthReport
    ENV_KEY = "STUDIO_HEALTH_REPORT_TO"
    TOKEN_ENV_KEY = "STUDIO_HEALTH_TOKEN"
    SCHEMA = 1         # the JSON contract's version; bump on a breaking change
    LISTED = 10        # names shown under a count; the count is always whole
    ERROR_GROUPS = 15  # distinct errors shown; the rest are counted as "more"

    # One section of the report. `items` is at most LISTED labels; `count` is
    # the true total. `failure` is set when the source raised: the report still
    # sends, and says that this one part could not be read.
    Section = Struct.new(:title, :count, :items, :failure, keyword_init: true) do
      def failed? = !failure.nil?
      # Rows counted but not listed. A count-only section lists none and owes no tail.
      def more = items.empty? ? 0 : [count.to_i - items.size, 0].max
    end

    # One distinct error: its class, its message, how often, first and last.
    ErrorGroup = Struct.new(:error_class, :message, :count, :first_seen, :last_seen, keyword_init: true)

    Report = Struct.new(:app_name, :window, :signups, :errors, :error_groups, :error_kinds, :contacts,
                        keyword_init: true) do
      def sections = [signups, errors, contacts].compact

      # Nothing happened and nothing failed: the email is the all-clear line.
      def quiet? = sections.all? { |s| !s.failed? && s.count.to_i.zero? }

      def subject
        return "#{app_name} health: all clear" if quiet?

        parts = sections.reject { |s| s.count.to_i.zero? && !s.failed? }.map do |s|
          s.failed? ? "#{s.title.downcase} unavailable" : HealthReport.pluralize(s.count, s.title.downcase.chomp("s"))
        end
        "#{app_name} health: #{parts.join(', ')}"
      end

      # A time on the report's own clock: "Oct 13, 6:42 AM".
      def stamp(time) = time ? time.in_time_zone(window.end.time_zone).strftime("%b %-d, %-l:%M %p") : "unknown"

      # "Oct 12, 7:00 AM to Oct 13, 7:00 AM MDT"
      def window_label
        from, to = window.begin, window.end
        "#{from.strftime('%b %-d, %-l:%M %p')} to #{to.strftime('%b %-d, %-l:%M %p %Z')}"
      end
    end

    module_function

    def window(now = Time.now, zone: Studio.health_report_zone, hour: Studio.health_report_hour)
      finish = now.in_time_zone(zone).change(hour: hour)
      finish -= 1.day if finish > now
      (finish - 1.day)...finish
    end

    # The window that ENDS at `finish` (the job passes this through the outbox,
    # so a retry re-reads the same day rather than the day it happens to run on).
    def window_ending(finish, zone: Studio.health_report_zone)
      finish = finish.in_time_zone(zone)
      (finish - 1.day)...finish
    end

    def recipients
      configured = Studio.health_report_to
      configured = configured.call if configured.respond_to?(:call)
      list = split(configured)
      list = split(ENV.fetch(ENV_KEY, nil)) if list.empty?
      list
    end

    def split(value)
      Array(value).flat_map { |v| v.to_s.split(",") }.map(&:strip).reject(&:empty?)
    end

    # ErrorLog.capture! stores "#<Class: message>"; a row written by hand may
    # carry only a message. Returns [class, message].
    def error_name(text)
      return ["Error", "(no message)"] if text.blank?

      match = /\A#<([A-Z][\w:]*): (.*)>\z/m.match(text.to_s)
      match ? [match[1], match[2]] : ["Error", text.to_s]
    end

    def pluralize(count, noun)
      "#{count} #{count == 1 ? noun : "#{noun}s"}"
    end

    # ---- the JSON endpoint (Studio::HealthReportsController) ---------------

    # Does this Authorization header carry the configured token? false when no
    # token is configured. Both sides are digested before the constant-time
    # compare, so neither the token's bytes nor its length leak through timing.
    def authorized?(authorization, token: Studio.health_report_token)
      return false if token.blank?

      presented = authorization.to_s[/\ABearer[ ]+(\S+)\s*\z/i, 1]
      return false if presented.nil?

      ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(presented),
                                                  Digest::SHA256.hexdigest(token.to_s))
    end

    # The window the endpoint reports: the day ENDING at `ending` (an ISO 8601
    # time), else the day the job would report now. Raises ArgumentError on a
    # value that is not ISO 8601, which the controller answers with a 400.
    def window_for(ending, now: Time.now)
      return window(now) if ending.nil?

      window_ending(Time.iso8601(ending.to_s))
    end

    SECTION_KEYS = %i[signups errors contacts].freeze

    # The report as the hub reads it. COUNTS ONLY, by construction: a Section's
    # `items` (names and emails) never reach this hash, so no signup or contact
    # detail leaves the app. Error groups carry the class and the truncated
    # message the email already shows.
    def payload(report)
      {
        schema: SCHEMA,
        app: report.app_name.to_s,
        engine_version: Studio::VERSION,
        window: { begin: iso(report.window.begin), end: iso(report.window.end), label: report.window_label },
        quiet: report.quiet?,
        sections: SECTION_KEYS.filter_map do |key|
          section = report.public_send(key)
          next unless section

          { key: key.to_s, title: section.title, count: section.count.to_i, failure: section.failure }
        end,
        error_kinds: report.error_kinds.to_i,
        error_groups: Array(report.error_groups).map do |group|
          { error_class: group.error_class, message: group.message, count: group.count.to_i,
            first_seen: iso(group.first_seen), last_seen: iso(group.last_seen) }
        end
      }
    end

    def iso(time) = time&.iso8601

    # ---- gathering (needs the host's database) ------------------------------

    def build(window: self.window(Time.now))
      Report.new(
        app_name: Studio.app_name,
        window: window,
        signups: section("Signups", Studio.health_report_signups, window),
        contacts: section("Contact messages", Studio.health_report_contacts, window),
        **errors(window)
      )
    end

    def section(title, source, window)
      source = default_signups_source if source == :default
      return nil if source.nil?

      collect(title, source.call(window))
    rescue StandardError => e
      capture(e)
      Section.new(title: title, count: 0, items: [], failure: e.class.name)
    end

    # The host's `User`, newest first, when it has a created_at; otherwise no
    # section at all, rather than a "0 signups" line that is not true.
    def default_signups_source
      return nil unless defined?(::User) && ::User.respond_to?(:column_names) && ::User.column_names.include?("created_at")

      ->(window) { ::User.where(created_at: window).order(created_at: :desc) }
    end

    def collect(title, result)
      case result
      when nil then Section.new(title: title, count: 0, items: [])
      when Integer then Section.new(title: title, count: result, items: [])
      else
        count = result.respond_to?(:count) ? result.count : result.size
        rows = result.respond_to?(:limit) ? result.limit(LISTED).to_a : Array(result).first(LISTED)
        Section.new(title: title, count: count, items: rows.map { |r| label(r) })
      end
    end

    # A short, human name for a row: its own health_report_label if it has
    # one, else a name, then an email, then "Model #id".
    def label(record)
      return record.to_s if record.is_a?(String)
      return record.health_report_label.to_s if record.respond_to?(:health_report_label)

      name = %i[display_name name].lazy.filter_map { |m| record.public_send(m).presence if record.respond_to?(m) }.first
      email = record.public_send(:email).presence if record.respond_to?(:email)
      return "#{name} <#{email}>" if name && email && name != email
      return (name || email).to_s if name || email

      "#{record.class.name} ##{record.try(:id)}"
    rescue StandardError
      "#{record.class.name} ##{record.try(:id)}"
    end

    # Grouped in SQL: a bad day can hold thousands of rows. The key is the
    # stored "#<Class: message>", which is the class AND the message.
    def errors(window)
      empty = { errors: Section.new(title: "Errors", count: 0, items: []), error_groups: [], error_kinds: 0 }
      return empty unless defined?(::ErrorLog) && ::ErrorLog.table_exists?

      key = "COALESCE(#{::ErrorLog.connection.quote_column_name('inspect')}, message)"
      scope = ::ErrorLog.where(created_at: window)
      total = scope.count
      return empty if total.zero?

      kinds = scope.distinct.count(Arel.sql(key))
      created = ::ErrorLog.type_for_attribute("created_at")
      groups = scope.group(Arel.sql(key)).order(Arel.sql("COUNT(*) DESC, MAX(created_at) DESC")).limit(ERROR_GROUPS)
                    .pluck(Arel.sql(key), Arel.sql("COUNT(*)"), Arel.sql("MIN(created_at)"), Arel.sql("MAX(created_at)"))
                    .map do |text, count, first, last|
        klass, message = error_name(text)
        ErrorGroup.new(error_class: klass, message: message.to_s.truncate(300), count: count.to_i,
                       first_seen: created.deserialize(first), last_seen: created.deserialize(last))
      end
      { errors: Section.new(title: "Errors", count: total, items: []), error_groups: groups, error_kinds: kinds }
    rescue StandardError => e
      capture(e)
      { errors: Section.new(title: "Errors", count: 0, items: [], failure: e.class.name), error_groups: [], error_kinds: 0 }
    end

    def capture(error)
      ::ErrorLog.capture!(error) if defined?(::ErrorLog)
    rescue StandardError
      nil
    end
  end
end
