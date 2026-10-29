# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

# [unit] Studio::OmniauthUser, the engine's default User.from_omniauth, against
# a real ActiveRecord table (the dummy's in-memory sqlite) with the unique email
# and slug indexes every consumer has. Booting the dummy is only for the table;
# no request is made.
#
# The User here is the one docs/USER_CONTRACT.md used to show: Sluggable with
# name_slug = name.parameterize. That is the shape whose second "Mia" raised
# RecordNotUnique on the slug index and signed nobody in (Carl, 2026-10-29,
# voicebox PR #7).
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :email
    t.string :name
    t.string :slug
    t.string :provider
    t.string :uid
    t.timestamps
  end
  add_index :users, :email, unique: true
  add_index :users, :slug, unique: true

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
  include Sluggable

  def name_slug
    (name.presence || email.to_s.split("@").first).to_s.parameterize
  end
end

# A host that includes the concern gets User.from_omniauth under its own name.
class ConcernUser < ApplicationRecord
  self.table_name = "users"
  include Sluggable
  include Studio::OmniauthUser

  def name_slug
    name.to_s.parameterize
  end
end

# A host whose slug is its own, and always the same: the fallback cannot help
# it, so the collision is logged and the sign-in answers nil.
class StubbornSlugUser < ApplicationRecord
  self.table_name = "users"
  include Sluggable

  def name_slug
    "always-this"
  end

  private

  def set_slug
    self.slug = "always-this"
  end
end

class OmniauthUserDefaultTest < ActiveSupport::TestCase
  def setup
    User.delete_all
    ErrorLog.delete_all
  end

  def auth(uid:, email:, name: "Google Person")
    OmniAuth::AuthHash.new(provider: "google_oauth2", uid: uid, info: { email: email, name: name })
  end

  def from_omniauth(hash, email_verified: true, model: User)
    Studio::OmniauthUser.resolve(model, hash, email_verified: email_verified)
  end

  test "finds the account already holding the Google id" do
    member = User.create!(email: "mia@example.com", name: "Mia", provider: "google_oauth2", uid: "g-mia")

    assert_equal member, from_omniauth(auth(uid: "g-mia", email: "changed@example.com"), email_verified: false)
  end

  test "links a verified address to the existing account, case-insensitively" do
    member = User.create!(email: "Mia@Example.com", name: "Mia")

    assert_no_difference -> { User.count } do
      assert_equal member, from_omniauth(auth(uid: "g-mia", email: "MIA@example.COM"))
    end
    assert_equal %w[google_oauth2 g-mia], member.reload.values_at(:provider, :uid)
  end

  test "refuses an unverified address that matches an account" do
    member = User.create!(email: "mia@example.com", name: "Mia")

    assert_equal :email_not_verified, from_omniauth(auth(uid: "g-mia", email: "mia@example.com"), email_verified: false)
    assert_nil member.reload.uid, "an unverified address links nothing"
  end

  test "creates a new account with the address downcased" do
    user = nil
    assert_difference -> { User.count }, 1 do
      user = from_omniauth(auth(uid: "g-new", email: "  New.Person@Example.COM ", name: "New Person"))
    end

    assert_kind_of User, user
    assert user.persisted?
    assert_equal "new.person@example.com", user.email
    assert_equal "New Person", user.name
    assert_equal "new-person", user.slug
    assert_equal %w[google_oauth2 g-new], user.values_at(:provider, :uid)
  end

  test "a new account named like an existing one gets user-<id>, not a failed sign-in" do
    mia = User.create!(email: "mia@example.com", name: "Mia")
    assert_equal "mia", mia.slug

    other = from_omniauth(auth(uid: "g-other-mia", email: "another.mia@example.com", name: "Mia"))

    assert_kind_of User, other, "the second Mia signs in"
    assert other.persisted?
    assert_equal "user-#{other.id}", other.reload.slug
    assert_equal "mia", mia.reload.slug
  end

  test "a name that parameterizes to nothing gets user-<id> too" do
    user = from_omniauth(auth(uid: "g-emoji", email: nil, name: "!!!"))

    assert_kind_of User, user
    assert_equal "user-#{user.id}", user.reload.slug
  end

  test "a collision with nobody to find is logged and answers nil" do
    StubbornSlugUser.create!(email: "first@example.com", name: "First")

    result = nil
    assert_difference -> { ErrorLog.count }, 1 do
      result = from_omniauth(auth(uid: "g-second", email: "second@example.com"), model: StubbornSlugUser)
    end

    assert_nil result
    assert_match(/UNIQUE|unique/i, ErrorLog.last.message)
  end

  # A RACE: the address was free when step 2 looked and taken by the insert.
  # Simulated by making step 2's lookup miss once. The rescue may hand back the
  # row holding the address only when Google verified it, the same rule step 2
  # applies; otherwise an unverified address would take over someone's account.
  def with_first_email_lookup_missing
    original = Studio::OmniauthUser.method(:find_by_email)
    calls = 0
    Studio::OmniauthUser.define_singleton_method(:find_by_email) do |model, email|
      calls += 1
      calls == 1 ? nil : original.call(model, email)
    end
    yield
  ensure
    # The stub REPLACED the method on the same singleton class, so it is put
    # back rather than removed (removing would delete the original too).
    Studio::OmniauthUser.define_singleton_method(:find_by_email, original)
  end

  test "a raced insert returns the address's row only for a verified address" do
    member = User.create!(email: "mia@example.com", name: "Mia")

    with_first_email_lookup_missing do
      assert_nil from_omniauth(auth(uid: "g-race", email: "mia@example.com", name: "Other"), email_verified: false),
                 "an unverified address must not be handed someone else's row"
    end
    assert_nil member.reload.uid

    with_first_email_lookup_missing do
      assert_equal member, from_omniauth(auth(uid: "g-race", email: "mia@example.com", name: "Other"), email_verified: true)
    end
  end

  test "a missing uid signs nobody in" do
    assert_nil from_omniauth(OmniAuth::AuthHash.new(provider: "google_oauth2", uid: nil, info: { email: "x@example.com" }))
  end

  test "the concern gives the host User.from_omniauth, and a host's own definition overrides it" do
    assert ConcernUser.respond_to?(:from_omniauth)
    user = ConcernUser.from_omniauth(auth(uid: "g-concern", email: "c@example.com", name: "Concern"), email_verified: true)
    assert_kind_of ConcernUser, user

    overriding = Class.new(ConcernUser) do
      def self.from_omniauth(_auth, email_verified: false)
        :the_hosts_own
      end
    end
    assert_equal :the_hosts_own, Studio::OmniauthUser.resolve(overriding, auth(uid: "g", email: "g@example.com"))
  end
end
