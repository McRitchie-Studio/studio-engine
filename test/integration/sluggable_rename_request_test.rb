# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

# [integration] A slug rename through a dispatched request, in a controller that
# includes Studio::ErrorHandling the way every host's ApplicationController does.
# A duplicate or badly formed slug answers 422 with the reason for JSON and a
# redirect back with the reason for HTML; it never reaches the catch-all that
# answers 500. The form path (`rename_slug`) re-renders 422 inline.
#
# The dummy runs with show_exceptions :none, so a refusal the concern failed to
# claim would raise out of the request here instead of passing as an error page.
ActionDispatch::IntegrationTest.app = Rails.application

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :teams, force: true do |t|
    t.string :name
    t.string :slug
    t.timestamps
    t.index :slug, unique: true
  end

  create_table :players, force: true do |t|
    t.string :team_slug
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

class RenameTeam < ApplicationRecord
  self.table_name = "teams"
  include Sluggable

  has_slug_children "players" => :team_slug

  def name_slug
    name.to_s.parameterize
  end
end

class TeamSlugsController < ActionController::Base
  include Studio::ErrorHandling

  skip_before_action :require_authentication
  skip_forgery_protection

  # The admin rename: the bang form, left to the concern's handler.
  def update
    team = RenameTeam.find_by!(slug: params[:id])
    team.rename_slug!(params[:slug])

    respond_to do |format|
      format.json { render json: { slug: team.slug } }
      format.html { redirect_to "/team_slugs/#{team.slug}" }
    end
  end

  # The inline form: the non-bang form, re-rendering with the reason.
  def form_update
    team = RenameTeam.find_by!(slug: params[:id])
    return render(plain: team.slug) if team.rename_slug(params[:slug])

    render plain: team.errors.full_messages_for(:slug).to_sentence, status: :unprocessable_entity
  end

  def create_error_log(exception)
    raise "no ErrorLog for a slug refusal: #{exception.class}"
  end
end

Rails.application.routes.append do
  patch "team_slugs/:id", to: "team_slugs#update"
  patch "team_slugs/:id/form", to: "team_slugs#form_update"
end
Rails.application.reload_routes!

class SluggableRenameRequestTest < ActionDispatch::IntegrationTest
  def setup
    ActiveRecord::Base.connection.execute("DELETE FROM players")
    RenameTeam.delete_all
    @team = RenameTeam.create!(name: "Denver Broncos")
    RenameTeam.create!(name: "Seattle Seahawks")
    ActiveRecord::Base.connection.execute("INSERT INTO players (team_slug) VALUES ('denver-broncos')")
  end

  def rename(slug, format: :json, path: "/team_slugs/denver-broncos")
    headers = format == :json ? { "ACCEPT" => "application/json" } : { "ACCEPT" => "text/html", "HTTP_REFERER" => "/teams/edit" }
    patch path, params: { slug: slug }, headers: headers
  end

  def player_slugs = ActiveRecord::Base.connection.select_values("SELECT team_slug FROM players")

  test "a free, well-formed slug renames the team and its players" do
    rename "broncos"

    assert_response :success
    assert_equal({ "slug" => "broncos" }, JSON.parse(response.body))
    assert_equal %w[broncos], player_slugs
  end

  test "a duplicate slug answers 422 with the reason, and nothing moves" do
    rename "seattle-seahawks"

    assert_response :unprocessable_entity
    assert_equal({ "error" => "Slug has already been taken" }, JSON.parse(response.body))
    assert_equal "denver-broncos", @team.reload.slug
    assert_equal %w[denver-broncos], player_slugs
  end

  test "a badly formed slug answers 422 with the reason" do
    rename "Denver Broncos!"

    assert_response :unprocessable_entity
    assert_equal({ "error" => "Slug is invalid" }, JSON.parse(response.body))
  end

  test "an HTML refusal goes back to the form with the reason as the alert" do
    rename "seattle-seahawks", format: :html

    assert_redirected_to "/teams/edit"
    assert_equal "Slug has already been taken", flash[:alert]
    assert_equal "denver-broncos", @team.reload.slug
  end

  test "the form path re-renders 422 inline with the reason" do
    rename "", path: "/team_slugs/denver-broncos/form"

    assert_response :unprocessable_entity
    assert_equal "Slug can't be blank", response.body
  end

  # CONTROL: the 422 above comes from the concern's own handler. An invalid save
  # that is NOT a slug refusal still reaches the catch-all, which in test raises,
  # so the handler claims only SlugRefused and not every RecordInvalid.
  test "a plain RecordInvalid is not claimed by the slug handler" do
    controller = TeamSlugsController.new
    plain = ActiveRecord::RecordInvalid.new(@team)

    assert_equal :handle_unexpected_error, controller.send(:handler_for_rescue, plain).name
    assert_equal :handle_slug_refused,
                 controller.send(:handler_for_rescue, Sluggable::SlugRefused.new(@team)).name
  end
end
