# frozen_string_literal: true

require_relative "../../test_helper"
require "active_support/core_ext/string/inflections"
require_relative "../../../lib/studio/s3"
require_relative "../../../app/services/studio/email_image"

# [unit] Studio::EmailImage — the transactional-email registry and its two-layer
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
class EmailImageRegistryTest < Minitest::Test
  def setup
    Studio::EmailImage.reset!
    @stubs = []
  end

  def teardown
    @stubs.reverse_each { |mod, name, original| mod.define_singleton_method(name, original) }
    Studio::EmailImage.reset!
  end

  # Hand-rolled singleton stub with ensure-restore (minitest/mock is gone in
  # Minitest 6). Restores in teardown even when the assertion raises.
  def stub_module(mod, name, &replacement)
    @stubs << [mod, name, mod.method(name)]
    mod.define_singleton_method(name, &replacement)
  end

  # --- 1. the engine ships the standard two ---------------------------------

  def test_standard_emails_are_pre_registered_in_display_order
    assert_equal %w[magic_link email_change_confirmation], Studio::EmailImage.keys,
      "every app must inherit the standard two, magic_link first"
  end

  def test_standard_emails_carry_a_label_and_a_default_asset
    entry = Studio::EmailImage.entry("magic_link")

    assert_equal "Magic-link sign-in", entry.label
    assert_equal "emails/magic-link.png", entry.default_asset
    refute_empty entry.description.to_s, "a registered email describes its workflow"
  end

  def test_known_and_label_answer_for_a_standard_email
    assert Studio::EmailImage.known?("magic_link")
    assert Studio::EmailImage.known?(:magic_link), "a symbol key must resolve too"
    refute Studio::EmailImage.known?("nope")
    assert_equal "Email change confirmation", Studio::EmailImage.label("email_change_confirmation")
  end

  def test_label_falls_back_to_a_humanized_key_for_an_unregistered_email
    assert_equal "Wallet export", Studio::EmailImage.label("wallet_export")
  end

  # --- 2. a host registers its own on top -----------------------------------

  def test_a_host_registers_its_own_workflows_after_the_inherited_two
    Studio::EmailImage.register("winnings", label: "Contest winnings",
                                description: "Sent when a player wins.")

    assert_equal %w[magic_link email_change_confirmation winnings], Studio::EmailImage.keys
    assert_equal "Contest winnings", Studio::EmailImage.label("winnings")
  end

  def test_re_registering_an_inherited_key_updates_in_place
    Studio::EmailImage.register("magic_link", label: "Sign in to Turf Monster")

    assert_equal %w[magic_link email_change_confirmation], Studio::EmailImage.keys,
      "a relabel must not append a duplicate or reorder the page"
    assert_equal "Sign in to Turf Monster", Studio::EmailImage.label("magic_link")
    assert_equal "emails/magic-link.png", Studio::EmailImage.entry("magic_link").default_asset,
      "a relabel must keep the inherited default artwork"
  end

  def test_register_defaults_the_label_to_a_humanized_key
    Studio::EmailImage.register("friend_joined_contest")

    assert_equal "Friend joined contest", Studio::EmailImage.label("friend_joined_contest")
  end

  def test_reset_drops_host_registrations_back_to_the_standard_two
    Studio::EmailImage.register("winnings", label: "Contest winnings")
    Studio::EmailImage.reset!

    assert_equal %w[magic_link email_change_confirmation], Studio::EmailImage.keys
  end

  def test_variants_keeps_the_legacy_key_to_label_shape
    assert_equal({ "magic_link" => "Magic-link sign-in",
                   "email_change_confirmation" => "Email change confirmation" },
                 Studio::EmailImage.variants)
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
    stub_module(Studio::EmailImage, :record) { |_key| row }
    stub_module(Studio::EmailImage, :default_asset_path) { |_key| "/assets/emails/magic-link.png" }

    assert_equal :app, Studio::EmailImage.source("magic_link")
    assert Studio::EmailImage.app_owned?("magic_link")
    assert_equal "https://turf-monster-dev.s3.amazonaws.com/email_banners/magic_link-ab12.png",
                 Studio::EmailImage.url("magic_link")
  end

  def test_the_inherited_default_renders_when_the_app_uploaded_nothing
    stub_module(Studio::EmailImage, :record) { |_key| nil }
    stub_module(Studio::EmailImage, :default_asset_path) { |_key| "/assets/emails/magic-link.png" }

    assert_equal :default, Studio::EmailImage.source("magic_link")
    refute Studio::EmailImage.app_owned?("magic_link")
    assert_nil Studio::EmailImage.override_url("magic_link")
  end

  def test_no_image_at_all_is_reported_as_none_not_as_a_default
    stub_module(Studio::EmailImage, :record) { |_key| nil }
    stub_module(Studio::EmailImage, :default_asset_path) { |_key| nil }

    assert_equal :none, Studio::EmailImage.source("magic_link")
    assert_nil Studio::EmailImage.url("magic_link"),
      "a bannerless email resolves to nil so the mailer renders the card without one"
  end

  # --- 5. browser vs inbox addressing of the SAME default -------------------

  def test_preview_url_keeps_a_default_root_relative_for_the_browser
    stub_module(Studio::EmailImage, :record) { |_key| nil }
    stub_module(Studio::EmailImage, :default_asset_path) { |_key| "/assets/emails/magic-link.png" }

    # The admin page is viewed on whatever host+port this app is running on
    # (localhost:3042 in a worktree), so an absolute mailer asset_host would
    # point the preview at the wrong origin.
    assert_equal "/assets/emails/magic-link.png", Studio::EmailImage.preview_url("magic_link")
  end

  def test_url_makes_a_default_absolute_for_the_inbox
    stub_module(Studio::EmailImage, :record) { |_key| nil }
    stub_module(Studio::EmailImage, :default_asset_path) { |_key| "/assets/emails/magic-link.png" }
    stub_module(Studio::EmailImage, :mailer_asset_host) { "https://mcritchie.studio" }

    assert_equal "https://mcritchie.studio/assets/emails/magic-link.png",
                 Studio::EmailImage.url("magic_link")
  end

  def test_url_leaves_an_already_absolute_asset_path_alone
    stub_module(Studio::EmailImage, :record) { |_key| nil }
    stub_module(Studio::EmailImage, :default_asset_path) { |_key| "https://cdn.example.com/assets/emails/magic-link.png" }
    stub_module(Studio::EmailImage, :mailer_asset_host) { "https://mcritchie.studio" }

    assert_equal "https://cdn.example.com/assets/emails/magic-link.png",
                 Studio::EmailImage.url("magic_link"),
      "an asset_host-resolved absolute URL must not be prefixed a second time"
  end

  # --- uploads gate: honest degradation, not a 500 --------------------------

  def test_uploads_are_unavailable_when_the_app_has_no_bucket
    previous = Studio.s3_bucket_prefix
    Studio.s3_bucket_prefix = nil
    stub_module(Studio::EmailImage, :table_ready?) { true }

    refute Studio::EmailImage.uploads_available?,
      "an app with no bucket must report read-only rather than raise on upload"
  ensure
    Studio.s3_bucket_prefix = previous
  end

  def test_uploads_are_available_with_a_bucket_and_the_table_installed
    previous = Studio.s3_bucket_prefix
    Studio.s3_bucket_prefix = "mcritchie-studio"
    stub_module(Studio::EmailImage, :table_ready?) { true }

    assert Studio::EmailImage.uploads_available?
  ensure
    Studio.s3_bucket_prefix = previous
  end

  def test_uploads_are_unavailable_before_the_image_caches_table_exists
    previous = Studio.s3_bucket_prefix
    Studio.s3_bucket_prefix = "mcritchie-studio"
    stub_module(Studio::EmailImage, :table_ready?) { false }

    refute Studio::EmailImage.uploads_available?
  ensure
    Studio.s3_bucket_prefix = previous
  end
end
