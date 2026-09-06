# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

# [integration] POST /onboarding/first_name against a REAL host-shaped User —
# the row it actually leaves behind.
#
# WHY A DISPATCHED TEST AND NOT A UNIT ONE. The bug this file guards was
# invisible to every unit lane: Studio::OnboardingController writes with
# `update_columns`, so `first_name` got the WHOLE typed value and the host's
# `before_save :set_name_parts` never ran to split it. Someone answering the
# first-name prompt with "Ada Lovelace" landed first_name="Ada Lovelace",
# last_name NULL — and it never self-healed, because set_name_parts is gated on
# `name_changed?` and no later save sees a name change. Only a real record with
# real callbacks can tell that story.
#
# THE USER BELOW IS THE HOST, NOT A CONVENIENCE. It carries the two callbacks
# every consuming app's User actually carries, copied from
# mcritchie-studio/app/models/user.rb:
#
#   include Sluggable                                  # ungated before_save :set_slug
#   before_save :set_name_parts, if: -> { name_changed? }
#
# Both are load-bearing here and pull in OPPOSITE directions, which is the whole
# design problem this endpoint sits inside:
#
#   * set_name_parts is what the write must AGREE WITH.
#   * set_slug is why the write must not be a full save — Sluggable's hook is
#     UNGATED and mcritchie-studio's User#name_slug is built from `name`, so a
#     save right after this endpoint writes `name` would re-point the slug the
#     account answers on. On a column with a unique index. Every signup.
#
# So `test_a_full_save_would_repoint_the_slug` is a CONTROL, not decoration: it
# proves the constraint is live in this harness rather than asserted from
# reading, which is what makes the guard next to it mean something.
#
# The pure derivation is unit-tested in test/lib/studio/name_parts_test.rb.
# The endpoints, routes and the shared outstanding? rule are covered by
# test/integration/onboarding_endpoints_test.rb. A host with NO last_name column
# is test/integration/onboarding_thin_host_test.rb — two shapes of `users`
# cannot coexist in one process, and bin/release-check runs each file in its own.
ActionDispatch::IntegrationTest.app = Rails.application

# See profile_requests_test.rb — require_authentication answers
# format.turbo_stream, a MIME type turbo-rails registers and this dummy lacks.
Mime::Type.register "text/vnd.turbo-stream.html", :turbo_stream unless Mime[:turbo_stream]

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  # The host owns this table in production. These are the columns both real
  # consumers carry for this flow — including `slug`, WITH its unique index,
  # because the index is half of why a full save is not an option here.
  create_table :users, force: true do |t|
    t.string :email
    t.string :name
    t.string :first_name
    t.string :last_name
    t.string :slug
    t.string :role
    t.timestamps
    t.index :slug, unique: true
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
  # The engine's own concern (app/models/concerns/sluggable.rb), included the
  # way both consumers include it — NOT a local imitation. Its before_save is
  # ungated by construction, and that is the property under test.
  include Sluggable

  before_save :set_name_parts, if: -> { name_changed? }

  def admin? = role == "admin"

  def display_name = name.presence || email.to_s.split("@").first.presence || "anon"
  def avatar_initials = display_name.to_s[0].to_s.upcase
  def avatar_color = "#6366f1"

  private

  # Copied verbatim from mcritchie-studio/app/models/user.rb (byte-identical in
  # turf-monster). The reference the endpoint has to match.
  def set_name_parts
    parts = name.to_s.strip.split(" ")
    self.first_name = parts.first
    self.last_name = parts.last if parts.size > 1
  end

  # mcritchie-studio's shape: built from `name`, so a name write moves the slug.
  def name_slug
    identifier = email.presence || "user"
    prefix = name.presence || email&.split("@")&.first || "user"
    "#{prefix}-#{identifier}".downcase.gsub(/\s+/, "-")
  end
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

