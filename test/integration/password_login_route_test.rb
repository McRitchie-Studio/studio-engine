# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

ActionDispatch::IntegrationTest.app = Rails.application

# A host app's tables, controller base and passwordless User, as the consumers
# ship them. bin/release-check runs each test FILE in its own process, so these
# top-level definitions collide with nothing.
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

# No has_secure_password: the password case gives it `authenticate` for the
# length of one test only.
class User < ApplicationRecord
  def display_name
    name.presence || email.split("@").first
  end
end

# POST /login (sessions#create) is the email+password exchange, and the engine
# draws it only for an app that declares :password in Studio.auth_methods.
#
# A passwordless app that inherited the route published a door with nothing
# behind it: the engine's #create calls user.authenticate, which a passwordless
# User does not define, so a member's address answered 500 and a stranger's 422.
# The two different answers told anyone who asked which addresses belong to
# members. With no route there is one answer for every address: 404.
#
# The rest of the sign-in surface does not move with it. GET /login is the
# sign-in page every app renders, and the SSO, logout, signup and OmniAuth
# routes serve passwordless apps too.
module PasswordLoginRouteSupport
  def with_auth_methods(methods)
    original = Studio.auth_methods
    Studio.auth_methods = methods
    Rails.application.reload_routes!
    yield
  ensure
    Studio.auth_methods = original
    Rails.application.reload_routes!
  end

  def login_routes
    Rails.application.routes.routes.select { |r| r.path.spec.to_s == "/login(.:format)" }
  end

  def login_verbs
    login_routes.map(&:verb).to_set
  end

  # Every drawn route except POST /login, as verb + path + controller#action.
  def routes_other_than_password_login
    Rails.application.routes.routes.filter_map do |r|
      next if r.verb == "POST" && r.path.spec.to_s == "/login(.:format)"

      [r.verb, r.path.spec.to_s, r.defaults[:controller], r.defaults[:action]]
    end.to_set
  end
end

# [unit] The drawn route table, read as data rather than as source text.
class PasswordLoginRouteTableTest < ActiveSupport::TestCase
  include PasswordLoginRouteSupport

  test "an app without :password draws no password login path" do
    [%i[magic_link google], %i[magic_link], %i[google], %i[magic_link google wallet]].each do |methods|
      with_auth_methods(methods) do
        refute_includes login_verbs, "POST", "#{methods.inspect} must draw no POST /login"
        assert_includes login_verbs, "GET", "#{methods.inspect} keeps the GET /login sign-in page"
      end
    end
  end

  test "an app with :password draws POST /login to sessions#create" do
    with_auth_methods(%i[password google]) do
      post_login = login_routes.find { |r| r.verb == "POST" }

      assert post_login, "a password app keeps POST /login"
      assert_equal "sessions", post_login.defaults[:controller]
      assert_equal "create", post_login.defaults[:action]
    end
  end

  # The gate removes exactly one route. If it ever took a neighbour with it
  # (the sign-in page, SSO, logout, signup), a consumer would lose a route it
  # still links to, and that fails at boot or in a visitor's browser, not here.
  test "adding :password adds POST /login and changes no other route" do
    without = with_auth_methods(%i[magic_link google]) { routes_other_than_password_login }
    with = with_auth_methods(%i[magic_link google password]) { routes_other_than_password_login }

    assert_equal without, with
  end

  # login_path names the GET sign-in page, so the helper every app redirects to
  # survives on a passwordless app.
  test "login_path still generates on a passwordless app" do
    with_auth_methods(%i[magic_link]) do
      assert_equal "/login", Rails.application.routes.url_helpers.login_path
    end
  end
end

# [integration] Through the real stack. The dummy app raises exceptions in tests
# (show_exceptions :none); these requests switch it to :rescuable, the
# production behaviour, so each one reads the status a visitor would get.
class PasswordLoginRouteRequestTest < ActionDispatch::IntegrationTest
  include PasswordLoginRouteSupport

  MEMBER = "member@example.com"
  STRANGER = "stranger@example.com"

  def setup
    @prior_show_exceptions = Rails.application.env_config["action_dispatch.show_exceptions"]
    Rails.application.env_config["action_dispatch.show_exceptions"] = :rescuable
    User.delete_all
    User.create!(email: MEMBER, name: "Member")
  end

  def teardown
    Rails.application.env_config["action_dispatch.show_exceptions"] = @prior_show_exceptions
    User.send(:remove_method, :authenticate) if User.method_defined?(:authenticate, false)
  end

  # The enumeration this closes: a member's address and a stranger's must get
  # the same answer, and the answer is that the route does not exist.
  test "a magic-link-only app answers 404 on the password login POST" do
    with_auth_methods(%i[magic_link]) do
      post "/login", params: { email: MEMBER, password: "guess" }
      member_status = response.status

      post "/login", params: { email: STRANGER, password: "guess" }
      stranger_status = response.status

      assert_equal 404, member_status, "a member's address must not reach sessions#create"
      assert_equal 404, stranger_status, "a stranger's address must not reach sessions#create"
      assert_nil session[Studio.session_key]
    end
  end

  test "a password app signs a member in through POST /login, as it always did" do
    User.define_method(:authenticate) { |password| password == "right" && self }

    with_auth_methods(%i[password]) do
      post "/login", params: { email: MEMBER, password: "right" }

      assert_redirected_to "/"
      assert_equal User.find_by(email: MEMBER).id, session[Studio.session_key]
    end
  end

  test "a password app refuses a wrong password with 422, as it always did" do
    User.define_method(:authenticate) { |password| password == "right" && self }

    with_auth_methods(%i[password]) do
      post "/login", params: { email: MEMBER, password: "wrong" }

      assert_response :unprocessable_entity
      assert_nil session[Studio.session_key]
    end
  end
end
