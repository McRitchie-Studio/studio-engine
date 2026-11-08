# frozen_string_literal: true

# A consuming app, as far as the connections tooling is concerned: the
# engine's studio_connections migration run for real, Active Record encryption
# keys set, a host ApplicationController with Studio::ErrorHandling (so
# rescue_and_log and require_admin are the engine's own), a User, a sign-in
# door, and three GENERIC test providers, one per refresh policy:
#
#   :ledger   a rotating code grant: the account is named on the callback
#             (?account_id=), HTTP Basic client auth, a JSON revoke, a stated
#             refresh-token lifetime; served by the engine's controller
#   :drive    a cached code grant on a per-account host: the admin names the
#             account (a DNS label) before Connect, form client auth, a
#             secret-only revoke, 409 throttling; served by a HOST controller
#             that adds its own show page
#   :tenant   a client-credentials grant behind an admin consent: the account
#             (a GUID) is private, so it is stored encrypted and keyed by a
#             digest; no revoke endpoint; the token lives in memory
#
# None is a real provider; every host is *.example.
#
# Required by test/integration/connections_*_test.rb, each its own process.
require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

ActionDispatch::IntegrationTest.app = Rails.application

ActiveRecord::Encryption.configure(
  primary_key: "connections-host-primary-key-not-a-real-secret",
  deterministic_key: "connections-host-deterministic-key-not-a-real-secret",
  key_derivation_salt: "connections-host-key-derivation-salt-not-a-real-secret"
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

class User < ApplicationRecord
  def admin? = role == "admin"
  def display_name = name.presence || email.to_s.split("@").first
end

class ConnectionsTestSessionsController < ApplicationController
  skip_before_action :require_authentication, raise: false

  def create
    session[Studio.session_key] = params[:id].to_i
    head :ok
  end
end

module Admin
  # A host's own page for a provider: it includes the flow and adds show.
  class DriveController < ApplicationController
    include Studio::ConnectionFlow

    def show
      render plain: "drive page: #{Studio::Connection.readable(:drive).map(&:label).join(', ')}"
    end
  end
end

module ConnectionsHost
  GUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  DNS_LABEL = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
  TENANT = "00000000-0000-0000-0000-0000000000a1"
  ENV_VALUES = {
    "LEDGER_CLIENT_ID" => "ledger-id", "LEDGER_CLIENT_SECRET" => "ledger-secret",
    "DRIVE_CLIENT_ID" => "drive-id", "DRIVE_CLIENT_SECRET" => "drive-secret",
    "TENANT_CLIENT_ID" => "tenant-id", "TENANT_CLIENT_SECRET" => "tenant-secret"
  }.freeze

  # What each provider's describe hook was handed, for the flow tests.
  DESCRIBED = []

  def self.define_providers!
    Studio::Connections.all.each { |provider| provider.sign_in_stand_in = nil; provider.http = nil }
    DESCRIBED.clear

    Studio.define_connection :ledger,
      label: "Ledger",
      env: { client_id: "LEDGER_CLIENT_ID", client_secret: "LEDGER_CLIENT_SECRET" },
      authorize_url: "https://auth.ledger.example/oauth2",
      token_url: "https://auth.ledger.example/oauth2/token",
      revoke_url: "https://auth.ledger.example/oauth2/revoke",
      scopes: %w[ledger.read],
      client_auth: :basic, revoke_format: :json,
      refresh: :rotating, refresh_expires_in_key: "x_refresh_token_expires_in",
      account: :callback, account_param: "account_id", account_format: /\A\d{1,12}\z/,
      filter_keys: %w[account_id],
      describe: lambda { |grant:, account:, provider:|
        DESCRIBED << { provider: provider.key, account:, access_token: grant["access_token"] }
        { label: "Ledger Co #{account}", metadata: { environment: "sandbox" } }
      }

    Studio.define_connection :drive,
      label: "Drive",
      env: { client_id: "DRIVE_CLIENT_ID", client_secret: "DRIVE_CLIENT_SECRET" },
      authorize_url: ->(account) { "https://#{account}.drive.example/oauth/authorize" },
      token_url: ->(account) { "https://#{account}.drive.example/oauth/token" },
      revoke_url: ->(account) { "https://#{account}.drive.example/oauth/revoke" },
      scopes: %w[drive.files], exchange_params: { scope: "drive.files" },
      client_auth: :form, revoke_auth: :secret_only,
      refresh: :cached, refresh_margin: 1.day,
      account: :connect, account_param: "drive_domain", account_format: DNS_LABEL,
      normalize_account: ->(value) { value.to_s.strip.downcase.sub(%r{\Ahttps?://}, "").sub(%r{[/?#].*\z}, "").delete_suffix(".drive.example") },
      rate_limited_statuses: [409, 429], revoked_pattern: /invalid refresh token/i,
      describe: ->(grant:, account:, provider:) { { label: "#{account}.drive.example" } }

    Studio.define_connection :tenant,
      label: "Tenant Suite",
      env: { client_id: "TENANT_CLIENT_ID", client_secret: "TENANT_CLIENT_SECRET" },
      grant: :client_credentials,
      authorize_url: "https://login.tenant.example/common/adminconsent",
      token_url: ->(account) { "https://login.tenant.example/#{account}/oauth2/v2.0/token" },
      scopes: %w[https://api.tenant.example/.default],
      account: :callback, account_param: "tenant", account_format: GUID,
      normalize_account: ->(value) { value.to_s.strip.downcase },
      private_account: true, revoked_errors: %w[unauthorized_client],
      filter_keys: %w[tenant],
      revoke_note: "Remove the app in the tenant's admin center to revoke its access.",
      declined_errors: %w[access_denied consent_required],
      callback_check: ->(params) { "Tenant Suite did not report an approval. Nothing was connected." unless params[:admin_consent].to_s.casecmp?("true") }
  end

  def self.draw_routes!
    Rails.application.reload_routes!
    Rails.application.routes.append do
      post "connections_test_sign_in/:id", to: "connections_test_sessions#create"
      Studio.draw_connection_routes(self, :ledger, path: "admin/ledger", return_to: %w[/admin/ledger /integrations])
      Studio.draw_connection_routes(self, :drive, path: "admin/drive", controller: "admin/drive")
      Studio.draw_connection_routes(self, :tenant, path: "admin/tenant")
    end
    Rails.application.reload_routes!
  end

  define_providers!
  draw_routes!

  def with_env(values = ENV_VALUES)
    saved = values.keys.to_h { [_1, ENV[_1]] }
    values.each { |name, value| ENV[name] = value }
    yield
  ensure
    saved.each { |name, value| ENV[name] = value }
  end

  # An http seam that answers each request from `answers` in turn and records it.
  def stub_http(provider, *answers)
    requests = []
    queue = answers.dup
    provider.http = lambda do |url, form, headers|
      requests << { url:, form:, headers: }
      answer = queue.shift or raise "the stub ran out of answers for #{url}"
      answer.respond_to?(:call) ? answer.call : answer
    end
    requests
  end

  def grant(**fields) = [200, fields.to_json]

  def store(key, account:, **grant_fields)
    Studio::Connection.store!(key, grant_fields.transform_keys(&:to_s), account:, by: "tester")
  end
end
