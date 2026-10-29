# frozen_string_literal: true

# A host booted in its own process, in the environment the caller names, to
# answer one question for test/integration/mail_sender_boot_test.rb: does the
# engine refuse a production boot whose ApplicationMailer sends from an
# example.com placeholder (Studio::MailSender), and what sender does an app get
# by default? Rails.env is fixed per process, so production cannot be asked from
# the dummy.
#
# The host is what a consumer is: Action Mailer and Active Record loaded, its own
# config/initializers/studio.rb and (when the case writes one) its own
# app/mailers/application_mailer.rb, the scaffold shadow, all under PROBE_ROOT.
# It records what it booted into PROBE_RESULT, or the boot error.
require "bundler/setup"
require "json"
require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "action_mailer/railtie"
require "importmap-rails"
require "studio"

ROOT = ENV.fetch("PROBE_ROOT")
RESULT = ENV.fetch("PROBE_RESULT")
ENV["DATABASE_URL"] ||= "sqlite3::memory:"

module MailSenderBootProbe
  class Application < ::Rails::Application
    config.root = ROOT
    config.load_defaults 8.1
    config.eager_load = false
    config.secret_key_base = "studio-engine-mail-sender-probe-not-a-real-secret"
    config.logger = ActiveSupport::Logger.new(IO::NULL)
    config.log_level = :fatal
    config.hosts.clear

    assets = ActiveSupport::OrderedOptions.new
    assets.precompile = []
    assets.paths = []
    config.assets = assets
  end
end

def write_result(payload)
  File.write(RESULT, JSON.generate(payload))
end

begin
  Rails.application.initialize!
rescue StandardError => error
  write_result("booted" => false, "error_class" => error.class.name, "error" => error.message)
  exit 0
end

write_result(
  "booted" => true,
  "rails_env" => Rails.env.to_s,
  "mailer_from" => Studio.mailer_from,
  "application_mailer_from" => Studio::MailSender.resolve(ApplicationMailer),
  "user_mailer_from" => Studio::MailSender.resolve(UserMailer)
)
