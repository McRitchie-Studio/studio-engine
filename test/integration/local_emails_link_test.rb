# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

# [integration] /_studio/local_emails — the "Open link" affordance.
#
# WHY THIS EXISTS. The local inbox is how an operator tests a mailed flow on a
# desk that sends nothing externally, so its link is the thing they actually
# click. It was derived by a hardcoded case per mailer, and the entry for
# `email_change_confirmation` was written for turf-monster's mailer: it pointed at
# `/account/email/confirm/` and took `args[1]` as the token.
#
# For the engine's own Studio::ProfileMailer — signature
# `(user, current_email, new_email, token)` — that produced
# `/account/email/confirm/alex%40mcritchie.studio`: the wrong PATH, carrying the
# CURRENT EMAIL ADDRESS where the token belongs. Observed on a live preview stack
# before it was fixed. A dead link in the tool you reach for to check the flow is
# worse than no link, because it reads as the flow being broken.
ActionDispatch::IntegrationTest.app = Rails.application

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  # Mirrors db/migrate/20260614000000_create_studio_email_deliveries.rb — the
  # consuming apps own this table; sqlite takes json where postgres takes jsonb.
  create_table :studio_email_deliveries, force: true do |t|
    t.string   :email_key, null: false
    t.string   :to
    t.string   :mailer, null: false
    t.string   :action, null: false
    t.json     :args,   null: false, default: []
    t.json     :kwargs, null: false, default: {}
    t.boolean  :sent,   null: false, default: false
    t.datetime :sent_at
    t.text     :error
    t.bigint   :user_id
    t.timestamps
  end
end

class ApplicationController < ActionController::Base
end

class LocalEmailsLinkTest < ActionDispatch::IntegrationTest
  TOKEN = "aVerySafeUrlToken_-123"

  def setup
    Studio::EmailDelivery.delete_all
  end

  def record_delivery(email_key, args)
    mailer, action = email_key.split("#")
    Studio::EmailDelivery.create!(
      email_key: email_key, to: "old@example.com",
      mailer: mailer, action: action, args: args, kwargs: {}
    )
  end

  # The regression, stated as the property: the link must carry the TOKEN and
  # point at the engine's own route.
  test "the engine's email-change mail links to /profile with the real token" do
    record_delivery("Studio::ProfileMailer#email_change_confirmation",
                    [nil, "old@example.com", "new@example.com", TOKEN])

    get "/_studio/local_emails"

    assert_response :success
    assert_includes response.body, "/profile/email/confirm/#{TOKEN}"
  end

  test "it does not put the email address where the token belongs" do
    record_delivery("Studio::ProfileMailer#email_change_confirmation",
                    [nil, "old@example.com", "new@example.com", TOKEN])

    get "/_studio/local_emails"

    refute_includes response.body, "/profile/email/confirm/old%40example.com"
    refute_includes response.body, "/account/email/confirm/old%40example.com",
      "this is the exact dead link that shipped — the turf path with the address as the token"
  end

  # turf-monster keeps its own UserMailer and its own /account route. The engine
  # fixing ITS link must not repoint turf's.
  test "a host's own email-change mailer keeps its own /account link" do
    record_delivery("UserMailer#email_change_confirmation", [nil, TOKEN, "new@example.com"])

    get "/_studio/local_emails"

    assert_includes response.body, "/account/email/confirm/#{TOKEN}"
    refute_includes response.body, "/profile/email/confirm/#{TOKEN}"
  end
end
