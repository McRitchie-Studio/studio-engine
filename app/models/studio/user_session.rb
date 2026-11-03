# frozen_string_literal: true

module Studio
  # One signed-in browser session: who, whether they were an admin, when it
  # started and when it was last seen. It is a cached record for the app's own
  # dashboard, kept on purpose without an IP, a user agent or a path.
  #
  # A new row starts after IDLE without a request. An open row is written at most
  # once per THROTTLE, and the cookie remembers when, so a request inside that
  # window runs no query at all.
  #
  # Nil-safe, because the table comes from a migration the host runs: an app that
  # has not run it records nothing and serves as before.
  class UserSession < ApplicationRecord
    self.table_name = "studio_user_sessions"

    IDLE = 30.minutes
    THROTTLE = 5.minutes

    belongs_to :user, class_name: "::User", optional: true

    scope :recent, -> { order(last_seen_at: :desc) }
    scope :non_admin, -> { where(admin: false) }

    # Per app, like Studio.session_key: apps on the hub's shared cookie
    # (STUDIO_SSO_SHARED_COOKIE) must not read each other's mark.
    def self.cookie_key = :"#{Studio.session_key}_session_mark"

    # Off under test unless a test asks: the row a first request writes would count in

    # every host's query-budget test, which measures the page and not this.

    cattr_accessor :record_in_test, default: false


    def self.recording?

      !Rails.env.test? || record_in_test

    end


    def self.available?
      connection.data_source_exists?(table_name)
    rescue ActiveRecord::ActiveRecordError, NoMethodError
      false
    end

    # Records this request for `user`, reading and writing `store` (the session).
    # Answers the row it wrote, or nil. Never raises: a request must not fail
    # because its bookkeeping did.
    def self.track(store, user, now: Time.current)
      return if user.nil? || !recording?

      mark = store[cookie_key]
      mark = mark.to_h.transform_keys(&:to_s) if mark.respond_to?(:to_h)
      same_user = mark.is_a?(Hash) && mark["user"] == user.id
      seen = same_user ? Time.zone.at(mark["at"].to_i) : nil
      return if seen && seen > now - THROTTLE
      return unless available?

      row = same_user && seen > now - IDLE ? find_by(id: mark["id"], user_id: user.id) : nil
      if row
        row.update_columns(last_seen_at: now)
      else
        admin = user.respond_to?(:admin?) && user.admin?
        row = create!(user_id: user.id, admin: admin ? true : false, started_at: now, last_seen_at: now)
      end
      store[cookie_key] = { "id" => row.id, "user" => user.id, "at" => now.to_i }
      row
    rescue StandardError => e
      Rails.logger&.warn("[user_session] #{e.class}: #{e.message}")
      nil
    end
  end
end
