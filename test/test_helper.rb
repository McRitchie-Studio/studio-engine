# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"

# Load ActiveSupport for mattr_accessor, symbolize_keys, etc.
require "active_support"
require "active_support/concern"
require "active_support/core_ext/module/attribute_accessors"
require "active_support/core_ext/hash/keys"
require "active_support/core_ext/numeric/time"
require "active_support/core_ext/object/blank"

# Load the Studio module and pure-Ruby lib classes.
# We skip requiring "studio/engine" since that needs a full Rails app.
require_relative "../lib/studio/version"
require_relative "../lib/studio/color_scale"
require_relative "../lib/studio/environment_banner"
require_relative "../lib/studio/sidebar_sections"
require_relative "../lib/studio/theme_resolver"
require_relative "../lib/studio/ui_primitives"
require_relative "../lib/studio/email"
require_relative "../lib/studio/email_smoke"
require_relative "../lib/studio/redis"
require_relative "../lib/studio/cable"

# Model-page protocol PORO. Lives under app/models (Zeitwerk-autoloaded in host
# apps so initializers can register models) but is dependency-free, so the
# pure-Ruby unit suite requires it directly.
require_relative "../app/models/studio/model_page"

# Define Studio module attributes without requiring the engine.
# This mirrors lib/studio.rb but avoids the Rails engine dependency.
module Studio
  mattr_accessor :app_name,            default: "Studio"
  mattr_accessor :session_key,         default: :user_id
  mattr_accessor :welcome_message,     default: ->(user) { "Welcome, #{user.display_name}!" }
  mattr_accessor :registration_params, default: [:name, :email, :password, :password_confirmation]
  mattr_accessor :configure_new_user,  default: ->(user) {}
  mattr_accessor :configure_sso_user,  default: ->(user) {}
  mattr_accessor :sso_logo,            default: nil
  mattr_accessor :wallet_address_method, default: nil
  mattr_accessor :theme_logos,         default: []
  mattr_accessor :sticky_table_headers, default: false
  mattr_accessor :smooth_load,          default: false
  mattr_accessor :nav_spinner_min_ms,   default: 2500
  mattr_accessor :sidebar_sections,     default: []

  mattr_accessor :theme_primary,  default: "#8E82FE"
  mattr_accessor :theme_dark,     default: "#1A1535"
  mattr_accessor :theme_light,    default: "#f8fafc"
  mattr_accessor :theme_success,  default: "#4BAF50"
  mattr_accessor :theme_warning,  default: "#FF7C47"
  mattr_accessor :theme_danger,   default: "#EF4444"
  mattr_accessor :theme_accent,   default: "#F72585"
  mattr_accessor :mailer_from, default: nil
  mattr_accessor :resend_mailer_from, default: "McRitchie Studio <team@mcritchie.studio>"
  mattr_accessor :local_email_capture, default: nil
  mattr_accessor :impersonation_target_session_key, default: :impersonated_user_id
  mattr_accessor :impersonation_actor_session_key,  default: :true_admin_id
  mattr_accessor :impersonation_started_at_session_key, default: :impersonation_started_at
  mattr_accessor :impersonation_max_minutes, default: 30

  def self.configure
    yield self
  end

  def self.sidebar_sections_for(view)
    SidebarSections.resolve(sidebar_sections, view)
  end

  def self.mailer_from_for_transport(env: ENV, ses_from:, resend_from: nil)
    if ses_transport_ready?(env)
      env_value(env, "MAILER_FROM") || ses_from
    else
      env_value(env, "RESEND_MAILER_FROM") || resend_from || resend_mailer_from
    end
  end

  def self.marketing_from_for_transport(env: ENV, ses_from:, resend_from: nil)
    if ses_transport_ready?(env)
      env_value(env, "MARKETING_MAILER_FROM") || ses_from
    else
      env_value(env, "RESEND_MARKETING_FROM") ||
        env_value(env, "RESEND_MAILER_FROM") ||
        resend_from ||
        resend_mailer_from
    end
  end

  def self.ses_transport_ready?(env = ENV)
    env["MAIL_TRANSPORT"].to_s.downcase == "ses" &&
      env_value(env, "SES_SMTP_USERNAME") &&
      env_value(env, "SES_SMTP_PASSWORD")
  end

  def self.env_value(env, key)
    value = env[key]
    value if value && !value.to_s.strip.empty?
  end

  def self.local_email_capture?
    return !!local_email_capture unless local_email_capture.nil?

    env_truthy?(ENV["LOCAL_EMAIL_CAPTURE"]) || env_truthy?(ENV["AGENT_WORKTREE"])
  end

  def self.user_wallet_address(user)
    return nil unless user

    [wallet_address_method, :wallet_address, :solana_address].compact.each do |method|
      next unless user.respond_to?(method)

      value = user.public_send(method)
      return value if value && !(value.respond_to?(:empty?) && value.empty?)
    end

    nil
  end

  def self.theme_config
    {
      primary: theme_primary,
      dark:    theme_dark,
      light:   theme_light,
      success: theme_success,
      warning: theme_warning,
      danger:  theme_danger,
      accent:  theme_accent
    }.compact
  end

  def self.env_truthy?(value)
    %w[1 true yes on].include?(value.to_s.strip.downcase)
  end
end
