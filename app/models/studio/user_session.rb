# frozen_string_literal: true

require "securerandom"

module Studio
  # One signed-in browser session: who, whether they were an admin, when it
  # started and when it was last seen. It is a cached record for the app's own
  # dashboard, kept on purpose without an IP, a user agent or a path.
  #
  # A new row starts after IDLE without a request. An open row is written at most
  # once per THROTTLE, and the cookie remembers when.
  #
  # A DEVICE SESSION YOU CAN END (docs/DEVICE_SESSIONS.md). The cookie store keeps
  # the whole session in the browser, so a logout used to delete only the
  # browser's copy: a copy of the pre-logout cookie still signed in. Each signed-in
  # cookie now carries a random `sid` in its mark, and every row of that device
  # session carries the same sid. A logout stamps `revoked_at` on those rows, and
  # every signed-in request reads the latest row for its sid (one indexed query):
  # revoked, or no row at all, and the request is signed out. Other devices have
  # other sids, so they stay signed in.
  #
  # Nil-safe, because the table and its columns come from migrations the host
  # runs: an app without them records nothing, checks nothing and serves as
  # before.
  class UserSession < ApplicationRecord
    self.table_name = "studio_user_sessions"

    IDLE = 30.minutes
    THROTTLE = 5.minutes
    # A device session idle this long has its rows pruned, so its cookie no longer
    # signs in: the user signs in again.
    RETENTION = 90.days
    PRUNE_EVERY = 1.hour
    PRUNE_BATCH = 1_000

    belongs_to :user, class_name: "::User", optional: true

    scope :recent, -> { order(last_seen_at: :desc) }
    scope :non_admin, -> { where(admin: false) }

    # Per app, like Studio.session_key: apps on the hub's shared cookie
    # (STUDIO_SSO_SHARED_COOKIE) must not read each other's mark.
    def self.cookie_key = :"#{Studio.session_key}_session_mark"

    # Off under test unless a test asks: the row a first request writes would count in
    # every host's query-budget test, which measures the page and not this.
    cattr_accessor :record_in_test, default: false

    # A signed-in cookie with no sid predates this change. Until this moment it is
    # accepted and given a sid on its request, so the deploy signs nobody out;
    # after it, such a cookie is signed out once. The bound matters: a copy of a
    # pre-deploy cookie carries no sid, so without it that copy would stay
    # replayable after the device logs out.
    cattr_accessor :legacy_grace_until, default: Time.utc(2026, 12, 8)

    # When this process last pruned (prune_due!). Per process, so it costs nothing.
    cattr_accessor :pruned_at, default: nil

    def self.recording?
      !Rails.env.test? || record_in_test
    end

    def self.available?
      connection.data_source_exists?(table_name)
    rescue ActiveRecord::ActiveRecordError, NoMethodError
      false
    end

    # The table carries the sid and revoked_at columns. The schema cache and the
    # model's column cache answer it, so a request pays no query for it.
    def self.revocable?
      return false unless connection.schema_cache.data_source_exists?(table_name)

      names = column_names
      names.include?("sid") && names.include?("revoked_at")
    rescue ActiveRecord::ActiveRecordError, NoMethodError
      false
    end

    # This app's mark in `store` (the session), as a string-keyed Hash.
    def self.mark_in(store)
      mark = store[cookie_key]
      mark.respond_to?(:to_h) ? mark.to_h.transform_keys(&:to_s) : {}
    end

    def self.new_sid = SecureRandom.urlsafe_base64(24)

    # The verdict on a signed-in request, read before anything else runs. Answers
    # [verdict, row]:
    #
    #   :live    the sid names a row that is not revoked (row is that row)
    #   :ended   the sid's latest row is revoked, or the sid has no row (pruned,
    #            or never written); also a sid-less cookie past legacy_grace_until
    #   :legacy  no sid, inside the grace: accepted, and track gives it one
    #   :off     nothing to check (not recording, or no columns)
    #
    # One indexed query when the cookie carries a sid, none otherwise. A failure
    # answers :off, so a database fault signs nobody out: the request's own user
    # lookup needs the same database, and a copied cookie cannot cause the fault.
    def self.verdict(store, now: Time.current)
      return [:off, nil] unless recording? && revocable?

      sid = mark_in(store)["sid"].presence
      return [now < legacy_grace_until ? :legacy : :ended, nil] unless sid

      row = where(sid: sid.to_s).order(id: :desc).first
      return [:ended, nil] if row.nil? || row.revoked_at

      [:live, row]
    rescue StandardError => e
      Rails.logger&.warn("[user_session] verdict #{e.class}: #{e.message}")
      [:off, nil]
    end

    # Starts this device's session at a sign-in (ErrorHandling#set_app_session):
    # writes its first row with a new sid and marks `store`, so the very next
    # request is checked. A sign-in by the same user over a live sid keeps it: a
    # re-auth is the same device session. A different user gets a new sid; the old
    # one is not revoked, since a sign-in is not a logout. Answers the row, or nil.
    # It raises on a failed write, so the caller can log it.
    def self.start!(store, user, now: Time.current)
      return unless user && recording? && revocable?

      mark = mark_in(store)
      return if mark["user"] == user.id && mark["sid"].present?

      admin = user.respond_to?(:admin?) && user.admin?
      row = create!(sid: new_sid, user_id: user.id, admin: admin ? true : false, started_at: now, last_seen_at: now)
      store[cookie_key] = { "id" => row.id, "user" => user.id, "at" => now.to_i, "sid" => row.sid }
      prune_due!(now)
      row
    end

    # Ends this device's session: stamps revoked_at on every row of its sid and
    # drops the mark from `store`. Other sids (other devices, and other apps on a
    # shared cookie) are untouched. Answers the rows it revoked. It raises on a
    # failed write, so the caller can log it (ErrorHandling#end_device_session).
    def self.revoke!(store, now: Time.current)
      sid = mark_in(store)["sid"].presence
      store.delete(cookie_key)
      return 0 unless sid && recording? && revocable?

      where(sid: sid.to_s, revoked_at: nil).update_all(revoked_at: now, updated_at: now)
    end

    # Records this request for `user`, reading and writing `store` (the session).
    # `row` is the row verdict read for this request, so tracking adds no read of
    # its own. Answers the row it wrote, or nil. Never raises: a request must not
    # fail because its bookkeeping did.
    def self.track(store, user, now: Time.current, row: nil)
      return if user.nil? || !recording?

      mark = mark_in(store)
      same_user = mark["user"] == user.id
      seen = same_user && mark["at"] ? Time.zone.at(mark["at"].to_i) : nil
      revocable = revocable?
      sid = same_user ? mark["sid"].presence : nil
      # A sid-less cookie does not wait out the throttle: it gets its sid now.
      return if seen && seen > now - THROTTLE && (sid || !revocable)
      return unless available?

      row = revocable && sid ? row_for_sid(sid, user, now, row) : legacy_row(mark, same_user, seen, user, now, revocable)
      if row
        changes = { last_seen_at: now }
        changes[:sid] = sid = new_sid if revocable && sid.nil?
        row.update_columns(changes)
      else
        sid ||= new_sid if revocable
        admin = user.respond_to?(:admin?) && user.admin?
        attrs = { user_id: user.id, admin: admin ? true : false, started_at: now, last_seen_at: now }
        attrs[:sid] = sid if revocable
        row = create!(attrs)
        prune_due!(now)
      end
      store[cookie_key] = { "id" => row.id, "user" => user.id, "at" => now.to_i }.tap { |m| m["sid"] = sid if revocable }
      row
    rescue StandardError => e
      Rails.logger&.warn("[user_session] #{e.class}: #{e.message}")
      nil
    end

    # The open row to move for this sid: the one verdict read, else the latest by
    # sid. Past IDLE nil, so a new row starts with the same sid.
    def self.row_for_sid(sid, user, now, row)
      row = nil unless row && row.sid == sid
      row ||= where(sid: sid).order(id: :desc).first
      row if row && row.user_id == user.id && row.revoked_at.nil? && row.last_seen_at > now - IDLE
    end
    private_class_method :row_for_sid

    # The row a sid-less mark names (a cookie from before sids, or before this
    # app's columns), inside IDLE. Under sids only a row with no sid of its own
    # qualifies: it takes the cookie's new sid.
    def self.legacy_row(mark, same_user, seen, user, now, revocable)
      return unless same_user && seen && seen > now - IDLE

      row = find_by(id: mark["id"], user_id: user.id)
      row unless revocable && row&.sid.present?
    end
    private_class_method :legacy_row

    # Deletes up to `batch` rows last seen before `before`. One statement on the
    # last_seen_at index.
    def self.prune!(now: Time.current, before: now - RETENTION, batch: PRUNE_BATCH)
      where(id: where(arel_table[:last_seen_at].lt(before)).order(:id).limit(batch).select(:id)).delete_all
    end

    # Prunes at most once per PRUNE_EVERY per process, from the moment a row is
    # created (a sign-in or a return after IDLE), so no host has to schedule a job.
    def self.prune_due!(now = Time.current)
      return if pruned_at && pruned_at > now - PRUNE_EVERY

      self.pruned_at = now
      prune!(now: now)
    rescue StandardError => e
      Rails.logger&.warn("[user_session] prune #{e.class}: #{e.message}")
      nil
    end
  end
end
