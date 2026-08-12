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

    # The banner's words and logo. Each is nil until the operator sets it, and
    # nil means INHERIT — never "empty".
    COPY_FIELDS = %i[header header_fallback subtext logo_url subject].freeze

    class << self
      # The saved scrim for this email as a 0.0-1.0 fraction, or nil when the
      # operator has not set one (the registry default then applies).
      def scrim_for(key)
        return nil unless table_ready?

        percent = find_by(email_key: key.to_s)&.scrim_percent
        percent.nil? ? nil : percent / 100.0
      end

      # One saved copy field, or nil to inherit. Blank is stored as nil by
      # #set_copy, so a blank return here always means "not set".
      def copy_for(key, field)
        return nil unless table_ready?
        return nil unless COPY_FIELDS.include?(field.to_sym)

        find_by(email_key: key.to_s)&.public_send(field).presence
      end

      # True when the operator has explicitly hidden the logo — which is a
      # different answer from "no logo url saved" (that one inherits).
      def hide_logo?(key)
        return false unless table_ready?

        find_by(email_key: key.to_s)&.hide_logo || false
      rescue ActiveRecord::ActiveRecordError
        false
      end

      # Save the words. A blank field is stored as NULL rather than "", so
      # clearing a box means "go back to the registry default" — the same
      # gesture that resets the tint.
      def set_copy(key, attrs)
        return nil unless table_ready?

        record = find_or_initialize_by(email_key: key.to_s)
        COPY_FIELDS.each do |field|
          next unless attrs.key?(field) || attrs.key?(field.to_s)

          record.public_send(:"#{field}=", (attrs[field] || attrs[field.to_s]).presence)
        end
        # ONLY when the form carried it. Two separate cards post to this method,
        # and an absent checkbox means "this form does not manage the logo", not
        # "show the logo" — writing false either way let saving the subject
        # silently un-hide a logo the operator had hidden.
        if attrs.key?(:hide_logo) || attrs.key?("hide_logo")
          record.hide_logo = ActiveModel::Type::Boolean.new.cast(attrs[:hide_logo] || attrs["hide_logo"]) || false
        end
        record.save!
        record
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
