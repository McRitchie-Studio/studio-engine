# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "active_support/testing/time_helpers"
require "nokogiri"

# [unit] + [integration] The daily application health report against a real
# database: the counts it gathers for the window, the email it renders, and
# the job's three refusals (no recipient, QA, a failure) — the rules a host
# relies on when it turns the report on. Window arithmetic and recipient
# parsing are test/lib/studio/health_report_test.rb.
ActiveJob::Base.queue_adapter = :inline
ActionMailer::Base.delivery_method = :test

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :email, null: false
    t.string :name
    t.timestamps
  end

  # Stands in for a host's contact model, which the engine does not own.
  create_table :inquiries, force: true do |t|
    t.string :email
    t.text   :body
    t.timestamps
  end

  create_table :error_logs, force: true do |t|
    t.string :slug
    t.text   :message
    t.text   :inspect
    t.text   :backtrace
    t.string :target_type
    t.bigint :target_id
    t.string :parent_type
    t.bigint :parent_id
    t.timestamps
  end
end

class User < ApplicationRecord
  def display_name = name.presence || email
end

class Inquiry < ApplicationRecord; end

class HealthReportTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  # 07:00:05 MDT on Oct 13: the window is Oct 12 07:00 to Oct 13 07:00 Denver.
  NOW          = Time.utc(2026, 10, 13, 13, 0, 5)
  INSIDE       = Time.utc(2026, 10, 13, 2)   # Oct 12, 8 PM MDT
  BEFORE       = Time.utc(2026, 10, 12, 12, 59, 59)
  WINDOW_END   = Time.utc(2026, 10, 13, 13)
  SETTINGS     = %i[health_report_to health_report_signups health_report_contacts health_report_zone health_report_hour app_name].freeze

  def setup
    @saved = SETTINGS.to_h { |k| [k, Studio.public_send(k)] }
    @saved_env = ENV.fetch("STUDIO_HEALTH_REPORT_TO", nil)
    @saved_qa = ENV.fetch("QA_ENV", nil)
    ENV.delete("STUDIO_HEALTH_REPORT_TO")
    ENV.delete("QA_ENV")
    Studio.app_name = "Dummy"
    ActionMailer::Base.deliveries.clear
    [User, Inquiry, ErrorLog].each(&:delete_all)
  end

  def teardown
    @saved.each { |k, v| Studio.public_send(:"#{k}=", v) }
    @saved_env ? ENV["STUDIO_HEALTH_REPORT_TO"] = @saved_env : ENV.delete("STUDIO_HEALTH_REPORT_TO")
    @saved_qa ? ENV["QA_ENV"] = @saved_qa : ENV.delete("QA_ENV")
  end

  def user(email, at:, name: nil) = User.create!(email: email, name: name, created_at: at)

  def error(klass, message, at:)
    ErrorLog.create!(message: message, inspect: "#<#{klass}: #{message}>", created_at: at)
  end

  def report = Studio::HealthReport.build(window: Studio::HealthReport.window(NOW))

  def run_job = Studio::HealthReportJob.perform_now(NOW)

  def body_text(mail) = Nokogiri::HTML(mail.html_part.body.to_s).text.squish

  # --- [unit] what it counts --------------------------------------------------

  test "[unit] signups count the host's users created inside the window, newest first" do
    user("old@example.test", at: BEFORE)
    user("ann@example.test", name: "Ann", at: INSIDE)
    user("bo@example.test", at: INSIDE + 60)
    user("late@example.test", at: WINDOW_END) # 07:00:00 belongs to tomorrow

    signups = report.signups

    assert_equal 2, signups.count
    assert_equal ["bo@example.test", "Ann <ann@example.test>"], signups.items
  end

  test "[unit] the signup list is capped but the count is whole" do
    12.times { |i| user("u#{i}@example.test", at: INSIDE + i) }

    assert_equal 12, report.signups.count
    assert_equal Studio::HealthReport::LISTED, report.signups.items.size
    assert_equal 2, report.signups.more
  end

  test "[unit] errors are grouped by class and message with counts and first and last seen" do
    3.times { |i| error("Net::ReadTimeout", "ESPN feed", at: INSIDE + (i * 600)) }
    error("NoMethodError", "undefined method `slug' for nil", at: INSIDE + 30)
    error("Net::ReadTimeout", "ESPN feed", at: BEFORE)
    ErrorLog.create!(message: "hand-written row", created_at: INSIDE) # no inspect

    r = report
    timeout = r.error_groups.first

    assert_equal 5, r.errors.count
    assert_equal 3, r.error_kinds
    assert_equal ["Net::ReadTimeout", "ESPN feed", 3], [timeout.error_class, timeout.message, timeout.count]
    assert_equal INSIDE, timeout.first_seen
    assert_equal INSIDE + 1200, timeout.last_seen
    assert_includes r.error_groups.map(&:error_class), "NoMethodError"
    assert_includes r.error_groups.map(&:message), "hand-written row"
  end

  test "[unit] contacts are omitted unless the host names a source, then counted" do
    Inquiry.create!(email: "lead@example.test", created_at: INSIDE)
    Inquiry.create!(email: "stale@example.test", created_at: BEFORE)

    assert_nil report.contacts

    Studio.health_report_contacts = ->(window) { Inquiry.where(created_at: window) }

    assert_equal 1, report.contacts.count
    assert_equal ["lead@example.test"], report.contacts.items
  end

  test "[unit] a host whose accounts are not User points signups at its own model" do
    Inquiry.create!(email: "member@example.test", created_at: INSIDE)
    Studio.health_report_signups = ->(window) { Inquiry.where(created_at: window).count }

    assert_equal 1, report.signups.count
    assert_empty report.signups.items

    Studio.health_report_signups = nil
    assert_nil report.signups
  end

  test "[unit] a source that raises marks its section unread, leaves a receipt, and spares the rest" do
    error("RuntimeError", "real error", at: INSIDE)
    Studio.health_report_contacts = ->(_window) { raise IOError, "contacts db down" }

    r = nil
    assert_difference -> { ErrorLog.count }, 1 do
      r = report
    end

    assert r.contacts.failed?
    assert_equal "IOError", r.contacts.failure
    assert_equal 1, r.errors.count
    refute r.quiet?
  end

  test "[unit] a day with nothing in it is quiet" do
    user("old@example.test", at: BEFORE)

    assert report.quiet?
    assert_equal "Dummy health: all clear", report.subject
  end

  # --- [integration] the email ------------------------------------------------

  test "[integration] the mailer renders signups, grouped errors and contacts" do
    Studio.health_report_contacts = ->(window) { Inquiry.where(created_at: window) }
    user("ann@example.test", name: "Ann", at: INSIDE)
    2.times { error("Net::ReadTimeout", "ESPN feed", at: INSIDE) }
    Inquiry.create!(email: "lead@example.test", created_at: INSIDE)

    mail = Studio::HealthReportMailer.daily(WINDOW_END.iso8601, "ops@example.test")
    text = body_text(mail)

    assert_equal ["ops@example.test"], mail.to
    assert_equal "Dummy health: 1 signup, 2 errors, 1 contact message", mail.subject
    assert_includes text, "Oct 12, 7:00 AM to Oct 13, 7:00 AM MDT"
    assert_includes text, "Ann <ann@example.test>"
    assert_includes text, "Net::ReadTimeout"
    assert_includes text, "first Oct 12, 8:00 PM"
    assert_includes text, "lead@example.test"
    refute_includes text, "All clear"
    assert_includes mail.text_part.body.to_s, "2x Net::ReadTimeout: ESPN feed"
    # A count-only section (errors list groups, not rows) has no "and N more" tail.
    refute_includes mail.text_part.body.to_s, "more"
  end

  test "[integration] a quiet day sends one short all-clear line, never an empty email" do
    mail = Studio::HealthReportMailer.daily(WINDOW_END.iso8601, "ops@example.test")

    assert_equal "Dummy health: all clear", mail.subject
    assert_includes body_text(mail), "All clear: no signups or errors in the last day."
    assert_includes mail.text_part.body.to_s, "All clear: no signups or errors in the last day."
  end

  test "[integration] the job sends one report to the configured recipient" do
    Studio.health_report_to = "ops@example.test, cto@example.test"
    error("RuntimeError", "boom", at: INSIDE)

    run_job

    assert_equal 1, ActionMailer::Base.deliveries.size
    mail = ActionMailer::Base.deliveries.last
    assert_equal %w[ops@example.test cto@example.test], mail.to
    assert_equal "Dummy health: 1 error", mail.subject
  end

  test "[integration] the env names the recipient when the app config does not" do
    ENV["STUDIO_HEALTH_REPORT_TO"] = "env@example.test"

    run_job

    assert_equal [["env@example.test"]], ActionMailer::Base.deliveries.map(&:to)
  end

  test "[integration] no recipient configured means no email at all" do
    error("RuntimeError", "boom", at: INSIDE)

    run_job

    assert_empty ActionMailer::Base.deliveries
  end

  test "[integration] QA never sends, even with a recipient" do
    Studio.health_report_to = "ops@example.test"
    ENV["QA_ENV"] = "true"

    run_job

    assert_empty ActionMailer::Base.deliveries
  end

  test "[integration] a send failure leaves an ErrorLog receipt and does not raise" do
    Studio.health_report_to = "ops@example.test"

    # Hand-rolled: Minitest 6 dropped minitest/mock, so there is no .stub.
    original = Studio::Email.method(:deliver)
    Studio::Email.define_singleton_method(:deliver) { |*, **| raise IOError, "outbox is down" }
    begin
      assert_difference -> { ErrorLog.count }, 1 do
        run_job
      end
    ensure
      Studio::Email.define_singleton_method(:deliver, original)
    end
  end

  test "[integration] the job is scheduled by nobody: the engine registers no recurring entry" do
    engine_root = Studio::Engine.root
    schedules = Dir[engine_root.join("config/**/*.yml")].select { |f| File.read(f).include?("HealthReportJob") }

    assert_empty schedules, "turning the report on is each host's call, not the engine's"
  end
end
