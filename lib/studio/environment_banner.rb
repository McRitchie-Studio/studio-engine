# frozen_string_literal: true

module Studio
  # The shared dev/QA environment banner's decisions, as pure Ruby.
  #
  # Every Studio app used to hand-roll its own yellow "<Env> Environment" strip,
  # so no two agreed on when it appeared, what it said, or whether it linked the
  # local email inbox. Those three rules live here and `studio/banners/_environment`
  # renders them, so a host adopts the standard with one `render` call.
  #
  # Dependency-free on purpose: the unit suite requires this file directly, so
  # the tests exercise the SHIPPED rules rather than a copy of them.
  module EnvironmentBanner
    QA_ENV_VAR = "QA_ENV"

    # The engine's local email inbox (Studio::LocalEmailsController).
    INBOX_PATH = "/_studio/local_emails"

    module_function

    # True for stable QA apps. They run Rails in production mode but are
    # non-production REVIEW targets and must say so. The release conductor sets
    # QA_ENV=true on every QA app (mcritchie-studio/config/qa_environments.yml).
    def qa_environment?(env = ENV)
      truthy?(env[QA_ENV_VAR])
    end

    # Show the banner in every environment EXCEPT real production. A QA app is
    # Rails-production but not real production, so QA_ENV re-opens it there.
    def show?(rails_env:, qa_environment: qa_environment?)
      return true unless rails_env.to_s == "production"

      qa_environment
    end

    # "Development Environment" · "QA Environment · Non-production", plus any
    # app-supplied suffix ("Devnet", ...).
    def message(rails_env:, qa_environment: qa_environment?, extra: [])
      head = if qa_environment
               ["QA Environment", "Non-production"]
             else
               ["#{rails_env.to_s.capitalize} Environment"]
             end

      (head + present_parts(extra)).join(" · ")
    end

    def present_parts(extra)
      Array(extra).map(&:to_s).reject { |part| part.strip.empty? }
    end

    def truthy?(value)
      %w[1 true yes on].include?(value.to_s.strip.downcase)
    end
  end
end
