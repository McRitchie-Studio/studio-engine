# frozen_string_literal: true

require_relative "../../test_helper"
require "active_support/core_ext/string/inflections"
require_relative "../../../lib/studio/s3"
require_relative "../../../app/services/studio/email_catalog"

# [unit] Studio::EmailCatalog — the transactional-email registry and its two-layer
# image resolution (app-owned override -> inherited gem default -> nothing).
#
# What these lock down:
#
#   1. The engine PRE-REGISTERS the two emails every Studio app sends, in
#      display order, so a brand-new host inherits both without declaring
#      anything. "Works from the jump" is this test.
#   2. A host registers its own workflows on top (turf-monster's winnings,
#      wallet_export, …) — Studio::ModelPage.register's precedent — and
#      re-registering an inherited key UPDATES IT IN PLACE rather than appending
#      a duplicate or shuffling the page order.
#   3. Resolution order, which is the whole inheritance contract: this app's own
#      ImageCache row wins; with no row the engine's default gem asset renders;
#      with neither, nil (the mailer sends bannerless, it does not crash).
#   4. source() reports which of those three actually shipped — the bug this
#      work fixes was a page that read ONLY the override and therefore said
#      "No image yet" about an email that was visibly sending a banner.
#   5. preview_url (browser) and url (inbox) differ ONLY in how a default is
#      addressed: root-relative for the admin page, absolute for the mailer.
class EmailCatalogTest < Minitest::Test
  def setup
    Studio::EmailCatalog.reset!
    @stubs = []
  end

  def teardown
    @stubs.reverse_each { |mod, name, original| mod.define_singleton_method(name, original) }
    Studio::EmailCatalog.reset!
  end

  # Hand-rolled singleton stub with ensure-restore (minitest/mock is gone in
  # Minitest 6). Restores in teardown even when the assertion raises.
  def stub_module(mod, name, &replacement)
    @stubs << [mod, name, mod.method(name)]
    mod.define_singleton_method(name, &replacement)
  end

  # --- 1. the engine ships the standard two ---------------------------------

  def test_standard_emails_are_pre_registered_in_display_order
    assert_equal %w[magic_link email_change_confirmation], Studio::EmailCatalog.keys,
      "every app must inherit the standard two, magic_link first"
  end

  def test_standard_emails_carry_a_label_and_a_default_asset
    entry = Studio::EmailCatalog.entry("magic_link")

    assert_equal "Magic-link sign-in", entry.label
    assert_equal "emails/magic-link.png", entry.default_asset
    refute_empty entry.description.to_s, "a registered email describes its workflow"
  end

  def test_known_and_label_answer_for_a_standard_email
    assert Studio::EmailCatalog.known?("magic_link")
    assert Studio::EmailCatalog.known?(:magic_link), "a symbol key must resolve too"
    refute Studio::EmailCatalog.known?("nope")
    assert_equal "Email change confirmation", Studio::EmailCatalog.label("email_change_confirmation")
  end

  def test_label_falls_back_to_a_humanized_key_for_an_unregistered_email
    assert_equal "Wallet export", Studio::EmailCatalog.label("wallet_export")
  end

  # --- 2. a host registers its own on top -----------------------------------

  def test_a_host_registers_its_own_workflows_after_the_inherited_two
    Studio::EmailCatalog.register("winnings", label: "Contest winnings",
                                description: "Sent when a player wins.")

    assert_equal %w[magic_link email_change_confirmation winnings], Studio::EmailCatalog.keys
    assert_equal "Contest winnings", Studio::EmailCatalog.label("winnings")
  end

  def test_re_registering_an_inherited_key_updates_in_place
    Studio::EmailCatalog.register("magic_link", label: "Sign in to Turf Monster")

    assert_equal %w[magic_link email_change_confirmation], Studio::EmailCatalog.keys,
      "a relabel must not append a duplicate or reorder the page"
    assert_equal "Sign in to Turf Monster", Studio::EmailCatalog.label("magic_link")
    assert_equal "emails/magic-link.png", Studio::EmailCatalog.entry("magic_link").default_asset,
      "a relabel must keep the inherited default artwork"
  end

  def test_register_defaults_the_label_to_a_humanized_key
    Studio::EmailCatalog.register("friend_joined_contest")

    assert_equal "Friend joined contest", Studio::EmailCatalog.label("friend_joined_contest")
  end

  def test_reset_drops_host_registrations_back_to_the_standard_two
    Studio::EmailCatalog.register("winnings", label: "Contest winnings")
    Studio::EmailCatalog.reset!

    assert_equal %w[magic_link email_change_confirmation], Studio::EmailCatalog.keys
  end

  def test_variants_keeps_the_legacy_key_to_label_shape
    assert_equal({ "magic_link" => "Magic-link sign-in",
                   "email_change_confirmation" => "Email change confirmation" },
                 Studio::EmailCatalog.variants)
  end

  # --- 3 + 4. resolution order and the source it reports --------------------

  # A stand-in for the app's own ImageCache row. Built OUTSIDE the stub block —
  # a define_singleton_method block runs with self = the stubbed module, where
  # this helper is not in scope.
  def app_row(url)
    Object.new.tap { |row| row.define_singleton_method(:url) { url } }
  end

  def test_an_app_owned_override_wins_over_the_inherited_default
    row = app_row("https://turf-monster-dev.s3.amazonaws.com/email_banners/magic_link-ab12.png")
    stub_module(Studio::EmailCatalog, :record) { |_key| row }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |_key| "/assets/emails/magic-link.png" }

    assert_equal :app, Studio::EmailCatalog.source("magic_link")
    assert Studio::EmailCatalog.app_owned?("magic_link")
    assert_equal "https://turf-monster-dev.s3.amazonaws.com/email_banners/magic_link-ab12.png",
                 Studio::EmailCatalog.resolved_url("magic_link")
  end

  def test_the_inherited_default_renders_when_the_app_uploaded_nothing
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |_key| "/assets/emails/magic-link.png" }
    stub_module(Studio::EmailCatalog, :mailer_asset_host) { "https://mcritchie.studio" }

    assert_equal :default, Studio::EmailCatalog.source("magic_link")
    refute Studio::EmailCatalog.app_owned?("magic_link")
    assert_equal "https://mcritchie.studio/assets/emails/magic-link.png",
                 Studio::EmailCatalog.resolved_url("magic_link")
  end

  def test_no_image_at_all_is_reported_as_none_not_as_a_default
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |_key| nil }

    assert_equal :none, Studio::EmailCatalog.source("magic_link")
    assert_nil Studio::EmailCatalog.resolved_url("magic_link"),
      "a bannerless email resolves to nil so the mailer renders the card without one"
  end

  # --- THE COMPATIBILITY CONTRACT -------------------------------------------
  #
  # REGRESSION GUARD, and the most important test in this file.
  #
  # `url` predates the registry and has always meant "this app's own image, or
  # nil" — callers were written to fall back themselves. turf-monster's mailer
  # today is literally:
  #
  #   Studio::EmailCatalog.url(:magic_link) || email_banner_url("magic-link-banner.jpg")
  #
  # The first cut of this work made `url` resolve to the engine default. Same
  # signature, same arity, no deprecation — and that `||` became dead code, so
  # turf-monster's committed 1200x600 branded banner would have been silently
  # replaced by the engine's PLACEHOLDER GRADIENT in real sign-in email. The
  # engine suite was green; only reading the consumer's call site caught it.
  #
  # If someone "simplifies" url into resolved_url again, this goes red.
  def test_url_returns_nil_when_this_app_uploaded_nothing_even_with_a_default
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |_key| "/assets/emails/magic-link.png" }

    assert_nil Studio::EmailCatalog.url("magic_link"),
      "url() must keep its pre-registry contract — a host's own `url(...) || its_own_asset` " \
      "fallback is load-bearing, and resolving here would swap its artwork for the placeholder"
  end

  def test_url_returns_this_apps_own_image_when_there_is_one
    row = app_row("https://turf-monster-dev.s3.amazonaws.com/email_banners/magic_link-ab12.png")
    stub_module(Studio::EmailCatalog, :record) { |_key| row }

    assert_equal "https://turf-monster-dev.s3.amazonaws.com/email_banners/magic_link-ab12.png",
                 Studio::EmailCatalog.url("magic_link")
  end

  # --- 5. browser vs inbox addressing of the SAME default -------------------

  def test_preview_url_keeps_a_default_root_relative_for_the_browser
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |_key| "/assets/emails/magic-link.png" }

    # The admin page is viewed on whatever host+port this app is running on
    # (localhost:3042 in a worktree), so an absolute mailer asset_host would
    # point the preview at the wrong origin.
    assert_equal "/assets/emails/magic-link.png", Studio::EmailCatalog.preview_url("magic_link")
  end

  def test_resolved_url_makes_a_default_absolute_for_the_inbox
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |_key| "/assets/emails/magic-link.png" }
    stub_module(Studio::EmailCatalog, :mailer_asset_host) { "https://mcritchie.studio" }

    assert_equal "https://mcritchie.studio/assets/emails/magic-link.png",
                 Studio::EmailCatalog.resolved_url("magic_link")
  end

  def test_resolved_url_leaves_an_already_absolute_asset_path_alone
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |_key| "https://cdn.example.com/assets/emails/magic-link.png" }
    stub_module(Studio::EmailCatalog, :mailer_asset_host) { "https://mcritchie.studio" }

    assert_equal "https://cdn.example.com/assets/emails/magic-link.png",
                 Studio::EmailCatalog.resolved_url("magic_link"),
      "an asset_host-resolved absolute URL must not be prefixed a second time"
  end

  # --- the asset origin a banner URL hangs off ------------------------------
  #
  # REGRESSION GUARD. mailer_asset_host used to read default_url_options[:host]
  # and prefix "https://", dropping the port and forcing TLS. On a worktree stack
  # ({host: "localhost", port: 3001}) that produced https://localhost/... and the
  # banner in every preview came back ERR_CONNECTION_REFUSED. The engine suite was
  # green; opening the page is what showed it.

  # The two pure helpers that carry all of the logic. mailer_asset_host itself
  # needs a booted ActionMailer, so its end-to-end assembly is covered in
  # test/integration/emails_page_test.rb rather than re-implemented here.

  def test_a_local_stack_keeps_its_port
    assert_equal ":3001", Studio::EmailImage.mailer_port_suffix(host: "localhost", port: 3001)
  end

  def test_loopback_defaults_to_http_not_https
    assert_equal "http", Studio::EmailImage.mailer_protocol({ port: 3042 }, "127.0.0.1")
    assert_equal "http", Studio::EmailImage.mailer_protocol({ port: 3001 }, "localhost")
  end

  def test_a_real_host_still_defaults_to_https
    # Production apps set only {host: "mcritchie.studio"}; defaulting to http
    # would downgrade every image in their email.
    assert_equal "https", Studio::EmailImage.mailer_protocol({}, "mcritchie.studio")
  end

  def test_default_ports_are_left_off
    assert_equal "", Studio::EmailImage.mailer_port_suffix(host: "mcritchie.studio", port: 443)
    assert_equal "", Studio::EmailImage.mailer_port_suffix(host: "example.test", port: 80)
    assert_equal "", Studio::EmailImage.mailer_port_suffix(host: "example.test")
  end

  def test_an_explicit_protocol_wins_over_the_loopback_default
    assert_equal "https", Studio::EmailImage.mailer_protocol({ protocol: "https" }, "localhost")
  end

  def test_protocol_with_a_trailing_separator_is_normalized
    assert_equal "https", Studio::EmailImage.mailer_protocol({ protocol: "https://" }, "example.test")
  end

  # --- uploads gate: honest degradation, not a 500 --------------------------

  def test_uploads_are_unavailable_when_the_app_has_no_bucket
    previous = Studio.s3_bucket_prefix
    Studio.s3_bucket_prefix = nil
    stub_module(Studio::EmailCatalog, :table_ready?) { true }

    refute Studio::EmailCatalog.uploads_available?,
      "an app with no bucket must report read-only rather than raise on upload"
  ensure
    Studio.s3_bucket_prefix = previous
  end

  def test_uploads_are_available_with_a_bucket_and_the_table_installed
    previous = Studio.s3_bucket_prefix
    Studio.s3_bucket_prefix = "mcritchie-studio"
    stub_module(Studio::EmailCatalog, :table_ready?) { true }

    assert Studio::EmailCatalog.uploads_available?
  ensure
    Studio.s3_bucket_prefix = previous
  end

  def test_uploads_are_unavailable_before_the_image_caches_table_exists
    previous = Studio.s3_bucket_prefix
    Studio.s3_bucket_prefix = "mcritchie-studio"
    stub_module(Studio::EmailCatalog, :table_ready?) { false }

    refute Studio::EmailCatalog.uploads_available?
  ensure
    Studio.s3_bucket_prefix = previous
  end
end
