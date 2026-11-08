# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

require_relative "../../db/migrate/20261103120000_create_studio_user_sessions"
require_relative "../../db/migrate/20261108120000_add_device_revocation_to_studio_user_sessions"

ActiveRecord::Schema.verbose = false
ActiveRecord::Migration.verbose = false
ActiveRecord::Schema.define do
  create_table :error_logs, force: true do |t|
    t.string :slug
    t.text   :message
    t.text   :inspect
    t.text   :backtrace
    t.string :target_type
    t.bigint :target_id
    t.string :target_name
    t.string :parent_type
    t.bigint :parent_id
    t.string :parent_name
    t.timestamps
  end
end
ActiveRecord::Base.connection.drop_table(:studio_user_sessions, if_exists: true)
CreateStudioUserSessions.migrate(:up)
AddDeviceRevocationToStudioUserSessions.migrate(:up)
Studio::UserSession.reset_column_information

# [unit] Studio::UserSession's device sessions (docs/DEVICE_SESSIONS.md): the sid a
# sign-in mints, the verdict a request reads, revoke!, the legacy grace, and prune.
class UserSessionRevocationTest < ActiveSupport::TestCase
  Session = Studio::UserSession
  Person = Struct.new(:id, :is_admin) { def admin? = is_admin }

  setup do
    Session.record_in_test = true
    Session.pruned_at = nil
    Session.check_failure_logged_at = nil
    Session.delete_all
    ErrorLog.delete_all
  end

  teardown do
    Session.record_in_test = false
    Session.pruned_at = nil
    Session.check_failure_logged_at = nil
  end

  class RecordingLogger
    attr_reader :warnings

    def initialize = @warnings = []
    def warn(text) = @warnings << text
    def debug(_text) = nil
  end

  def now = Time.zone.parse("2026-11-08 12:00:00")
  def member = Person.new(7, false)

  def queries
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  test "the migration adds sid and revoked_at, and indexes sid" do
    assert Session.revocable?
    assert ActiveRecord::Base.connection.index_exists?(:studio_user_sessions, :sid)
  end

  test "a sign-in mints a random sid and marks the cookie with it" do
    store = {}
    row = Session.start!(store, member, now: now)

    assert_equal 32, row.sid.length
    assert_equal row.sid, store[Session.cookie_key]["sid"]
    refute_equal row.sid, Session.start!({}, member, now: now).sid, "each device gets its own sid"
  end

  test "a re-auth by the same user keeps the device's sid" do
    store = {}
    first = Session.start!(store, member, now: now)

    assert_nil Session.start!(store, member, now: now + 1.minute)
    assert_equal first.sid, store[Session.cookie_key]["sid"]
  end

  test "a live sid reads :live with its row, in one query" do
    store = {}
    row = Session.start!(store, member, now: now)
    verdict = nil

    assert_equal 1, queries { verdict = Session.verdict(store, now: now) }
    assert_equal [:live, row], verdict
  end

  test "revoke! ends this device only, and drops the mark" do
    phone = {}
    laptop = {}
    Session.start!(phone, member, now: now)
    Session.start!(laptop, member, now: now)
    copy = phone.deep_dup

    assert_equal 1, Session.revoke!(phone, now: now + 1.minute)
    assert_nil phone[Session.cookie_key]
    assert_equal :ended, Session.verdict(copy, now: now + 2.minutes).first, "the copy no longer signs in"
    assert_equal :live, Session.verdict(laptop, now: now + 2.minutes).first, "the other device stays signed in"
  end

  test "revoke! covers every row of the sid, so an older copy is ended too" do
    store = {}
    Session.start!(store, member, now: now)
    early_copy = store.deep_dup
    Session.track(store, member, now: now + 40.minutes) # past IDLE: a second row, same sid

    assert_equal 2, Session.where(sid: store[Session.cookie_key]["sid"]).count
    Session.revoke!(store, now: now + 41.minutes)
    assert_equal :ended, Session.verdict(early_copy, now: now + 42.minutes).first
  end

  test "a request in flight over a logout cannot write a live row for the revoked sid" do
    store = {}
    Session.start!(store, member, now: now)
    _, row = Session.verdict(store, now: now + 40.minutes) # request A reads :live, past IDLE
    Session.revoke!(store.deep_dup, now: now + 40.minutes)  # request B logs the device out
    Session.track(store, member, now: now + 40.minutes, row: row) # A's after_action starts a row

    assert_equal :ended, Session.verdict(store, now: now + 41.minutes).first
  end

  test "a sid with no row (pruned, or forged) is ended" do
    store = { Session.cookie_key => { "id" => 1, "user" => 7, "at" => now.to_i, "sid" => "nope" } }

    assert_equal :ended, Session.verdict(store, now: now).first
  end

  test "a cookie with no sid is accepted in the grace and gets one; after the grace it is ended" do
    legacy = { Session.cookie_key => { "id" => 99, "user" => 7, "at" => (now - 1.minute).to_i } }
    Session.legacy_grace_until = now + 1.day

    assert_equal :legacy, Session.verdict(legacy, now: now).first
    row = Session.track(legacy, member, now: now)
    assert row.sid.present?, "inside the throttle too: a sid-less cookie gets its sid at once"
    assert_equal row.sid, legacy[Session.cookie_key]["sid"]
    assert_equal :live, Session.verdict(legacy, now: now).first

    assert_equal :ended, Session.verdict({ Session.cookie_key => {} }, now: now + 2.days).first
  ensure
    Session.legacy_grace_until = Time.utc(2026, 12, 8)
  end

  test "a pre-sid row the mark names takes the new sid instead of a new row" do
    old = Session.create!(user_id: 7, admin: false, started_at: now - 10.minutes, last_seen_at: now - 10.minutes)
    store = { Session.cookie_key => { "id" => old.id, "user" => 7, "at" => (now - 10.minutes).to_i } }

    row = Session.track(store, member, now: now)
    assert_equal old.id, row.id
    assert_equal row.sid, old.reload.sid
    assert_equal 1, Session.count
  end

  test "track reuses the row verdict read, so it adds no read of its own" do
    store = {}
    Session.start!(store, member, now: now)
    _, row = Session.verdict(store, now: now + 6.minutes)

    assert_equal 1, queries { Session.track(store, member, now: now + 6.minutes, row: row) }, "only the touch"
    assert_equal 0, queries { Session.track(store, member, now: now + 7.minutes, row: row) }, "inside the throttle"
  end

  test "with no sid columns nothing is checked and tracking is as before" do
    connection = ActiveRecord::Base.connection
    AddDeviceRevocationToStudioUserSessions.migrate(:down)
    Session.reset_column_information
    connection.schema_cache.clear!

    store = {}
    assert_equal :off, Session.verdict(store, now: now).first
    assert_nil Session.start!(store, member, now: now)
    row = Session.track(store, member, now: now)
    assert row
    assert_nil store[Session.cookie_key]["sid"]
    assert_equal 0, Session.revoke!(store, now: now)
  ensure
    AddDeviceRevocationToStudioUserSessions.migrate(:up)
    Session.reset_column_information
    connection.schema_cache.clear!
  end

  test "under test it checks nothing unless asked, so host query budgets hold" do
    store = {}
    Session.start!(store, member, now: now)
    Session.record_in_test = false

    assert_equal 0, queries { assert_equal :off, Session.verdict(store, now: now).first }
  end

  test "a database fault answers :off, so it signs nobody out" do
    store = { Session.cookie_key => { "sid" => "x" } }
    Session.define_singleton_method(:where) { |*| raise ActiveRecord::StatementInvalid, "down" }

    assert_equal [:off, nil], Session.verdict(store, now: now)
  ensure
    Session.singleton_class.remove_method(:where)
  end

  test "prune deletes rows idle past RETENTION, at most once an hour per process" do
    stale = Session.create!(sid: "s", user_id: 7, admin: false, started_at: now - 100.days, last_seen_at: now - 91.days)
    fresh = Session.create!(sid: "f", user_id: 7, admin: false, started_at: now - 100.days, last_seen_at: now - 89.days)

    assert_equal 1, Session.prune_due!(now)
    assert_nil Session.find_by(id: stale.id)
    assert Session.find_by(id: fresh.id)

    Session.create!(sid: "t", user_id: 7, admin: false, started_at: now - 100.days, last_seen_at: now - 95.days)
    assert_nil Session.prune_due!(now + 30.minutes), "inside the hour no prune runs"
    assert_equal 1, Session.prune_due!(now + 61.minutes)
  end

  test "a sign-in prunes when due" do
    Session.create!(sid: "s", user_id: 7, admin: false, started_at: now - 100.days, last_seen_at: now - 91.days)
    Session.start!({}, member, now: now)

    assert_equal 1, Session.count
  end

  test "a plain Hash decoded from the cookie (a cable connection's read) carries its sid" do
    store = {}
    Session.start!(store, member, now: now)
    decoded = JSON.parse(store.to_json)

    assert_equal :live, Session.verdict(decoded, now: now).first
    Session.revoke!(store, now: now)
    assert_equal :ended, Session.verdict(decoded, now: now).first
  end

  # --- device-session-hardening (Carl's review of logout-ends-device-session) ---

  test "ended? is the cable check: true only for an ended sid, false for live, legacy and off" do
    store = {}
    Session.start!(store, member, now: now)
    decoded = JSON.parse(store.to_json)

    refute Session.ended?(decoded, now: now), "a live sid opens a socket"
    refute Session.ended?({}, now: now), "a sid-less cookie inside the grace opens a socket"
    Session.revoke!(store, now: now)
    assert Session.ended?(decoded, now: now), "a revoked sid is refused"
    assert Session.ended?({ Session.cookie_key.to_s => { "sid" => "forged" } }, now: now), "a sid with no row is refused"

    Session.record_in_test = false
    refute Session.ended?(decoded, now: now), "off answers false"
  end

  test "ended? never writes the store it reads" do
    store = {}
    Session.start!(store, member, now: now)
    Session.revoke!(store.dup, now: now)
    before = store.deep_dup

    assert Session.ended?(store, now: now)
    assert_equal before, store
  end

  test "a failed verdict writes one ErrorLog row, throttled per process" do
    store = { Session.cookie_key => { "sid" => "x" } }
    Session.define_singleton_method(:where) { |*| raise ActiveRecord::StatementInvalid, "down" }

    assert_equal [:off, nil], Session.verdict(store, now: now)
    assert_equal 1, ErrorLog.count
    assert_match(/down/, ErrorLog.last.message)

    Session.verdict(store, now: now + 1.minute)
    assert_equal 1, ErrorLog.count, "inside the window no second row"

    Session.verdict(store, now: now + Session::CHECK_FAILURE_LOG_EVERY + 1.second)
    assert_equal 2, ErrorLog.count, "past the window it logs again"
  ensure
    Session.singleton_class.remove_method(:where)
  end

  test "a failed ErrorLog write in the verdict still answers :off and is not retried every request" do
    store = { Session.cookie_key => { "sid" => "x" } }
    Session.define_singleton_method(:where) { |*| raise ActiveRecord::StatementInvalid, "down" }
    calls = 0
    ErrorLog.define_singleton_method(:capture!) { |*| calls += 1; raise ActiveRecord::ConnectionNotEstablished, "no db" }

    assert_equal [:off, nil], Session.verdict(store, now: now)
    assert_equal [:off, nil], Session.verdict(store, now: now + 1.minute)
    assert_equal 1, calls
  ensure
    Session.singleton_class.remove_method(:where)
    ErrorLog.singleton_class.remove_method(:capture!)
  end

  test "start! never reuses a revoked sid: a sign-in on a logged-out cookie mints a new one" do
    store = {}
    first = Session.start!(store, member, now: now)
    copy = store.deep_dup
    Session.revoke!(store, now: now + 1.minute)

    row = Session.start!(copy, member, now: now + 2.minutes)
    assert row, "a new row is written"
    refute_equal first.sid, row.sid
    assert_equal row.sid, copy[Session.cookie_key]["sid"]
    assert_equal :live, Session.verdict(copy, now: now + 2.minutes).first
  end

  test "start! does not reuse a sid with no row, or one another user's row holds" do
    forged = { Session.cookie_key => { "user" => member.id, "sid" => "forged" } }
    row = Session.start!(forged, member, now: now)
    refute_equal "forged", row.sid

    other = Session.start!({}, Person.new(8, false), now: now)
    borrowed = { Session.cookie_key => { "user" => member.id, "sid" => other.sid } }
    mine = Session.start!(borrowed, member, now: now)
    refute_equal other.sid, mine.sid
  end

  test "start! keeps a live sid of the same user in one query" do
    store = {}
    first = Session.start!(store, member, now: now)

    assert_equal 1, queries { assert_nil Session.start!(store, member, now: now + 1.minute) }
    assert_equal first.sid, store[Session.cookie_key]["sid"]
  end

  test "the boot warns when the device-session columns are missing, and is quiet when whole" do
    connection = ActiveRecord::Base.connection
    logger = RecordingLogger.new
    assert_equal [], Studio::HostSchema.device_session_check!(connection: connection, mode: :raise, logger: logger)
    assert_empty logger.warnings

    AddDeviceRevocationToStudioUserSessions.migrate(:down)
    connection.schema_cache.clear!
    missing = Studio::HostSchema.device_session_check!(connection: connection, mode: :raise, logger: logger)
    assert_equal %w[sid revoked_at], missing, "it warns and never raises, even in :raise mode"
    assert_match(/NOT checked/, logger.warnings.last)

    assert_equal [], Studio::HostSchema.device_session_check!(connection: connection, mode: false, logger: logger)
  ensure
    AddDeviceRevocationToStudioUserSessions.migrate(:up)
    Session.reset_column_information
    connection.schema_cache.clear!
  end

  test "the boot warns when the table itself is missing, and skips an unreachable database" do
    logger = RecordingLogger.new
    absent = Object.new
    def absent.table_exists?(_) = false
    assert_equal %w[sid revoked_at], Studio::HostSchema.device_session_check!(connection: absent, mode: :log, logger: logger)
    assert_equal 1, logger.warnings.size

    broken = Object.new
    def broken.table_exists?(_) = raise(ActiveRecord::ConnectionNotEstablished, "no database")
    assert_equal [], Studio::HostSchema.device_session_check!(connection: broken, mode: :log, logger: logger)
  end
end
