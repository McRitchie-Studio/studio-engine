# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

# [integration] The engine's SessionsController finds nobody for a blank email.
#
# Both doors used `User.find_by(email: ...)`. With no address that is
# find_by(email: nil), and it matches ANY account without an email: every
# wallet and guest sign-up. On the password door that account then went to
# `authenticate`; on the SSO door it was signed in outright. Each test here
# fails on the old line (the [control] runs: test names say which door).
#
# authenticate_sso_user! is reached through a subclass route because its only
# public caller, sso_continue, checks the address is present first. The method
# itself must not depend on that check.
ActionDispatch::IntegrationTest.app = Rails.application

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :email
    t.string :name
    t.string :provider
    t.string :uid
    t.string :session_token
    t.string :solana_address
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
    t.string :target_name
    t.string :parent_type
    t.bigint :parent_id
    t.string :parent_name
    t.timestamps
  end
end

class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
end

# A password host double: the same shape as sso_continue_creates_user_test.rb's.
# `password` is not persisted, so a loaded row's is nil, and a form posted with
# no password compares nil to nil.
class BlankEmailUser < ApplicationRecord
  self.table_name = "users"

  attr_accessor :password

  def authenticate(candidate) = candidate == password && self
  def display_name = name.presence || email.to_s.split("@").first || "User"
end

class ExposedSsoSessionsController < SessionsController
  def force_sso
    authenticate_sso_user!
  end
end

class TestBlankSsoSeedsController < ActionController::Base
  def create
    session[:sso_email] = params[:email]
    session[:sso_source] = "Some Sibling App"
    head :ok
  end
end

Rails.application.routes.append do
  post "test_blank_sso_seed", to: "test_blank_sso_seeds#create"
  post "test_force_sso", to: "exposed_sso_sessions#force_sso"
end
Rails.application.reload_routes!

class SessionsBlankEmailTest < ActionDispatch::IntegrationTest
  def setup
    @original_user = Object.const_defined?(:User, false) ? Object.const_get(:User) : nil
    @original_auth = Studio.auth_methods
    Object.send(:remove_const, :User) if Object.const_defined?(:User, false)
    Object.const_set(:User, BlankEmailUser)
    Studio.auth_methods = %i[password]
    BlankEmailUser.delete_all
    @stranger = BlankEmailUser.create!(name: "Wallet Stranger", solana_address: "So1anaStranger")
  end

  def teardown
    Object.send(:remove_const, :User) if Object.const_defined?(:User, false)
    Object.const_set(:User, @original_user) if @original_user
    Studio.auth_methods = @original_auth
  end

  test "password door: a login posted with no email signs nobody in" do
    post "/login", params: {}

    assert_response :unprocessable_entity
    assert_nil session[Studio.session_key], "find_by(email: nil) signed in the emailless account"
  end

  test "password door: an email matches case-insensitively" do
    member = BlankEmailUser.create!(name: "Mia", email: "mia@example.com")

    post "/login", params: { email: " MIA@Example.com " }

    assert_equal member.id, session[Studio.session_key]
  end

  test "SSO door: a blank sso_email signs nobody in" do
    [nil, "", "  "].each do |blank|
      reset!
      post "/test_blank_sso_seed", params: { email: blank }
      post "/test_force_sso"

      assert_redirected_to "/login"
      assert_nil session[Studio.session_key], "#{blank.inspect}: signed in as #{BlankEmailUser.find_by(id: session[Studio.session_key])&.name}"
    end
    assert_equal 1, BlankEmailUser.count, "a blank address creates no account either"
  end

  test "SSO door: a real address still finds its account" do
    member = BlankEmailUser.create!(name: "Mia", email: "mia@example.com")

    post "/test_blank_sso_seed", params: { email: "Mia@Example.com" }
    post "/test_force_sso"

    assert_equal member.id, session[Studio.session_key]
  end
end
