module Studio
  # An operator's per-email overrides, editable from /admin/emails.
  #
  # The registry (code) supplies defaults; a row here overrides them for THIS
  # app. That split matters: the scrim is the dial between a readable header and
  # a visible picture, and the right value depends on artwork that changes
  # without a deploy — so it has to be tunable by the person looking at it.
  #
  # Nil-safe throughout, because the table is installed by a migration the host
  # runs. An app that has not run it yet must still send email.
  class EmailSetting < ApplicationRecord
    self.table_name = "studio_email_settings"

    SCRIM_RANGE = (0..100).freeze

    validates :email_key, presence: true, uniqueness: true
    validates :scrim_percent, numericality: { only_integer: true,
                                              greater_than_or_equal_to: SCRIM_RANGE.min,
                                              less_than_or_equal_to: SCRIM_RANGE.max },
                              allow_nil: true

    class << self
      # The saved scrim for this email as a 0.0-1.0 fraction, or nil when the
      # operator has not set one (the registry default then applies).
      def scrim_for(key)
        return nil unless table_ready?

        percent = find_by(email_key: key.to_s)&.scrim_percent
        percent.nil? ? nil : percent / 100.0
      end

      # Store a percent, or clear the override with nil/blank so the email falls
      # back to the registry default rather than being pinned to whatever the
      # default happened to be on the day.
      def set_scrim(key, percent)
        return nil unless table_ready?

        record = find_or_initialize_by(email_key: key.to_s)
        record.scrim_percent = percent.presence&.to_i
        record.save!
        record
      end

      # Reference the constant directly so Zeitwerk autoloads it — defined?()
      # does NOT trigger autoload, so it reads "undefined" for a not-yet-loaded
      # const and would silently disable every setting.
      def table_ready?
        table_exists?
      rescue ActiveRecord::ActiveRecordError, NameError
        false
      end
    end
  end
end
