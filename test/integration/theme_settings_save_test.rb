# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

ActionDispatch::IntegrationTest.app = Rails.application

# Studio::ErrorHandling#require_authentication answers turbo_stream, which the
# dummy does not register.
Mime::Type.register "text/vnd.turbo-stream.html", :turbo_stream unless Mime[:turbo_stream]

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :email
    t.string :role
    t.string :session_token
    t.timestamps
  end

  create_table :theme_settings, force: true do |t|
    t.string :app_name, null: false
    t.string :slug
    t.string :primary
    t.string :dark
    t.string :light
    t.string :accent1
    t.string :accent2
    t.string :warning
    t.string :danger
    t.timestamps
    t.index :app_name, unique: true
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

class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
end

class User < ApplicationRecord
  def admin? = role == "admin"
  def display_name = email.to_s.split("@").first
end

class ThemeTestSessionsController < ApplicationController
  skip_before_action :require_authentication

  def create
    user = User.find(params[:id])
    session[Studio.session_key] = user.id
    session[:session_token] = user.session_token
    head :ok
  end

  def destroy
    reset_session
    head :ok
  end
end

Rails.application.routes.append do
  post "theme_test_sign_in/:id", to: "theme_test_sessions#create"
  delete "theme_test_sign_out", to: "theme_test_sessions#destroy"
end
Rails.application.reload_routes!

# [integration] What /admin/theme answers the style guide's fetch, which asks
# for JSON and follows no redirect: a 204 only once the theme is written. An
# ended session answers 401 and a non-admin a redirect, and neither writes. A
# form post keeps its redirect back to the editor.
class ThemeSettingsSaveTest < ActionDispatch::IntegrationTest
  JSON_FETCH = { "ACCEPT" => "application/json" }.freeze

  setup do
    User.delete_all
    ThemeSetting.delete_all
    @admin = User.create!(email: "admin@example.test", role: "admin", session_token: "tok-admin")
    post "/theme_test_sign_in/#{@admin.id}"
    assert_response :ok
  end

  def save(color, headers: JSON_FETCH)
    patch "/admin/theme", params: { theme_setting: { primary: color } }, headers: headers
  end

  def stored_primary = ThemeSetting.find_by(app_name: Studio.app_name)&.primary

  test "a fetch save answers 204 and the theme is written" do
    save "#123456"

    assert_response :no_content
    assert_equal "#123456", stored_primary
  end

  test "a fetch save after the session ended answers 401 and writes nothing" do
    save "#123456"
    delete "/theme_test_sign_out"

    save "#abcdef"

    assert_response :unauthorized
    assert_equal "#123456", stored_primary
  end

  # The bounce a fetch that names no format gets: a 302 it cannot tell from a
  # save's own redirect.
  test "a save after the session ended that asks for no format is redirected to sign in" do
    delete "/theme_test_sign_out"

    save "#abcdef", headers: {}

    assert_redirected_to "/login"
    assert_nil stored_primary
  end

  test "a fetch save by a non-admin is redirected and writes nothing" do
    member = User.create!(email: "pat@example.test", session_token: "tok-pat")
    post "/theme_test_sign_in/#{member.id}"

    save "#abcdef"

    assert_response :redirect
    assert_nil stored_primary
  end

  test "a fetch save the server refuses answers 422 with the reason" do
    patch "/admin/theme", params: {}, headers: JSON_FETCH

    assert_response :unprocessable_entity
    assert_match(/theme_setting/, JSON.parse(response.body)["error"])
    assert_nil stored_primary
  end

  test "a form save is redirected back to the editor with its notice" do
    save "#123456", headers: { "ACCEPT" => "text/html" }

    assert_redirected_to "/admin/theme"
    assert_equal "Theme saved.", flash[:notice]
    assert_equal "#123456", stored_primary
  end

  test "regenerate answers a fetch 204 and a form post the redirect" do
    post "/admin/theme/regenerate", headers: JSON_FETCH
    assert_response :no_content

    post "/admin/theme/regenerate", headers: { "ACCEPT" => "text/html" }
    assert_redirected_to "/admin/theme"

    delete "/theme_test_sign_out"
    post "/admin/theme/regenerate", headers: JSON_FETCH
    assert_response :unauthorized
  end
end
