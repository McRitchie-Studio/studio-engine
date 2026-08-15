# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

# [integration] /profile against a THIN host — a users table with none of the
# profile columns.
#
# WHY A SEPARATE FILE. This is the case profile_requests_test.rb structurally
# cannot cover: there, every user has first_name / provider / uid, so a guard
# that regressed to always-true would give the same answer as the correct one
# and the suite would stay green. Measured, not assumed — mutating
# ProfilesController#serves? to `true` leaves that file 13/13 green while
# reddening this one. Two shapes of `users` cannot coexist in one process, and
# bin/release-check runs each test FILE in its own process, so the second shape
# gets its own file.
#
# This is the harness Carl's F2 asked for. The old test proved the guard by
# regex-scanning the controller's source; this one proves it by sending the
# request a real thin host would send and reading what came back.
#
# mcritchie-industries IS this shape today for first_name: eight columns, no
# first_name, until it installs the standard profile columns.
ActionDispatch::IntegrationTest.app = Rails.application

# See profile_requests_test.rb — require_authentication answers
# format.turbo_stream, a MIME type turbo-rails registers and this dummy lacks.
Mime::Type.register "text/vnd.turbo-stream.html", :turbo_stream unless Mime[:turbo_stream]

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  # Deliberately minimal: NO first_name, NO provider, NO uid, no avatar.
  create_table :users, force: true do |t|
    t.string :email
    t.string :name
    t.string :role
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

class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
end

class User < ApplicationRecord
  def admin? = role == "admin"
end

class TestSessionsController < ApplicationController
  skip_before_action :require_authentication

  def create
    session[Studio.session_key] = params[:id]
    head :ok
  end
end

Rails.application.routes.append do
  post "test_sign_in/:id", to: "test_sessions#create"
end
Rails.application.reload_routes!

class ProfileThinHostTest < ActionDispatch::IntegrationTest
  def setup
    User.delete_all
    @user = User.create!(email: "pat@example.com", name: "Pat Studio", role: "viewer")
    post "/test_sign_in/#{@user.id}"
    assert_response :ok
  end

  # --- the page degrades rather than breaking ---------------------------------

  test "the page renders with none of the rows this host cannot serve" do
    get "/profile"

    assert_response :success
    refute_includes response.body, "Your name"
    refute_includes response.body, "Profile photo"
    refute_includes response.body, "Google account"
  end

  test "a host that can serve nothing gets an honest empty state, not a blank page" do
    get "/profile"

    assert_includes response.body, "Nothing to edit yet"
  end

  # --- the writes REFUSE rather than 500 --------------------------------------
  #
  # THE TESTS THIS FILE EXISTS FOR. Studio::ErrorHandling#rescue_and_log
  # RE-RAISES, so an unguarded write against a missing column is a 500 plus an
  # ErrorLog row — not a graceful no-op. Mutating ProfilesController#serves? to
  # always-true reddens both of these, which is precisely the regression the
  # source-scanning harness could not see.

  test "patching a first name this host has no column for is refused, not a 500" do
    patch "/profile", params: { profile: { first_name: "Alexander" } }

    assert_response :see_other
    assert_equal 0, ErrorLog.count, "a refusal must not be an exception in disguise"
  end

  test "unlinking google on a host with no oauth columns is refused, not a 500" do
    delete "/profile/google"

    assert_response :see_other
    assert_equal 0, ErrorLog.count
  end

  test "the avatar write is refused on a host with no attachment" do
    patch "/profile/avatar", params: { profile: { avatar: "not-a-file" } }

    assert_response :see_other
    assert_equal 0, ErrorLog.count
  end

  # A refused write must leave the record exactly as it was — no partial
  # application of the fields it COULD serve.
  test "a refused write changes nothing" do
    before = @user.attributes

    patch "/profile", params: { profile: { first_name: "Alexander" } }

    assert_equal before, @user.reload.attributes
  end
end
