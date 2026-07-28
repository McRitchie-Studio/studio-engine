# frozen_string_literal: true

require_relative "../test_helper"

class StudioTest < Minitest::Test
  def setup
    # Reset all config to defaults before each test
    Studio.app_name            = "Studio"
    Studio.session_key         = :user_id
    Studio.registration_params = [:name, :email, :password, :password_confirmation]
    Studio.sso_logo            = nil
    Studio.wallet_address_method = nil
    Studio.theme_logos         = []
    Studio.sticky_table_headers = false
    Studio.theme_primary       = "#8E82FE"
    Studio.theme_dark          = "#1A1535"
    Studio.theme_light         = "#f8fafc"
    Studio.theme_success       = "#4BAF50"
    Studio.theme_warning       = "#FF7C47"
    Studio.theme_danger        = "#EF4444"
    Studio.theme_accent        = "#F72585"
    Studio.mailer_from         = nil
    Studio.resend_mailer_from  = "McRitchie Studio <team@mcritchie.studio>"
    Studio.local_email_capture = nil
    ENV.delete("LOCAL_EMAIL_CAPTURE")
    ENV.delete("AGENT_WORKTREE")
    ENV.delete("MAIL_TRANSPORT")
    ENV.delete("MAILER_FROM")
    ENV.delete("MARKETING_MAILER_FROM")
    ENV.delete("RESEND_MAILER_FROM")
    ENV.delete("RESEND_MARKETING_FROM")
    ENV.delete("SES_SMTP_USERNAME")
    ENV.delete("SES_SMTP_PASSWORD")
  end

  # ── configure ───────────────────────────────────────────────

  def test_configure_yields_studio_module
    yielded = nil
    Studio.configure { |config| yielded = config }
    assert_equal Studio, yielded
  end

  def test_configure_sets_app_name
    Studio.configure { |config| config.app_name = "Turf Monster" }
    assert_equal "Turf Monster", Studio.app_name
  end

  def test_configure_sets_session_key
    Studio.configure { |config| config.session_key = :turf_user_id }
    assert_equal :turf_user_id, Studio.session_key
  end

  def test_configure_sets_theme_primary
    Studio.configure { |config| config.theme_primary = "#4BAF50" }
    assert_equal "#4BAF50", Studio.theme_primary
  end

  def test_configure_sets_sso_logo
    Studio.configure { |config| config.sso_logo = "/studio-logo.svg" }
    assert_equal "/studio-logo.svg", Studio.sso_logo
  end

  def test_configure_sets_theme_logos
    logos = [{ file: "favicon.png", title: "Favicon" }]
    Studio.configure { |config| config.theme_logos = logos }
    assert_equal logos, Studio.theme_logos
  end

  def test_configure_enables_sticky_table_headers
    Studio.configure { |config| config.sticky_table_headers = true }
    assert_equal true, Studio.sticky_table_headers
  end

  # ── default values ──────────────────────────────────────────

  def test_default_app_name
    assert_equal "Studio", Studio.app_name
  end

  def test_default_session_key
    assert_equal :user_id, Studio.session_key
  end

  def test_default_registration_params
    assert_equal [:name, :email, :password, :password_confirmation], Studio.registration_params
  end

  def test_default_sso_logo
    assert_nil Studio.sso_logo
  end

  def test_default_wallet_address_method
    assert_nil Studio.wallet_address_method
  end

  def test_default_theme_logos
    assert_equal [], Studio.theme_logos
  end

  def test_default_sticky_table_headers
    refute Studio.sticky_table_headers
  end

  def test_default_theme_primary
    assert_equal "#8E82FE", Studio.theme_primary
  end

  def test_default_theme_dark
    assert_equal "#1A1535", Studio.theme_dark
  end

  def test_default_theme_light
    assert_equal "#f8fafc", Studio.theme_light
  end

  def test_default_theme_success
    assert_equal "#4BAF50", Studio.theme_success
  end

  def test_default_theme_warning
    assert_equal "#FF7C47", Studio.theme_warning
  end

  def test_default_theme_danger
    assert_equal "#EF4444", Studio.theme_danger
  end

  def test_default_theme_accent
    assert_equal "#F72585", Studio.theme_accent
  end

  def test_default_welcome_message_is_callable
    assert_respond_to Studio.welcome_message, :call
  end

  def test_default_configure_new_user_is_callable
    assert_respond_to Studio.configure_new_user, :call
  end

  def test_default_configure_sso_user_is_callable
    assert_respond_to Studio.configure_sso_user, :call
  end

  def test_local_email_capture_defaults_off
    refute Studio.local_email_capture?
  end

  # Studio.local_tool_enabled? — the gate under the developer-desk tools — is
  # unit-tested in test/integration/local_review_endpoint_test.rb instead of
  # here. This suite runs without Rails, so it exercises the hand-written mirror
  # of the Studio module in test_helper.rb; a gate asserted against the mirror
  # would pass while the shipped lib/studio.rb was broken.

  def test_local_email_capture_turns_on_for_agent_worktree
    ENV["AGENT_WORKTREE"] = "1"
    assert Studio.local_email_capture?
  ensure
    ENV.delete("AGENT_WORKTREE")
  end

  def test_local_email_capture_env_overrides_auto
    ENV["LOCAL_EMAIL_CAPTURE"] = "true"
    assert Studio.local_email_capture?
  ensure
    ENV.delete("LOCAL_EMAIL_CAPTURE")
  end

  def test_local_email_capture_config_override_wins
    ENV["AGENT_WORKTREE"] = "1"
    Studio.local_email_capture = false
    refute Studio.local_email_capture?
  ensure
    ENV.delete("AGENT_WORKTREE")
    Studio.local_email_capture = nil
  end

  def test_mailer_from_for_transport_uses_ses_sender_when_ses_is_ready
    env = {
      "MAIL_TRANSPORT" => "ses",
      "SES_SMTP_USERNAME" => "user",
      "SES_SMTP_PASSWORD" => "pass",
      "MAILER_FROM" => "Turf Monster <team@turfmonster.media>"
    }

    assert_equal "Turf Monster <team@turfmonster.media>",
                 Studio.mailer_from_for_transport(env: env, ses_from: "App <team@example.com>")
  end

  def test_mailer_from_for_transport_uses_resend_sender_when_ses_is_not_ready
    env = {
      "MAIL_TRANSPORT" => "ses",
      "MAILER_FROM" => "Turf Monster <team@turfmonster.media>",
      "RESEND_MAILER_FROM" => "McRitchie Studio <team@mcritchie.studio>"
    }

    assert_equal "McRitchie Studio <team@mcritchie.studio>",
                 Studio.mailer_from_for_transport(env: env, ses_from: "Turf Monster <team@turfmonster.media>")
  end

  def test_mailer_from_for_transport_defaults_to_shared_resend_sender
    assert_equal "McRitchie Studio <team@mcritchie.studio>",
                 Studio.mailer_from_for_transport(env: {}, ses_from: "App <team@example.com>")
  end

  def test_marketing_from_for_transport_uses_marketing_sender_when_ses_is_ready
    env = {
      "MAIL_TRANSPORT" => "ses",
      "SES_SMTP_USERNAME" => "user",
      "SES_SMTP_PASSWORD" => "pass",
      "MARKETING_MAILER_FROM" => "Alex from Turf Monster <alex@turfmonster.media>"
    }

    assert_equal "Alex from Turf Monster <alex@turfmonster.media>",
                 Studio.marketing_from_for_transport(env: env, ses_from: "Alex <alex@example.com>")
  end

  def test_marketing_from_for_transport_uses_shared_resend_sender_for_fallback
    env = {
      "RESEND_MAILER_FROM" => "McRitchie Studio <team@mcritchie.studio>",
      "MARKETING_MAILER_FROM" => "Alex from Turf Monster <alex@turfmonster.media>"
    }

    assert_equal "McRitchie Studio <team@mcritchie.studio>",
                 Studio.marketing_from_for_transport(env: env, ses_from: "Alex from Turf Monster <alex@turfmonster.media>")
  end

  def test_user_wallet_address_uses_wallet_address_by_default
    user = Struct.new(:wallet_address).new("Wallet111")
    assert_equal "Wallet111", Studio.user_wallet_address(user)
  end

  def test_user_wallet_address_falls_back_to_solana_address
    user = Struct.new(:solana_address).new("Solana111")
    assert_equal "Solana111", Studio.user_wallet_address(user)
  end

  def test_user_wallet_address_uses_configured_method_first
    user = Struct.new(:wallet_address, :custom_wallet).new("Wallet111", "Custom111")
    Studio.wallet_address_method = :custom_wallet

    assert_equal "Custom111", Studio.user_wallet_address(user)
  ensure
    Studio.wallet_address_method = nil
  end

  def test_user_wallet_address_skips_blank_values
    user = Struct.new(:wallet_address, :solana_address).new("", "Solana111")
    assert_equal "Solana111", Studio.user_wallet_address(user)
  end

  # ── theme_config ────────────────────────────────────────────

  def test_theme_config_returns_hash
    config = Studio.theme_config
    assert_kind_of Hash, config
  end

  def test_theme_config_has_all_role_keys
    config = Studio.theme_config
    %i[primary dark light success warning danger accent].each do |role|
      assert config.key?(role), "Missing role key: #{role}"
    end
  end

  def test_theme_config_returns_current_values
    config = Studio.theme_config
    assert_equal "#8E82FE", config[:primary]
    assert_equal "#1A1535", config[:dark]
    assert_equal "#f8fafc", config[:light]
    assert_equal "#4BAF50", config[:success]
    assert_equal "#FF7C47", config[:warning]
    assert_equal "#EF4444", config[:danger]
    assert_equal "#F72585", config[:accent]
  end

  def test_theme_config_reflects_configure_changes
    Studio.configure do |config|
      config.theme_primary = "#4BAF50"
      config.theme_accent  = "#8E82FE"
    end
    result = Studio.theme_config
    assert_equal "#4BAF50", result[:primary]
    assert_equal "#8E82FE", result[:accent]
  end

  def test_theme_config_compacts_nil_values
    Studio.theme_accent = nil
    config = Studio.theme_config
    refute config.key?(:accent), "nil accent should be compacted out"
  end

  def test_theme_config_keeps_non_nil_values
    Studio.theme_accent = "#F72585"
    config = Studio.theme_config
    assert_equal "#F72585", config[:accent]
  end

  # ── version ─────────────────────────────────────────────────

  def test_version_is_defined
    assert_kind_of String, Studio::VERSION
    refute Studio::VERSION.empty?
  end

  def test_version_format
    assert_match(/\A\d+\.\d+\.\d+\z/, Studio::VERSION, "Version should be semver format")
  end
end
