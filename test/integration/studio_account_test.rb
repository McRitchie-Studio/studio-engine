# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

# [unit] Studio::Account, the engine-owned account contract (database audit
# 2026-11-07, section 3), against a real ActiveRecord table: the dummy's
# in-memory sqlite, with the unique email, slug and (provider, uid) indexes
# every consumer has. Booting the dummy is only for the table.
#
# The lookup tests are the security half: a blank address must find nobody,
# because find_by(email: nil) matches every account without an email (a wallet
# or guest sign-up). Each one carries a [control] that runs the old line against
# the same rows and shows it hands over the stranger.
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :email
    t.string :name
    t.string :slug
    t.string :provider
    t.string :uid
    t.string :role
    t.timestamps
  end
  add_index :users, :email, unique: true
  add_index :users, :slug, unique: true
  add_index :users, %i[provider uid], unique: true

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

class AccountUser < ApplicationRecord
  self.table_name = "users"
  include Studio::Account

  def name_slug
    (name.presence || email.to_s.split("@").first).to_s.parameterize.presence || "user-#{SecureRandom.hex(4)}"
  end
end

# The hub and Turf: viewer + admin only.
class NarrowAccountUser < ApplicationRecord
  self.table_name = "users"
  include Studio::Account
  studio_roles %w[viewer admin]

  def name_slug = AccountUser.instance_method(:name_slug).bind_call(self)
end

