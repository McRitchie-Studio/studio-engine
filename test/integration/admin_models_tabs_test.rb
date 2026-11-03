# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"
require "action_view/testing/resolvers"

ActionDispatch::IntegrationTest.app = Rails.application
Mime::Type.register "text/vnd.turbo-stream.html", :turbo_stream unless Mime[:turbo_stream]

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table(:users, force: true) { |t| t.string :email; t.string :role; t.string :session_token; t.timestamps }
  create_table :studio_user_sessions, force: true do |t|
    t.bigint :user_id, null: false
    t.boolean :admin, null: false, default: false
    t.datetime :started_at, null: false
    t.datetime :last_seen_at, null: false
    t.timestamps
  end
end

class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
end

class User < ApplicationRecord
  def admin? = role == "admin"
end

class ModelTabsSessionsController < ApplicationController
  skip_before_action :require_authentication

  def create
    user = User.find(params[:id])
    session[Studio.session_key] = user.id
    session[:session_token] = user.session_token
    head :ok
  end
end

# A host's models controller: its own models plus the engine's standard tab.
module Admin
  class TabsTestController < ApplicationController
    include Studio::AdminModels
    layout false
    before_action :require_admin

    MODELS = {
      "users" => { label: "Users", description: "Accounts" },
      "widgets" => { label: "Widgets", description: "A model this app added" }
    }.freeze

    prepend_view_path ActionView::FixtureResolver.new(
      "admin/models/_users_table.html.erb" => "<table id='models-users-table'></table>",
      "admin/models/_widgets_table.html.erb" => "<table id='models-widgets-table'></table>"
    )

    private

    def admin_model_scope_for(_key) = User.order(:id)
  end
end

Rails.application.routes.append do
  post "tabs_test_sign_in/:id", to: "model_tabs_sessions#create"
  get "admin/models", to: "admin/tabs_test#index", as: :admin_models
  get "admin/models/:key", to: "admin/tabs_test#show", as: :admin_model
end
Rails.application.reload_routes!

# [integration] The admin models page: a table per tab, the open tab highlighted,
# Sessions as a standard tab, and the row a real request records.
class AdminModelsTabsTest < ActionDispatch::IntegrationTest
  setup do
    Studio::UserSession.delete_all
    User.delete_all
    @admin = User.create!(email: "admin@example.test", role: "admin", session_token: "tok")
    post "/tabs_test_sign_in/#{@admin.id}"
  end

  def tabs = css_select("nav[aria-label='Models'] a")
  def open_tabs = css_select("nav[aria-label='Models'] a[aria-current='page']").map(&:text)

  test "the overview is the first tab: one table, title and tabs on one row" do
    get "/admin/models"
    assert_response :success

    assert_select "nav[aria-label='Models'] h1", text: "Models", count: 1
    assert_equal %w[Users Sessions Widgets], tabs.map(&:text)
    assert_equal ["Users"], open_tabs
    assert_select "table", count: 1
    assert_select "table#models-users-table"
    assert_select "a", text: "Back to dashboard", count: 0
  end

  test "each tab opens its own table and is the one highlighted" do
    get "/admin/models/widgets"
    assert_equal ["Widgets"], open_tabs
    assert_select "nav[aria-label='Models'] a.btn-primary", text: "Widgets", count: 1
    assert_select "nav[aria-label='Models'] a.btn-primary", count: 1
    assert_select "table#models-widgets-table"
  end

  test "a signed-in request records a session, and the Sessions tab lists it" do
    get "/admin/models/sessions"
    assert_response :success
    assert_equal ["Sessions"], open_tabs

    row = Studio::UserSession.sole
    assert_equal @admin.id, row.user_id
    assert row.admin

    get "/admin/models/sessions"
    assert_select "table#models-sessions-table td", text: /admin@example.test/
    assert_equal 1, Studio::UserSession.count, "a second request inside the throttle adds no row"
  end

  test "an unknown model is not found" do
      assert_raises(ActiveRecord::RecordNotFound) { get "/admin/models/nope" }
  end
end