class OnboardingNamePartsTest < ActionDispatch::IntegrationTest
  def setup
    User.delete_all
    @user = User.create!(email: "pat@example.com", role: "viewer")
    post "/test_sign_in/#{@user.id}"
    assert_response :ok
  end

  def answer(value)
    post "/onboarding/first_name",
         params: { first_name: value }.to_json,
         headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
  end

  def body = JSON.parse(response.body)

  # --- THE REGRESSION ---------------------------------------------------------

  # The bug, stated as the row it leaves behind. Before the fix this landed
  # first_name="Ada Lovelace", last_name=nil.
  test "a multi-word answer lands split exactly as the callback would split it" do
    answer "Ada Lovelace"

    assert_response :success
    @user.reload

    assert_equal "Ada", @user.first_name
    assert_equal "Lovelace", @user.last_name
    assert_equal "Ada Lovelace", @user.name, "the full answer is still the display name"
  end

  # PARITY, proven against the callback itself rather than against a second copy
  # of the rule: the same string driven through a full save must produce the
  # same two halves the endpoint produced.
  test "the endpoint and the host callback agree on the halves" do
    answer "Ada B. Lovelace"
    @user.reload
    through_endpoint = [@user.first_name, @user.last_name]

    other = User.create!(email: "via-callback@example.com", name: "Ada B. Lovelace")

    assert_equal [other.first_name, other.last_name], through_endpoint
  end

  # The row is right the FIRST time, which matters because it never gets a
  # second chance: set_name_parts is gated on `name_changed?`, so an ordinary
  # later save cannot repair a row this endpoint got wrong.
  test "a later ordinary save neither repairs nor disturbs the halves" do
    answer "Ada Lovelace"
    @user.reload
    @user.update!(role: "editor")

    assert_equal "Ada", @user.reload.first_name
    assert_equal "Lovelace", @user.last_name
  end

  # --- the slug, which is why this is not a plain save ------------------------

  test "the write does not repoint the slug" do
    before = @user.reload.slug
    refute_nil before, "Sluggable stamped a slug at create — the guard needs one to protect"

    answer "Ada Lovelace"

    assert_equal before, @user.reload.slug,
                 "a signup answering a name must not change the URL the account answers on"
  end

  # THE CONTROL for the guard above. If a full save did NOT move the slug, that
  # guard would pass for the wrong reason and this endpoint's `update_columns`
  # would look like an unjustified shortcut. It moves.
  test "a full save after the same write would repoint the slug" do
    before = @user.reload.slug

    @user.update!(name: "Ada Lovelace")

    refute_equal before, @user.reload.slug,
                 "Sluggable's before_save is UNGATED and name_slug reads `name` — " \
                 "this is the cost the endpoint's update_columns is avoiding"
  end

  # --- carry-over and backfill, unchanged by the fix --------------------------

  # One word omits last_name rather than nulling it, so a surname already on
  # file survives someone answering a first-name prompt.
  test "a one-word answer leaves an existing last name standing" do
    @user.update_columns(first_name: "Augusta", last_name: "Lovelace")

    answer "Ada"
    @user.reload

    assert_equal "Ada", @user.first_name
    assert_equal "Lovelace", @user.last_name
  end

  # `name` is backfilled only when blank — the pre-existing rule, and one the
  # split must not quietly change.
  test "a name already on file is not overwritten" do
    @user.update_columns(name: "Augusta King")

    answer "Ada Lovelace"
    @user.reload

    assert_equal "Augusta King", @user.name
    assert_equal "Ada", @user.first_name
    assert_equal "Lovelace", @user.last_name
  end

  # --- the response -----------------------------------------------------------

  # The STORED first name, not the typed string. A response that disagreed with
  # the row would be the same bug wearing a different hat.
  test "the response reports the first name that was actually stored" do
    answer "Ada Lovelace"

    assert_equal true, body["ok"]
    assert_equal "Ada", body["first_name"]
    assert_equal "Ada", @user.reload.first_name
  end

  test "a blank answer is refused and writes nothing" do
    answer "   "

    assert_response :unprocessable_entity
    refute body["ok"]
    assert_nil @user.reload.first_name
  end
end
