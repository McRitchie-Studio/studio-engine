# frozen_string_literal: true

require "test_helper"
require "omniauth"
require "omniauth-google-oauth2"
require "active_support/cache"
require "ipaddr"

# [unit] Studio::GoogleSignIn: is the app's OAuth client configured, does a
# host's own middleware already register Google, and the once-a-day claim behind
# "Request Google setup". The Rack wiring is the integration suites'
# (google_sign_in_ships_ready_test.rb, google_sign_in_host_provider_test.rb).
class GoogleSignInTest < Minitest::Test
  Entry = Struct.new(:klass, :block)

  def setup
    Studio::GoogleSignIn.reset!
  end

  def teardown
    Studio::GoogleSignIn.reset!
  end

  # --- ready? -----------------------------------------------------------------

  def test_ready_needs_both_credentials
    assert Studio::GoogleSignIn.ready?(env: { "GOOGLE_CLIENT_ID" => "id", "GOOGLE_CLIENT_SECRET" => "secret" })
    refute Studio::GoogleSignIn.ready?(env: { "GOOGLE_CLIENT_ID" => "id" })
    refute Studio::GoogleSignIn.ready?(env: { "GOOGLE_CLIENT_SECRET" => "secret" })
    refute Studio::GoogleSignIn.ready?(env: {})
  end

  def test_a_blank_credential_is_not_a_credential
    refute Studio::GoogleSignIn.ready?(env: { "GOOGLE_CLIENT_ID" => "  ", "GOOGLE_CLIENT_SECRET" => "secret" })
    refute Studio::GoogleSignIn.ready?(env: { "GOOGLE_CLIENT_ID" => "id", "GOOGLE_CLIENT_SECRET" => "" })
  end

  def test_credentials_are_stripped_and_blank_reads_nil
    assert_equal ["id", nil], Studio::GoogleSignIn.credentials(env: { "GOOGLE_CLIENT_ID" => " id ", "GOOGLE_CLIENT_SECRET" => " " })
  end

  # Studio.google_ready? is the public spelling; the test helper's Studio mirror
  # does not define it, so the delegation is read from lib/studio.rb itself.
  def test_studio_google_ready_delegates_here
    source = File.read(File.expand_path("../../../lib/studio.rb", __dir__))
    assert_match(/def self\.google_ready\?\(env: ENV\)\n\s+GoogleSignIn\.ready\?\(env: env\)/, source)
  end

  def test_the_redirect_uri_is_the_omniauth_callback_on_the_host
    assert_equal "https://voicebox.example/auth/google_oauth2/callback",
                 Studio::GoogleSignIn.redirect_uri(host: "voicebox.example")
    assert_equal "http://localhost:3500/auth/google_oauth2/callback",
                 Studio::GoogleSignIn.redirect_uri(host: "localhost:3500", scheme: "http")
  end

  # --- whose registration -----------------------------------------------------

  def test_a_builder_whose_block_provides_google_registers_google
    block = proc do
      provider :google_oauth2, ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_CLIENT_SECRET"], scope: "email,profile", prompt: "select_account"
    end

    assert Studio::GoogleSignIn.host_registers_google?([Entry.new(OmniAuth::Builder, block)])
  end

  def test_a_builder_naming_the_strategy_class_registers_google
    block = proc { provider OmniAuth::Strategies::GoogleOauth2, "id", "secret" }

    assert Studio::GoogleSignIn.host_registers_google?([Entry.new(OmniAuth::Builder, block)])
  end

  def test_the_strategy_used_directly_registers_google
    assert Studio::GoogleSignIn.host_registers_google?([Entry.new(OmniAuth::Strategies::GoogleOauth2, nil)])
  end

  def test_a_builder_with_other_providers_only_leaves_google_to_the_engine
    block = proc do
      configure { |config| config.path_prefix = "/auth" }
      provider :developer
      on_failure { |_env| [302, {}, []] }
    end

    refute Studio::GoogleSignIn.host_registers_google?([Entry.new(OmniAuth::Builder, block)])
  end

  def test_a_block_that_cannot_be_read_counts_as_google
    block = proc { raise "needs a constant only the host has" }

    assert Studio::GoogleSignIn.host_registers_google?([Entry.new(OmniAuth::Builder, block)]),
           "doubt resolves toward the host: two strategies on one path is the failure to prevent"
  end

  def test_the_engines_own_middleware_and_unrelated_middleware_do_not_count
    stack = [Entry.new(Studio::GoogleSignIn::Middleware, nil), Entry.new(Rack::Head, nil), Entry.new(OmniAuth::Builder, nil)]

    refute Studio::GoogleSignIn.host_registers_google?(stack)
  end

  def test_with_no_rails_app_the_host_registered_nothing_and_nothing_is_memoized
    refute Studio::GoogleSignIn.host_registered?
    assert_nil Studio::GoogleSignIn.instance_variable_get(:@host_registered)
  end

  def test_the_button_posts_once_ready_and_opens_the_modal_before
    assert Studio::GoogleSignIn.button_posts?(env: { "GOOGLE_CLIENT_ID" => "id", "GOOGLE_CLIENT_SECRET" => "secret" })
    refute Studio::GoogleSignIn.button_posts?(env: {})
  end

  def test_test_mode_makes_the_button_post_and_the_engine_register
    OmniAuth.config.test_mode = true
    assert Studio::GoogleSignIn.button_posts?(env: {})
    assert Studio::GoogleSignIn.engine_registers?(env: {})
    assert_equal :engine, Studio::GoogleSignIn.registration(env: {})
  ensure
    OmniAuth.config.test_mode = false
  end

  def test_no_credentials_and_no_mock_means_nobody_registers
    assert_equal :none, Studio::GoogleSignIn.registration(env: {})
  end

  # --- the canonical host: configuration, never the request ------------------

  def test_canonical_host_prefers_the_configured_setting
    assert_equal "voicebox.mcritchie.studio",
                 Studio::GoogleSignIn.canonical_host(env: { "APP_HOST" => "other.example" },
                                                     configured: "https://Voicebox.McRitchie.Studio/", hosts: ["third.example"])
  end

  def test_canonical_host_falls_back_to_app_host
    assert_equal "app.mcritchie.studio",
                 Studio::GoogleSignIn.canonical_host(env: { "APP_HOST" => "app.mcritchie.studio" }, configured: nil, hosts: ["third.example"])
  end

  def test_canonical_host_then_takes_the_first_plain_hostname_in_config_hosts
    hosts = [IPAddr.new("10.0.0.0/8"), /.*\.herokuapp\.com/, ".mcritchie.studio", "localhost:3000", "Cyvasse.xyz", "www.cyvasse.xyz"]

    assert_equal "cyvasse.xyz", Studio::GoogleSignIn.canonical_host(env: {}, configured: nil, hosts: hosts),
                 "no IPAddr, no Regexp, no leading dot, no port"
  end

  def test_with_nothing_configured_there_is_no_canonical_host
    assert_nil Studio::GoogleSignIn.canonical_host(env: {}, configured: nil, hosts: [])
    assert_nil Studio::GoogleSignIn.canonical_host(env: { "APP_HOST" => "  " }, configured: "", hosts: [".example.com"])
  end

  def test_the_redirect_uri_is_https_in_production
    env = { "APP_HOST" => "voicebox.mcritchie.studio" }

    assert_equal "https://voicebox.mcritchie.studio/auth/google_oauth2/callback",
                 Studio::GoogleSignIn.canonical_redirect_uri(env: env, production: true)
    assert_equal "http://voicebox.mcritchie.studio/auth/google_oauth2/callback",
                 Studio::GoogleSignIn.canonical_redirect_uri(env: env, production: false)
    assert_nil Studio::GoogleSignIn.canonical_redirect_uri(env: {}, production: true)
  end

  def test_full_host_is_pinned_only_in_production_and_only_from_an_explicit_host
    env = { "APP_HOST" => "voicebox.mcritchie.studio" }

    assert_equal "https://voicebox.mcritchie.studio", Studio::GoogleSignIn.pinned_full_host(env: env, production: true)
    assert_nil Studio::GoogleSignIn.pinned_full_host(env: env, production: false), "a desk keeps its own port"
    assert_nil Studio::GoogleSignIn.pinned_full_host(env: {}, production: true)
  end

  def test_allowed_hosts_mirror_config_hosts
    allowed = Studio::GoogleSignIn.allowed_hosts_from(["Cyvasse.xyz", "localhost:3000", ".mcritchie.studio", /qa\.example/])

    assert_includes allowed, "cyvasse.xyz"
    assert_includes allowed, "localhost", "OmniAuth compares bare hosts, so the port is dropped"
    pattern = allowed.find { |entry| entry.is_a?(Regexp) && entry.source.include?("mcritchie") }
    assert_match(/\A(?:#{pattern})\z/, "voicebox.mcritchie.studio")
    assert_match(/\A(?:#{pattern})\z/, "mcritchie.studio")
    refute_match(/\A(?:#{pattern})\z/, "evilmcritchie.studio")
  end

  def test_allowed_hosts_stay_unset_when_config_hosts_admits_everything_or_nothing
    assert_nil Studio::GoogleSignIn.allowed_hosts_from([])
    assert_nil Studio::GoogleSignIn.allowed_hosts_from([IPAddr.new("0.0.0.0/0"), "localhost"])
  end

  def test_seeding_never_overrides_the_apps_own_omniauth_host_config
    OmniAuth.config.allowed_hosts = nil
    OmniAuth.config.full_host = "https://hub.example"
    Studio::GoogleSignIn.seed_allowed_hosts!(hosts: ["cyvasse.xyz"])
    assert_nil OmniAuth.config.allowed_hosts

    OmniAuth.config.full_host = nil
    Studio::GoogleSignIn.seed_allowed_hosts!(hosts: ["cyvasse.xyz"])
    assert_equal ["cyvasse.xyz"], OmniAuth.config.allowed_hosts
  ensure
    OmniAuth.config.full_host = nil
    OmniAuth.config.allowed_hosts = nil
  end

  def test_the_daily_key_is_the_app_not_a_host
    prior = Studio.app_name
    Studio.app_name = "Voice Box!"
    assert_equal "voice-box", Studio::GoogleSignIn.app_key
  ensure
    Studio.app_name = prior
  end

  # --- the once-a-day claim ---------------------------------------------------

  def test_the_first_request_of_the_day_claims_it_and_the_rest_do_not
    store = ActiveSupport::Cache::MemoryStore.new
    today = Date.new(2026, 10, 29)

    assert Studio::GoogleSignIn.claim_daily_request("voicebox.example", store: store, today: today)
    refute Studio::GoogleSignIn.claim_daily_request("voicebox.example", store: store, today: today)
    refute Studio::GoogleSignIn.claim_daily_request("VOICEBOX.example", store: store, today: today), "app keys compare case-insensitively"
  end

  def test_the_claim_is_per_app_and_per_day
    store = ActiveSupport::Cache::MemoryStore.new
    today = Date.new(2026, 10, 29)

    assert Studio::GoogleSignIn.claim_daily_request("voicebox", store: store, today: today)
    assert Studio::GoogleSignIn.claim_daily_request("cyvasse", store: store, today: today)
    assert Studio::GoogleSignIn.claim_daily_request("voicebox", store: store, today: today + 1)
  end

  # A store that ignores unless_exist (as some do) must still rate-limit.
  class ForgetfulUnlessExistStore < ActiveSupport::Cache::MemoryStore
    def write(name, value, options = nil)
      super(name, value, (options || {}).except(:unless_exist))
    end
  end

  def test_a_store_that_ignores_unless_exist_still_limits
    store = ForgetfulUnlessExistStore.new
    today = Date.new(2026, 10, 29)

    assert Studio::GoogleSignIn.claim_daily_request("voicebox.example", store: store, today: today)
    refute Studio::GoogleSignIn.claim_daily_request("voicebox.example", store: store, today: today)
  end

  def test_with_no_usable_app_cache_the_claim_uses_a_store_of_its_own
    store = Studio::GoogleSignIn.request_store

    assert_kind_of ActiveSupport::Cache::MemoryStore, store
    assert_same store, Studio::GoogleSignIn.request_store, "one fallback per process, or it remembers nothing"
  end
end
