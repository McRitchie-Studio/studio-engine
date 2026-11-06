# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "stringio"

# [unit] Studio::ErrorHandling#rescue_and_log writes exactly ONE ErrorLog row
# per failure, whatever it is handed as a target.
#
# THE DEFECT. rescue_and_log assigned `error_log.target = target` and then
# `error_log.save!`. ErrorLog `belongs_to :target`, and a belongs_to autosaves a
# NEW record. So with an unsaved target (a User being signed up) the logger ran
# the failing save a second time, inside the logger. That second raise escaped
# before `@_error_logged` was set, so the catch-all logged the same failure
# again: two identical rows for one error, and the original exception replaced
# by the logger's.
#
# The second half is the logging path's own failure: when the ErrorLog write
# itself raises, the original exception must still reach the caller, and the
# failure must still reach Rails.logger.
#
# This lives in its OWN FILE: it arms raises on User#save and ErrorLog.capture!,
# and Minitest runs a file's classes in one process.
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string   :email, null: false
    t.string   :name
    t.string   :session_token
    t.datetime :email_verified_at
    t.string   :provider
    t.string   :uid
    t.timestamps
  end

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

# A host User whose save fails with a NON-validation error while armed, the way
# a missing column, a dropped table or a lost connection fails.
class User < ApplicationRecord
  cattr_accessor :explode_on_save, default: false
  cattr_accessor :save_attempts, default: 0

  before_save do
    self.class.save_attempts += 1
    raise ActiveRecord::StatementInvalid, "lab: the users table is gone" if self.class.explode_on_save
  end

  def display_name
    name.presence || email.split("@").first
  end
end

class RescueAndLogTargetTest < ActiveSupport::TestCase
  class ProbeController < ActionController::Base
    include Studio::ErrorHandling

    public :rescue_and_log
  end

  def setup
    ErrorLog.delete_all
    User.delete_all
    User.explode_on_save = false
    User.save_attempts = 0
    @controller = ProbeController.new
  end

  def teardown
    User.explode_on_save = false
    User.save_attempts = 0
  end

  test "an unsaved target that fails to save writes exactly one ErrorLog row" do
    user = User.new(email: "new@example.com")
    User.explode_on_save = true

    error = assert_raises(ActiveRecord::StatementInvalid) do
      @controller.rescue_and_log(target: user) { user.save! }
    end
    # The request's catch-all sees the same exception next. It must not log again.
    assert_raises(ActiveRecord::StatementInvalid) { @controller.rescue_with_handler(error) }

    assert_equal ["lab: the users table is gone"], ErrorLog.pluck(:message),
      "one failure, one row: the catch-all must find it already logged"
    assert_equal 1, User.save_attempts, "the logger must not run the failing save a second time"
    assert user.new_record?
  end

  test "an unsaved target is named on the row but not linked to it" do
    user = User.new(email: "new@example.com")

    assert_raises(IOError) do
      @controller.rescue_and_log(target: user) { raise IOError, "lab: the mail transport refused" }
    end

    log = ErrorLog.sole
    assert_nil log.target_id, "an unsaved record has no id to link"
    assert_nil log.target_type
    assert_equal "unsaved User", log.target_name
    assert_equal 0, User.count, "logging the failure must not create the account"
    assert_equal 0, User.save_attempts
  end

  # The hub's model-pricing page logs an unsaved ModelRateOverride and reads the
  # model name back from target_name: a slug, when the record has one, wins.
  test "an unsaved target with a slug is named by its slug" do
    user = User.new(email: "new@example.com")
    user.define_singleton_method(:slug) { "claude-opus-4-8" }

    assert_raises(IOError) do
      @controller.rescue_and_log(target: user) { raise IOError, "lab: boom" }
    end

    log = ErrorLog.sole
    assert_equal "claude-opus-4-8", log.target_name
    assert_nil log.target_id
    assert_equal 0, User.count
  end

  test "a saved target is still linked to the row" do
    user = User.create!(email: "known@example.com")

    assert_raises(IOError) do
      @controller.rescue_and_log(target: user) { raise IOError, "lab: boom" }
    end

    log = ErrorLog.sole
    assert_equal ["User", user.id], [log.target_type, log.target_id]
  end

  test "when the ErrorLog write itself fails, the original error surfaces and Rails.logger records it" do
    prior_logger = Rails.logger
    lines = arm_failing_capture

    error = assert_raises(IOError) do
      @controller.rescue_and_log { raise IOError, "lab: the mail transport refused" }
    end

    assert_equal "lab: the mail transport refused", error.message, "the logger's failure must not mask the original"
    assert_match(/IOError: lab: the mail transport refused/, lines.string)
    assert_match(/lab: error_logs is gone/, lines.string)
  ensure
    restore_capture(prior_logger)
  end

  test "when the catch-all cannot write its row, the original error surfaces and Rails.logger records it" do
    prior_logger = Rails.logger
    lines = arm_failing_capture

    # Test env re-raises after logging; the raise must be the ORIGINAL error.
    error = assert_raises(ArgumentError) { @controller.rescue_with_handler(ArgumentError.new("lab: boom")) }

    assert_equal "lab: boom", error.message
    assert_match(/ArgumentError: lab: boom/, lines.string)
    assert_match(/lab: error_logs is gone/, lines.string)
  ensure
    restore_capture(prior_logger)
  end

  private

  def arm_failing_capture
    lines = StringIO.new
    Rails.logger = ActiveSupport::Logger.new(lines)
    ErrorLog.singleton_class.alias_method(:__lab_capture!, :capture!)
    ErrorLog.define_singleton_method(:capture!) { |_e| raise ActiveRecord::StatementInvalid, "lab: error_logs is gone" }
    lines
  end

  def restore_capture(prior_logger)
    Rails.logger = prior_logger
    return unless ErrorLog.singleton_class.method_defined?(:__lab_capture!)

    ErrorLog.singleton_class.alias_method(:capture!, :__lab_capture!)
    ErrorLog.singleton_class.remove_method(:__lab_capture!)
  end
end
