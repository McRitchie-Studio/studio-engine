# frozen_string_literal: true

# A consuming app, as far as the integrations registry is concerned: the
# engine's studio_connections migration run for real, Active Record encryption
# keys set, a host ApplicationController with Studio::ErrorHandling, a User, a
# sign-in door, the engine's three integrations ENABLED with this host's own
# env names, a host panel partial for QuickBooks, and the admin page mounted at
# its default path (admin/integrations).
#
# Every HTTP answer is a stub or a stand-in; no test reaches a provider.
#
# Required by test/integration/integrations_*_test.rb, each its own process.
require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

ActionDispatch::IntegrationTest.app = Rails.application

ActiveRecord::Encryption.configure(
  primary_key: "integrations-host-primary-key-not-a-real-secret",
  deterministic_key: "integrations-host-deterministic-key-not-a-real-secret",
  key_derivation_salt: "integrations-host-key-derivation-salt-not-a-real-secret"
)

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :email
    t.string :name
    t.string :slug
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
    t.string :target_name
    t.string :parent_type
    t.bigint :parent_id
    t.string :parent_name
    t.timestamps
  end
end

require_relative "../../db/migrate/20261108130000_create_studio_connections"
ActiveRecord::Migration.suppress_messages { CreateStudioConnections.new.migrate(:up) }
Studio::Connection.reset_column_information

class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
end
ActionController::Base.prepend_view_path(File.expand_path("../fixtures/integrations_host", __dir__))

class User < ApplicationRecord
  def admin? = role == "admin"
  def display_name = name.presence || email.to_s.split("@").first
end

class IntegrationsTestSessionsController < ApplicationController
  skip_before_action :require_authentication, raise: false

  def create
    session[Studio.session_key] = params[:id].to_i
    head :ok
  end
end

module IntegrationsHost
  ENV_NAMES = {
    quickbooks: { client_id: "HOST_QBO_ID", client_secret: "HOST_QBO_SECRET", environment: "HOST_QBO_ENVIRONMENT" },
    egnyte: { client_id: "HOST_EGNYTE_ID", client_secret: "HOST_EGNYTE_SECRET" },
    microsoft_365: { client_id: "HOST_M365_ID", client_secret: "HOST_M365_SECRET" }
  }.freeze
  ENV_VALUES = {
    "HOST_QBO_ID" => "qbo-id", "HOST_QBO_SECRET" => "qbo-secret",
    "HOST_EGNYTE_ID" => "egnyte-id", "HOST_EGNYTE_SECRET" => "egnyte-secret",
    "HOST_M365_ID" => "m365-id", "HOST_M365_SECRET" => "m365-secret"
  }.freeze
  TENANT = "00000000-0000-0000-0000-00000000000a"

  def self.enable!
    # Enabling again replaces each integration (and its provider) in place:
    # the routes drawn once below keep pointing at them.
    Studio::Integrations.all.each(&:uninstall_stand_in!)
    Studio.enable_integration :quickbooks, env: ENV_NAMES[:quickbooks], panel: "admin/integrations/quickbooks_panel"
    Studio.enable_integration :egnyte, env: ENV_NAMES[:egnyte]
    Studio.enable_integration :microsoft_365, env: ENV_NAMES[:microsoft_365]
  end

  def self.draw_routes!
    Rails.application.reload_routes!
    Rails.application.routes.append do
      post "integrations_test_sign_in/:id", to: "integrations_test_sessions#create"
      Studio.draw_integrations_routes(self)
    end
    Rails.application.reload_routes!
  end

  enable!
  draw_routes!

  def with_env(values = ENV_VALUES)
    saved = values.keys.to_h { [_1, ENV[_1]] }
    values.each { |name, value| ENV[name] = value }
    yield
  ensure
    saved.each { |name, value| ENV[name] = value }
  end

  # An http seam on the provider's token endpoints: answers in turn, records each.
  def stub_tokens(integration, *answers)
    requests = []
    queue = answers.dup
    integration.provider.http = lambda do |url, form, headers|
      requests << { url:, form:, headers: }
      queue.shift or raise "the token stub ran out of answers for #{url}"
    end
    requests
  end

  # A seam on the describe call: answers in turn, records each.
  def stub_describe(integration, *answers)
    requests = []
    queue = answers.dup
    integration.api_http = lambda do |url, headers|
      requests << { url:, headers: }
      queue.shift or raise "the describe stub ran out of answers for #{url}"
    end
    requests
  end

  # The app as if its Active Record encryption keys were not set.
  def without_encryption
    Studio::Connections.singleton_class.alias_method(:__ready, :encryption_ready?)
    Studio::Connections.define_singleton_method(:encryption_ready?) { false }
    yield
  ensure
    Studio::Connections.singleton_class.alias_method(:encryption_ready?, :__ready)
  end

  def answer(status = 200, **fields) = [status, fields.to_json]
end
