# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

# [integration] The sign-in write path leaves a durable, attributable record when
# it fails — house discipline: every write path rescues into an ErrorLog.
#
# verify_email_ownership does `user.update!(email_verified_at: …)` on the way
# through a magic-link consume. A consuming app with an extra User validation
# turns that routine write into a raise, and two of its three call sites were
# UNWRAPPED — so the visitor got a 500 with nothing in ErrorLog to explain it.
# sign_in_existing is the worse of the two: it establishes the session BEFORE
# the write, so the failure lands on someone who is, in fact, signed in.
#
# This lives in its OWN FILE on purpose. It arms a User validation that fails
# every verification write, and Minitest runs a file's classes in one process —
# so arming it anywhere near the other magic-link suites would break them
# instead. (Learned the hard way one commit ago, in the opposite direction.)
ActionDispatch::IntegrationTest.app = Rails.application

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :studio_links, force: true do |t|
    t.string   :token, null: false
    t.string   :kind, null: false
    t.string   :linkable_type
    t.bigint   :linkable_id
    t.json     :metadata
    t.datetime :expires_at
    t.datetime :consumed_at
    t.timestamps
  end
  add_index :studio_links, :token, unique: true

  create_table :users, force: true do |t|
    t.string   :email, null: false
    t.string   :name
    t.string   :session_token
    t.datetime :email_verified_at
    t.string   :provider
    t.string   :uid
    t.timestamps
  end
  add_index :users, :email, unique: true

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

class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
end

# Stands in for a consumer app that validates its User more strictly than the
# engine does. The flag keeps the failure OFF for setup writes and ON only for
# the write under test.
class User < ApplicationRecord
  cattr_accessor :reject_verification, default: false

  validate :maybe_reject_verification

  def display_name
    name.presence || email.split("@").first
  end

  private

  def maybe_reject_verification
    return unless self.class.reject_verification && email_verified_at_changed?

    errors.add(:base, "this app refuses the verification write")
  end
end

class MagicLinkErrorLoggingTest < ActionDispatch::IntegrationTest
  EMAIL = "owner@example.com"

  def setup
    Studio::Link.delete_all
    User.delete_all
    ErrorLog.delete_all
    User.reject_verification = false
    @user = User.create!(email: EMAIL, name: "Owner")
  end

  def teardown
    User.reject_verification = false
  end

  test "a failed verification write on sign-in is recorded, not swallowed" do
    link = Studio::Link.create_magic_link(email: EMAIL)
    User.reject_verification = true

    assert_difference -> { ErrorLog.count }, 1 do
      assert_raises(ActiveRecord::RecordInvalid) { post "/l/#{link.token}" }
    end

    log = ErrorLog.order(:id).last
    assert_equal "User", log.target_type, "the row must name WHO the write was for"
    assert_equal @user.id, log.target_id
  end

  # The re-click path. Sharper than the one above, because :continue exists to be
  # invisible — an unlogged 500 here would be the loudest thing about it.
  test "a failed verification write on a re-click is recorded too" do
    post "/l/#{Studio::Link.create_magic_link(email: EMAIL).token}"
    assert_equal @user.id, session[:user_id], "test setup: expected a live session"

    # Put the account back to unverified WITHOUT tripping the validation, so the
    # next click reaches the write again.
    @user.update_column(:email_verified_at, nil)
    User.reject_verification = true

    assert_difference -> { ErrorLog.count }, 1 do
      assert_raises(ActiveRecord::RecordInvalid) do
        post "/l/#{Studio::Link.create_magic_link(email: EMAIL).token}"
      end
    end
  end

  # The happy path writes NO ErrorLog — otherwise the two assertions above would
  # pass on a rescue that fires for everyone.
  test "an ordinary sign-in records nothing" do
    assert_no_difference -> { ErrorLog.count } do
      post "/l/#{Studio::Link.create_magic_link(email: EMAIL).token}"
    end

    assert_equal @user.id, session[:user_id]
    refute_nil @user.reload.email_verified_at
  end
end
