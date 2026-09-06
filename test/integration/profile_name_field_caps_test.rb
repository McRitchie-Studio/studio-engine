# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

# [integration] /profile's name cap, PER FIELD — proven on a host that carries
# both halves.
#
# WHY A SEPARATE FILE, and not three more assertions in profile_requests_test.rb.
# That file's `users` has `first_name` and NO `last_name`, which is not an
# oversight: it is mcritchie-industries' real shape (the engine's own
# standard-columns migration adds `first_name` only), and it is what keeps the
# `respond_to?(:last_name)` guard in ProfilesController#name_attributes honest.
# Adding the column there would retire that coverage. mcritchie-studio and
# turf-monster carry BOTH columns, so that second shape gets its own file — the
# same rule profile_thin_host_test.rb and onboarding_thin_host_test.rb already
# follow, and one bin/release-check supports by running each test FILE in its
# own process.
#
# WHAT IT PINS. `Studio::FIRST_NAME_MAX_LENGTH` measures ONE FIELD. That reading
# is load-bearing and easy to lose from a distance: the onboarding endpoint used
# the same constant to measure a WHOLE typed answer, so anyone re-scoping the
# number to fix onboarding would silently halve what /profile accepts. Nothing
# in the suite said so out loud — the per-field cap was asserted for
# `first_name` alone, where "per field" and "per whole name" cannot be told
# apart. Two fields can tell them apart, which is the whole reason this file
# sends both.
ActionDispatch::IntegrationTest.app = Rails.application

# See profile_requests_test.rb — require_authentication answers
# format.turbo_stream, a MIME type turbo-rails registers and this dummy lacks.
Mime::Type.register "text/vnd.turbo-stream.html", :turbo_stream unless Mime[:turbo_stream]

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  # The FULL host shape: both name halves, as mcritchie-studio and turf-monster
  # carry them. `last_name` is the column this file exists for.
  create_table :users, force: true do |t|
    t.string :email
    t.string :name
    t.string :first_name
    t.string :last_name
    t.string :role
    t.timestamps
  end

  # Studio::ErrorHandling#rescue_and_log writes here on any unexpected
  # exception, so a controller that raised would fail with "Could not find
  # table" instead of reporting the actual bug.
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

  # The engine's avatar contract — every real consumer answers these.
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

class ProfileNameFieldCapsTest < ActionDispatch::IntegrationTest
  def setup
    User.delete_all
    @user = User.create!(email: "pat@example.com", name: "Pat Studio", role: "viewer")
    post "/test_sign_in/#{@user.id}"
    assert_response :ok
  end

  # THE CONTRACT. Each input is capped on its own, so the pair holds twice the
  # cap. Sending both in ONE request is what makes the assertion mean "per
  # field" — a cap applied to the whole name would land the two columns well
  # short, and a single-field test could not tell the two readings apart.
  test "each name field is capped on its own, not against the pair" do
    patch "/profile", params: { profile: {
      first_name: "A" * 200,
      last_name: "B" * 200
    } }

    @user.reload

    assert_equal Studio::FIRST_NAME_MAX_LENGTH, @user.first_name.length
    assert_equal Studio::FIRST_NAME_MAX_LENGTH, @user.last_name.length

    stored = @user.first_name.length + @user.last_name.length
    assert_equal Studio::FIRST_NAME_MAX_LENGTH * 2, stored,
                 "the cap measures one field; two fields hold two caps' worth"

    # THE CONTROL that names the boundary between the two vocabularies. The
    # onboarding step's whole-answer cap is exactly this pair PLUS the space
    # that joins them — the longest typed string that still splits into two
    # halves this page would accept. Stating it here is what makes the two
    # constants a relationship rather than two loose numbers: re-scope either
    # one and this fails.
    assert_equal stored + 1, Studio::FULL_NAME_MAX_LENGTH,
                 "the whole-answer cap is first + a space + last — if it stops being " \
                 "that, onboarding can store a name this page would silently shorten"
  end

  # The cap is a CEILING, not a target: a name under it is stored as typed, in
  # both fields. Without this, a cap regressed to a fixed-width pad or an
  # unconditional truncation would still satisfy the lengths asserted above.
  test "a name inside the cap is stored exactly as typed" do
    patch "/profile", params: { profile: { first_name: "Ada", last_name: "Lovelace" } }

    @user.reload

    assert_equal "Ada", @user.first_name
    assert_equal "Lovelace", @user.last_name
  end
end