class StudioAccountTest < ActiveSupport::TestCase
  def setup
    AccountUser.delete_all
    ErrorLog.delete_all
  end

  def auth(uid:, email:, name: "Google Person")
    OmniAuth::AuthHash.new(provider: "google_oauth2", uid: uid, info: { email: email, name: name })
  end

  # A wallet sign-up: no email, the row a nil lookup used to find.
  def wallet_account
    AccountUser.create!(name: "Wallet Person")
  end

  # --- the name --------------------------------------------------------------

  # REGRESSION GUARD. Inside `module Studio` a bare `User` resolves to
  # Studio::User before ::User, and the engine reads the host's User bare in
  # Studio::ErrorHandling#current_user and Studio::LinkConsumption. The audit's
  # name for this concern would have handed those the concern.
  test "the engine defines no Studio::User, so a bare User in module Studio is the host's" do
    refute Studio.const_defined?(:User, false), "a Studio::User shadows ::User inside module Studio"
  end

  # --- roles -----------------------------------------------------------------

  test "Studio::Roles is viewer, member, admin" do
    assert_equal %w[viewer member admin], Studio::Roles
    assert Studio::Roles.frozen?
  end

  test "a new account takes viewer, and admin? reads the role" do
    user = AccountUser.create!(name: "Mia")

    assert_equal "viewer", user.role
    refute user.admin?
    user.update!(role: "admin")
    assert user.admin?
  end

  test "every engine role saves; a role outside the list is refused" do
    Studio::Roles.each do |role|
      assert AccountUser.new(name: "R #{role}", role: role).valid?, "#{role} is an engine role"
    end

    user = AccountUser.new(name: "Typo", role: "amdin")
    refute user.valid?
    assert user.errors[:role].any?, "a mistyped role must not save as a quiet non-admin"
    refute AccountUser.new(name: "Old Turf", role: "user").valid?, "Turf's old spelling is not a role"
  end

  test "a host may narrow the list" do
    refute NarrowAccountUser.new(name: "Member", role: "member").valid?
    assert NarrowAccountUser.new(name: "Viewer", role: "viewer").valid?
    assert_equal %w[viewer member admin], AccountUser.studio_role_list, "narrowing one host changes no other"
  end

  test "a host may never widen the list" do
    klass = Class.new(ApplicationRecord) do
      self.table_name = "users"
      include Studio::Account
    end

    error = assert_raises(ArgumentError) { klass.studio_roles %w[viewer admin owner] }
    assert_includes error.message, "owner"
    assert_raises(ArgumentError) { klass.studio_roles [] }
  end

  test "a list without viewer defaults to its first role" do
    klass = Class.new(ApplicationRecord) do
      self.table_name = "users"
      include Studio::Account
      studio_roles %w[member admin]
    end

    assert_equal "member", klass.studio_default_role
  end

  # --- email -----------------------------------------------------------------

  test "normalizes the email: stripped, downcased, blank stored as NULL" do
    assert_equal "mia@example.com", AccountUser.create!(name: "Mia", email: "  Mia@Example.COM ").email
    assert_nil AccountUser.create!(name: "Blank", email: "   ").email
    assert_nil AccountUser.create!(name: "Empty", email: "").email, "two blank addresses must not collide"
  end

  test "display_name falls back from the name to the address" do
    assert_equal "Mia", AccountUser.new(name: "Mia").display_name
    assert_equal "mia", AccountUser.new(email: "mia@example.com").display_name
    assert_equal "User", AccountUser.new.display_name
  end

  # --- the one safe lookup ---------------------------------------------------

  test "a blank address finds nobody, even with an emailless account on file" do
    wallet_account

    [nil, "", "   "].each do |blank|
      assert_nil AccountUser.account_for_email(blank), "#{blank.inspect} found an account"
      assert_nil Studio::Account.find_by_email(AccountUser, blank)
    end
  end

  test "[control] the old find_by(email: nil) hands over the emailless account" do
    stranger = wallet_account

    assert_equal stranger, AccountUser.find_by(email: nil),
                 "the line Studio::Account replaces matches any account with no email"
  end

  test "the lookup is case-insensitive, and finds a row stored before normalizes" do
    AccountUser.insert_all!([{ name: "Legacy", slug: "legacy", email: "Legacy@Example.com", role: "viewer",
                               created_at: Time.current, updated_at: Time.current }])

    assert_equal "legacy", AccountUser.account_for_email(" LEGACY@example.COM ")&.slug
  end

  test "a model without an email column finds nobody rather than raising" do
    klass = Class.new(ApplicationRecord) { self.table_name = "error_logs" }

    assert_nil Studio::Account.find_by_email(klass, "mia@example.com")
  end

  # --- Google, through the included OmniauthUser -----------------------------

  test "from_omniauth with no email creates a new account, never the emailless stranger" do
    stranger = wallet_account

    user = AccountUser.from_omniauth(auth(uid: "g-new", email: nil), email_verified: true)

    assert_kind_of AccountUser, user
    refute_equal stranger, user
    assert_equal %w[google_oauth2 g-new], user.values_at(:provider, :uid)
    assert_nil stranger.reload.uid, "the stranger's account was not linked"
  end

  test "from_omniauth links a verified address and refuses an unverified one" do
    member = AccountUser.create!(name: "Mia", email: "mia@example.com")

    assert_equal :email_not_verified, AccountUser.from_omniauth(auth(uid: "g-mia", email: "MIA@example.com"), email_verified: false)
    assert_nil member.reload.uid
    assert_equal member, AccountUser.from_omniauth(auth(uid: "g-mia", email: "MIA@example.com"), email_verified: true)
  end

  # --- the race rescue -------------------------------------------------------

  test "race_winner finds the row by the Google id" do
    winner = AccountUser.create!(name: "Mia", provider: "google_oauth2", uid: "g-mia")

    assert_equal winner, Studio::Account.race_winner(AccountUser, provider: "google_oauth2", uid: "g-mia")
  end

  test "race_winner takes the address only when Google verified it" do
    holder = AccountUser.create!(name: "Mia", email: "mia@example.com")
    error = ActiveRecord::RecordNotUnique.new("duplicate email")

    assert_nil Studio::Account.race_winner(AccountUser, provider: "google_oauth2", uid: "g-x",
                                                        email: "mia@example.com", email_verified: false, error: error)
    assert_equal holder, Studio::Account.race_winner(AccountUser, provider: "google_oauth2", uid: "g-x",
                                                                  email: "mia@example.com", email_verified: true)
  end

  test "race_winner with no email finds nobody and logs to ErrorLog" do
    wallet_account
    error = ActiveRecord::RecordNotUnique.new("duplicate slug")

    assert_difference -> { ErrorLog.count }, 1 do
      assert_nil Studio::Account.race_winner(AccountUser, provider: "google_oauth2", uid: "g-x",
                                                          email: nil, email_verified: true, error: error)
    end
  end

  test "[control] the old voicebox rescue, find_by(email: email) with no email, hands over the stranger" do
    stranger = wallet_account
    email = nil

    assert_equal stranger, AccountUser.find_by(email: email),
                 "the rescue Studio::Account.race_winner replaces signs a nil-email race in as the stranger"
  end
end
