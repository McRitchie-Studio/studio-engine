# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

ActionDispatch::IntegrationTest.app = Rails.application

Mime::Type.register "text/vnd.turbo-stream.html", :turbo_stream unless Mime[:turbo_stream]

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :email, null: false
    t.string :name
    t.timestamps
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

# A host's ApplicationController shaped like the consumers': Studio::ErrorHandling
# and its require_authentication filter (which redirects an HTML request to
# /login). Signed in is a cookie here, read through the host's own logged_in?.
# The helper is the shape of Turf's *_modal_locals helpers.
class ApplicationController < ActionController::Base
  include Studio::ErrorHandling

  helper_method :lab_rules_locals

  private

  def logged_in? = cookies[:modal_lab_user] == "1"

  def lab_rules_locals = { greeting: "Hello from a helper" }
end

class User < ApplicationRecord; end

# [unit] GET /_studio/modals/:id (Studio::ModalsController): the allowlist is
# the registry, a :user modal checks sign-in, the locals resolve in the view,
# and the answer is a private fragment the browser can recognise.
class ModalsEndpointTest < ActionDispatch::IntegrationTest
  PARTIAL = "e2e_lab/modals/remote_rules"

  def setup
    Studio.modals.clear!
    Studio.modals.register :rules, partial: PARTIAL, locals: :lab_rules_locals
    Studio.modals.register :member, partial: "e2e_lab/modals/remote_member", auth: :user
    Studio.modals.register :lambda_locals, partial: PARTIAL, locals: ->(view) { { greeting: view.respond_to?(:render) ? "From a callable" : "no view" } }
    Studio.modals.register :hash_locals, partial: PARTIAL, locals: { greeting: "From a hash" }
    Rails.application.routes.url_helpers.login_path
  end

  def teardown
    Studio.modals.clear!
  end

  def fetch_modal(id, signed_in: false)
    cookies[:modal_lab_user] = signed_in ? "1" : ""
    get "/_studio/modals/#{id}", headers: { "Accept" => "text/html", "X-Requested-With" => "XMLHttpRequest" }
  end

  def test_a_registered_modal_renders_its_partial_alone
    fetch_modal("rules")

    assert_response :success
    assert_equal "rules", response.headers["X-Studio-Modal"]
    assert_match %r{\Atext/html}, response.media_type
    assert_includes response.body, 'data-test="remote-rules"'
    assert_includes response.body, "Hello from a helper", "a Symbol names a helper the view answers"
    refute_match(/<html|<head|<body/i, response.body, "no layout")
    refute_match(/<script/i, response.body, "a fragment carries no script")
  end

  def test_callable_and_hash_locals
    fetch_modal("lambda_locals")
    assert_includes response.body, "From a callable"

    fetch_modal("hash_locals")
    assert_includes response.body, "From a hash"
  end

  def test_an_unregistered_id_is_404_even_when_the_partial_exists
    fetch_modal("remote_rules")
    assert_response :not_found
    assert_nil response.headers["X-Studio-Modal"]

    # A path-shaped id never reaches the controller: the route refuses it.
    assert_raises(ActionController::RoutingError) do
      get "/_studio/modals/..%2Fe2e_lab%2Fmodals%2Fremote_rules"
    end
  end

  def test_a_user_modal_answers_401_signed_out_not_a_redirect
    fetch_modal("member", signed_in: false)

    assert_response :unauthorized
    assert_nil response.headers["Location"]
    assert_nil response.headers["X-Studio-Modal"]
  end

  def test_a_user_modal_renders_signed_in
    fetch_modal("member", signed_in: true)

    assert_response :success
    assert_includes response.body, "Members only"
  end

  def test_an_any_modal_skips_the_hosts_sign_in_redirect
    fetch_modal("rules", signed_in: false)
    assert_response :success
  end

  def test_the_answer_is_private_and_varies_by_cookie
    fetch_modal("rules")

    cache = response.headers["Cache-Control"].to_s
    assert_includes cache, "private"
    refute_includes cache, "public"
    assert_includes response.headers["Vary"].to_s, "Cookie"
    assert response.headers["ETag"].present?, "Rails' ETag lets a revisit answer 304"
  end

  # ---- engine-modals-fetch-hardening ----

  def test_a_fragment_with_a_script_is_recorded_once_as_an_error_log
    Studio::ModalsController.forget_recorded_scripts!
    Studio.modals.register :scripted, partial: "e2e_lab/modals/remote_script"
    before = ErrorLog.count
    fetch_modal("scripted")

    assert_response :success
    assert_equal "scripted", response.headers["X-Studio-Modal"], "still sent: the browser refuses it"
    assert_equal before + 1, ErrorLog.count
    assert_includes ErrorLog.last.message, "renders a <script>"

    fetch_modal("scripted")
    assert_response :success
    assert_equal before + 1, ErrorLog.count, "once per id per process, not per request"
  end

  def test_a_fragment_without_a_script_records_nothing
    before = ErrorLog.count
    fetch_modal("rules")
    assert_response :success
    assert_equal before, ErrorLog.count
  end
end
