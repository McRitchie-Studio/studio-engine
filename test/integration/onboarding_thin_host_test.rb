# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

# [integration] POST /onboarding/first_name against a host whose users table has
# `first_name` but NO `last_name`.
#
# THIS IS A REAL FLEET SHAPE, not a hypothetical. The engine's standard-columns
# migration (db/migrate/20260813220000) adds `first_name` and deliberately does
# NOT add `last_name` — making that column universal is a separate coordinated
# change (roll-out-last-name-column). So mcritchie-industries, moms-app and
# acquisition-studio all run this endpoint against a table with no last_name
# today, and app/views/studio/profiles/_name_fields.html.erb already gates on
# exactly that.
#
# WHY IT NEEDS ITS OWN FILE. The fix for the name-splitting bug writes a SECOND
# column, and `update_columns` on a column that does not exist raises inside
# rescue_and_log — which RE-RAISES, so it is a 500 plus an ErrorLog row, not a
# graceful no-op. Without the respond_to? guard in
# Studio::OnboardingController#name_columns, the fix would have turned a
# mis-split row into a hard signup failure across three apps. Two shapes of
# `users` cannot coexist in one process, and bin/release-check runs each test
# FILE in its own process, so the second shape gets its own file — the same
# argument test/integration/profile_thin_host_test.rb makes.
#
# The full-column host is test/integration/onboarding_name_parts_test.rb.
ActionDispatch::IntegrationTest.app = Rails.application

# See profile_requests_test.rb — require_authentication answers
# format.turbo_stream, a MIME type turbo-rails registers and this dummy lacks.
Mime::Type.register "text/vnd.turbo-stream.html", :turbo_stream unless Mime[:turbo_stream]

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  # `first_name` yes, `last_name` NO — the shape the standard-columns migration
  # actually leaves behind.
  create_table :users, force: true do |t|
    t.string :email
    t.string :name
    t.string :first_name
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

  def display_name = name.presence || email.to_s.split("@").first.presence || "anon"
  def avatar_initials = display_name.to_s[0].to_s.upcase
  def avatar_color = "#6366f1"
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

class OnboardingThinHostTest < ActionDispatch::IntegrationTest
  def setup
    User.delete_all
    ErrorLog.delete_all
    @user = User.create!(email: "pat@example.com", role: "viewer")
    post "/test_sign_in/#{@user.id}"
    assert_response :ok
  end

  def answer(value)
    post "/onboarding/first_name",
         params: { first_name: value }.to_json,
         headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
  end

  # THE TEST THIS FILE EXISTS FOR. Drop the respond_to? guard from
  # OnboardingController#name_columns and this goes red with a 500 and an
  # ErrorLog row, while the full-column suite next door stays entirely green.
  test "a multi-word answer succeeds on a host with no last_name column" do
    answer "Ada Lovelace"

    assert_response :success
    assert_equal true, JSON.parse(response.body)["ok"]
    assert_equal 0, ErrorLog.count,
                 "a signup answering a two-word name must not raise on a thin host"
  end

  # What such a host stores: the first half in `first_name`, and the WHOLE answer
  # in `name` — so nothing the person typed is lost, it is simply not split into
  # a column this app does not have.
  test "the half it can store is stored and the whole answer survives in name" do
    answer "Ada Lovelace"
    @user.reload

    assert_equal "Ada", @user.first_name
    assert_equal "Ada Lovelace", @user.name
    refute @user.respond_to?(:last_name), "the premise of this file"
  end

  test "a one-word answer behaves exactly as before" do
    answer "Ada"
    @user.reload

    assert_equal "Ada", @user.first_name
    assert_equal "Ada", @user.name
  end
end
