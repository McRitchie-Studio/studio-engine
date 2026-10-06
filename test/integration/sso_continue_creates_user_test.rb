# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

# [integration] POST /sso_continue — the "Continue as …" button a visitor signed in
# on a sibling app presses to land here. When no local User has that email yet, the
# engine CREATES one (SessionsController#authenticate_sso_user!).
#
# The bug this pins: the create passed `password: SecureRandom.hex(16)`
# unconditionally. Every consumer now runs passwordless (no has_secure_password, so
# no `password=`), and on those apps User.new raised ActiveModel::UnknownAttributeError
# — which sso_continue rescues into an ErrorLog and a redirect to /login with
# "Could not continue session." SSO sign-up failed for every new visitor, silently.
#
# Both host shapes are driven through the real router → controller → session:
#
#   * a PASSWORDLESS User (no `password=`): the user is created, signed in, and
#     no ErrorLog is written;
#   * a PASSWORD User (answers `password=` and requires one on create, the contract
#     has_secure_password imposes): still created, so the fix does not trade one
#     broken host shape for the other.
#
# The password double is hand-rolled rather than `has_secure_password` because
# that macro requires bcrypt, which is not in this gem's bundle; the double carries
# exactly the two facts the engine depends on — a `password=` writer and a
# presence validation on create.
ActionDispatch::IntegrationTest.app = Rails.application

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :email, null: false
    t.string :name
    t.string :provider
    t.string :uid
    t.string :session_token
    t.timestamps
  end
  add_index :users, :email, unique: true

  # sso_continue's rescue logs here; the suite reads it to prove nothing failed.
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

class ApplicationController < ActionController::Base
  include Studio::ErrorHandling

  before_action :verify_session_token
end

# A passwordless host: what the hub, turf-monster and every other consumer are now.
class PasswordlessUser < ApplicationRecord
  self.table_name = "users"

  def display_name = name.presence || email.to_s.split("@").first
end

# A password host: answers `password=` and refuses to create without one.
class PasswordUser < ApplicationRecord
  self.table_name = "users"

  attr_accessor :password

  validates :password, presence: true, on: :create

  def authenticate(candidate) = candidate == password && self
  def display_name = name.presence || email.to_s.split("@").first
end

# Seeds the cross-app SSO awareness keys the way a sibling app's set_app_session
# leaves them in the shared cookie: an email, a name, and a source that is NOT
# this app (sso_user_available? requires that).
class TestSsoSeedsController < ActionController::Base
  def create
    session[:sso_email]    = params[:email]
    session[:sso_name]     = "Sibling Visitor"
    session[:sso_provider] = "google_oauth2"
    session[:sso_uid]      = "uid-123"
    session[:sso_source]   = "Some Sibling App"
    head :ok
  end
end

Rails.application.routes.append do
  post "test_sso_seed", to: "test_sso_seeds#create"
end
Rails.application.reload_routes!

class SsoContinueCreatesUserTest < ActionDispatch::IntegrationTest
  EMAIL = "new-visitor@example.com"

  def setup
    @original_user = Object.const_defined?(:User, false) ? Object.const_get(:User) : nil
    @original_configure = Studio.configure_sso_user
    ErrorLog.delete_all
    PasswordlessUser.delete_all
  end

  def teardown
    Object.send(:remove_const, :User) if Object.const_defined?(:User, false)
    Object.const_set(:User, @original_user) if @original_user
    Studio.configure_sso_user = @original_configure
  end

  test "a passwordless app creates and signs in the SSO user" do
    use_user_class(PasswordlessUser)

    continue_as(EMAIL)

    user = PasswordlessUser.find_by(email: EMAIL)
    assert user, "SSO sign-up must create the user on a passwordless app; " \
                 "error logged: #{ErrorLog.last&.message.inspect}"
    assert_equal "Sibling Visitor", user.name
    assert_equal "google_oauth2", user.provider
    assert_equal "uid-123", user.uid
    assert_equal 0, ErrorLog.count, "a successful SSO sign-up writes no ErrorLog"
    assert_redirected_to "/"
    assert_equal user.id, session[Studio.session_key], "the new user is signed in"
  end

  test "a password app still creates the SSO user, with a password it never reveals" do
    use_user_class(PasswordUser)
    seen = nil
    Studio.configure_sso_user = ->(user) { seen = user.password }

    continue_as(EMAIL)

    user = PasswordUser.find_by(email: EMAIL)
    assert user, "SSO sign-up must still create the user on a password app; " \
                 "error logged: #{ErrorLog.last&.message.inspect}"
    assert_equal 0, ErrorLog.count
    assert_match(/\A\h{32}\z/, seen.to_s,
                 "a password app gets a random placeholder, set before configure_sso_user runs")
    assert_equal user.id, session[Studio.session_key]
  end

  test "an existing user is signed in, not re-created" do
    use_user_class(PasswordlessUser)
    existing = PasswordlessUser.create!(email: EMAIL, name: "Already Here")

    continue_as(EMAIL)

    assert_equal 1, PasswordlessUser.where(email: EMAIL).count
    assert_equal existing.id, session[Studio.session_key]
    assert_equal "Already Here", existing.reload.name
  end

  private

  def use_user_class(klass)
    Object.send(:remove_const, :User) if Object.const_defined?(:User, false)
    Object.const_set(:User, klass)
  end

  def continue_as(email)
    post "/test_sso_seed", params: { email: email }
    assert_response :ok
    post "/sso_continue"
  end
end
