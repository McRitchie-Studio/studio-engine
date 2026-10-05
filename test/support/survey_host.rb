# frozen_string_literal: true

# A consuming app, as far as the survey primitive is concerned: the engine's
# migration run for real, a host ApplicationController with
# Studio::ErrorHandling (so require_authentication and require_admin are the
# engine's own), a User, a sign-in door that writes the real session key, both
# survey route flags on, and one survey of every question type.
#
# Required by test/integration/survey_*_test.rb, each its own process.
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
    t.string :email
    t.string :name
    t.string :username
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

require_relative "../../db/migrate/20261005120000_create_studio_survey_responses"
ActiveRecord::Migration.suppress_messages { CreateStudioSurveyResponses.new.migrate(:up) }
Studio::SurveyResponse.reset_column_information

class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
end

class User < ApplicationRecord
  def admin? = role == "admin"
  def display_name = name.presence || email.to_s.split("@").first
end

class SurveyTestSessionsController < ApplicationController
  skip_before_action :require_authentication

  def create
    session[Studio.session_key] = params[:id].to_i
    head :ok
  end
end

Studio.draw_survey_routes = true
Studio.draw_admin_survey_routes = true
Rails.application.reload_routes!
Rails.application.routes.append do
  post "survey_test_sign_in/:id", to: "survey_test_sessions#create"
end
Rails.application.reload_routes!

module SurveyHost
  # What the engine's to_prepare loaded from test/dummy/config/surveys at boot,
  # read before any test resets the registry.
  BOOT_KEYS = Studio.survey("first-game")&.keys

  def self.define_surveys!
    Studio::Survey.reset!
    Studio.define_survey "first-game" do
      title "How was your first game?"
      intro "Six quick questions."
      thank_you "We read every answer."
      next_action label: "Play again", url: "/play"
      allow_anonymous true
      emoji_scale :overall, "How was it?", required: true
      rating :rules, "How clear were the rules?", low_label: "Lost", high_label: "Clear"
      choice :found_us, "How did you find us?", options: ["Email", "A friend", "Search"]
      multi_choice :liked, "What did you enjoy?", options: %w[Board Pace Art]
      short_text :word, "One word for it?"
      long_text :more, "Anything else?", required: true
    end
    Studio.define_survey "members-only" do
      title "Members only"
      rating :score, "Score?", required: true
    end
  end

  def sign_in(user)
    post "/survey_test_sign_in/#{user.id}"
    assert_response :ok
  end

  def survey = Studio.survey("first-game")
end
