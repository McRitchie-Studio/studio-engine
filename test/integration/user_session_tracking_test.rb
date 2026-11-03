# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table(:users, force: true) { |t| t.string :email; t.string :role; t.string :session_token; t.timestamps }
  create_table :studio_user_sessions, force: true do |t|
    t.bigint :user_id, null: false
    t.boolean :admin, null: false, default: false
    t.datetime :started_at, null: false
    t.datetime :last_seen_at, null: false
    t.timestamps
  end
end

# [unit] Studio::UserSession.track: when a row starts, when it is reused, and that a
# request inside the throttle runs no query.
class UserSessionTrackingTest < ActiveSupport::TestCase
  Session = Studio::UserSession
  Person = Struct.new(:id, :is_admin) { def admin? = is_admin }

  setup do

    Session.record_in_test = true

    Session.delete_all

  end


  teardown { Session.record_in_test = false }

  def now = Time.zone.parse("2026-11-03 12:00:00")
  def member = Person.new(7, false)

  test "the first request starts a row and marks the cookie" do
    store = {}
    row = Session.track(store, member, now: now)

    assert_equal 7, row.user_id
    refute row.admin
    assert_equal now, row.started_at
    assert_equal row.id, store[Session.cookie_key]["id"]
  end

  test "an admin's row says so" do
    assert Session.track({}, Person.new(1, true), now: now).admin
  end

  test "inside the throttle nothing is written and no query runs" do
    store = {}
    Session.track(store, member, now: now)
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      assert_nil Session.track(store, member, now: now + 4.minutes)
    end

    assert_equal 0, queries
  end

  test "past the throttle the same row moves; past idle a new one starts" do
    store = {}
    first = Session.track(store, member, now: now)

    moved = Session.track(store, member, now: now + 6.minutes)
    assert_equal first.id, moved.id
    assert_equal now + 6.minutes, moved.reload.last_seen_at

    fresh = Session.track(store, member, now: now + 40.minutes)
    refute_equal first.id, fresh.id
    assert_equal 2, Session.count
  end

  test "a different user on the same browser starts a row" do
    store = {}
    first = Session.track(store, member, now: now)
    other = Session.track(store, Person.new(8, false), now: now + 1.minute)

    refute_equal first.id, other.id
    assert_equal 8, other.user_id
  end

  test "two apps on one shared cookie keep separate marks" do
    store = {}
    hub = Studio.session_key
    Session.track(store, member, now: now)
    Studio.session_key = :other_app_user_id
    assert Session.track(store, member, now: now + 1.minute), "the other app's mark does not throttle this one"
    Studio.session_key = hub
    assert_nil Session.track(store, member, now: now + 2.minutes), "this app's own mark survives"
  ensure
    Studio.session_key = hub
  end

  test "a cookie that went through JSON still reads" do
    store = {}
    Session.track(store, member, now: now)
    store[Session.cookie_key] = JSON.parse(store[Session.cookie_key].to_json)

    assert_nil Session.track(store, member, now: now + 1.minute)
  end

  test "under test it records nothing unless asked, so host query budgets hold" do

    Session.record_in_test = false


    assert_nil Session.track({}, member, now: now)

    assert_equal 0, Session.count

  end


  test "no user records nothing, and a failure never raises" do
    assert_nil Session.track({}, nil, now: now)

    broken = Object.new
    def broken.[](*) = raise("cookie jar broke")
    assert_nil Session.track(broken, member, now: now)
  end

  test "an app without the table records nothing and serves on" do
    ActiveRecord::Base.connection.drop_table(:studio_user_sessions)
    Session.reset_column_information
    ActiveRecord::Base.connection.schema_cache.clear!

    assert_nil Session.track({}, member, now: now)
  ensure
    ActiveRecord::Base.connection.create_table :studio_user_sessions, force: true do |t|
      t.bigint :user_id, null: false
      t.boolean :admin, null: false, default: false
      t.datetime :started_at, null: false
      t.datetime :last_seen_at, null: false
      t.timestamps
    end
    Session.reset_column_information
  end
end
