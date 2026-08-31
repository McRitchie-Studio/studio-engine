# frozen_string_literal: true

require "bundler/setup"
ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"
require "minitest/autorun"
require "active_support/test_case"

# [integration] Studio.routes draws each auth route group from the app's OWN
# declaration, so a web2 app can drop wallet sign-in while keeping magic-link.
#
# This is a cross-app contract, and the failure mode it guards is a boot-time
# one: a consumer that loses a route it still references does not fail a test,
# it fails to start. Three consumers sit on three different configurations —
# mcritchie-studio (magic_link google wallet, no features), turf-monster
# (draw_auth_routes false, its own routes), mcritchie-industries (magic_link
# only) — and nothing pinned the property they each depend on until this file.
#
# The assertions read the drawn route TABLE rather than a source string, so a
# comment naming `auth/solana/nonce` cannot satisfy them.
class AuthRouteGatingTest < ActiveSupport::TestCase
  SOLANA_ROUTE_NAMES = %w[solana_nonce solana_verify phantom_callback].freeze

  def setup
    @original_auth_methods    = Studio.auth_methods
    @original_draw_auth       = Studio.draw_auth_routes
    @original_features        = Studio.features
  end

  def teardown
    Studio.auth_methods    = @original_auth_methods
    Studio.draw_auth_routes = @original_draw_auth
    Studio.features        = @original_features
    Rails.application.reload_routes!
  end

  # Redraw the host route table under a given configuration and return the set
  # of drawn route names. reload_routes! re-evaluates test/dummy/config/routes.rb,
  # which calls Studio.routes(self) exactly as a consuming app does.
  def drawn_route_names(auth_methods:, draw_auth_routes: true, features: [])
    Studio.auth_methods     = auth_methods
    Studio.draw_auth_routes = draw_auth_routes
    Studio.features         = features
    Rails.application.reload_routes!
    Rails.application.routes.routes.map { |r| r.name }.compact.to_set
  end

  def drawn_paths
    Rails.application.routes.routes.map { |r| r.path.spec.to_s }
  end

  # --- the base template is web2 --------------------------------------------

  # The engine default must not publish Solana endpoints. They are public
  # (skip_before_action :require_authentication) and #verify lands in
  # User.from_solana_wallet, which validate_user_contract! never requires a host
  # to implement — so a newsletter app inheriting them is the exact wrong default.
  test "the auth_methods default draws no solana routes" do
    refute_includes Studio.auth_methods, :wallet,
                    "the base template ships web2: :wallet must be opt-in"

    names = drawn_route_names(auth_methods: Studio.auth_methods)

    SOLANA_ROUTE_NAMES.each do |route_name|
      refute_includes names, route_name, "#{route_name} must not draw on a default app"
    end
    assert_includes names, "magic_link_request", "the default app still signs in by magic link"
  end

  # --- the acceptance criterion ---------------------------------------------

  # The property drop-hub-wallet-auth depends on: dropping :wallet removes the
  # Solana trio and leaves magic-link standing. If these two ever coupled, a web2
  # app could only shed Solana by also losing the sign-in method it actually uses.
  test "dropping wallet removes the solana routes and keeps magic link" do
    with_wallet = drawn_route_names(auth_methods: %i[magic_link google wallet])
    SOLANA_ROUTE_NAMES.each { |n| assert_includes with_wallet, n }

    without_wallet = drawn_route_names(auth_methods: %i[magic_link google])

    SOLANA_ROUTE_NAMES.each do |route_name|
      refute_includes without_wallet, route_name
    end
    assert_includes without_wallet, "magic_link_request",
                    "magic-link must survive dropping :wallet"
  end

  # mcritchie-industries' configuration, end to end.
  test "a magic-link-only app draws magic link and no wallet paths" do
    drawn_route_names(auth_methods: %i[magic_link])
    paths = drawn_paths

    assert_includes paths, "/magic_link(.:format)"
    refute paths.any? { |p| p.include?("/auth/solana/") },
           "a magic-link-only app must publish no /auth/solana/* path"
    refute paths.any? { |p| p.include?("/auth/phantom/") },
           "a magic-link-only app must publish no /auth/phantom/* path"
  end

  # --- the wallet app --------------------------------------------------------

  test "declaring wallet draws all three solana paths" do
    drawn_route_names(auth_methods: %i[magic_link google wallet])
    paths = drawn_paths

    assert_includes paths, "/auth/solana/nonce(.:format)"
    assert_includes paths, "/auth/solana/verify(.:format)"
    assert_includes paths, "/auth/phantom/callback(.:format)"
  end

  # The gate is auth_methods ALONE, deliberately — features gates product
  # surfaces, auth_methods gates the credential exchange. Pinned so that adding
  # `&& Studio.feature?(:web3)` to the route block flips a RED test with this
  # rationale attached, rather than silently removing a live consumer's routes.
  test "wallet routes draw on auth_methods without the web3 feature" do
    names = drawn_route_names(auth_methods: %i[magic_link google wallet], features: [])

    SOLANA_ROUTE_NAMES.each do |route_name|
      assert_includes names, route_name,
                      "#{route_name} is gated on auth_methods, not on feature?(:web3)"
    end
  end

  # --- turf-monster is unaffected either way ---------------------------------

  # turf-monster sets draw_auth_routes = false and draws its own battle-tested
  # magic_link/solana routes. The outer switch must suppress BOTH engine groups
  # no matter what auth_methods says, or turf boots into duplicate route names.
  test "draw_auth_routes false suppresses both groups whatever auth_methods says" do
    names = drawn_route_names(auth_methods: %i[magic_link google wallet],
                              draw_auth_routes: false,
                              features: %i[web3 leveling])

    SOLANA_ROUTE_NAMES.each do |route_name|
      refute_includes names, route_name, "#{route_name} must be left to the host"
    end
    refute_includes names, "magic_link_request", "magic_link must be left to the host"
  end

  # The /l/<token> pair is drawn for EVERY consumer, including draw_auth_routes
  # =false apps. turf-monster relies on that, so it is part of the same contract.
  test "link routes still draw when draw_auth_routes is false" do
    names = drawn_route_names(auth_methods: %i[magic_link google wallet],
                              draw_auth_routes: false)

    assert_includes names, "link"
    assert_includes names, "link_consume"
  end
end
