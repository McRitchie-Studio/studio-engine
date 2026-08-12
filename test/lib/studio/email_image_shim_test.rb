# frozen_string_literal: true

require_relative "../../test_helper"
require "active_support/core_ext/string/inflections"
require_relative "../../../lib/studio/s3"
require_relative "../../../app/services/studio/email_catalog"
require_relative "../../../app/services/studio/email_image"

# [unit] Studio::EmailImage — the deprecated name, kept as a delegating shim.
#
# This is a COMPATIBILITY test, not a feature test. Two audiences depend on the
# old name and neither can be fixed from inside an engine PR:
#
#   1. Any app already on engine 0.33, where Studio::EmailImage WAS the registry.
#   2. consumer-ci.yml, which runs each consumer's DEFAULT BRANCH suite against
#      an engine PR. mcritchie-studio's test/integration/studio_email_image_test.rb
#      on `main` calls .url, .store and .record directly today. Dropping any of
#      them reddens that lane the moment the PR opens.
#
# So the shim's surface is asserted method by method. When the old name is
# finally deleted, this file goes with it.
class EmailImageShimTest < Minitest::Test
  def setup
    Studio::EmailCatalog.reset!
    @stubs = []
  end

  def teardown
    @stubs.reverse_each { |mod, name, original| mod.define_singleton_method(name, original) }
    Studio::EmailCatalog.reset!
  end

  def stub_module(mod, name, &replacement)
    @stubs << [mod, name, mod.method(name)]
    mod.define_singleton_method(name, &replacement)
  end

  # --- the surface mcritchie-studio's main actually calls -------------------

  def test_url_delegates
    row = Object.new
    row.define_singleton_method(:url) { "https://bucket.s3.amazonaws.com/x.png" }
    stub_module(Studio::EmailCatalog, :record) { |_key| row }

    assert_equal "https://bucket.s3.amazonaws.com/x.png", Studio::EmailImage.url(:magic_link)
  end

  def test_record_delegates
    row = Object.new
    stub_module(Studio::EmailCatalog, :record) { |_key| row }

    assert_same row, Studio::EmailImage.record(:magic_link)
  end

  def test_store_delegates_with_its_keyword_arguments
    captured = nil
    stub_module(Studio::EmailCatalog, :store) do |key, io:, content_type: nil|
      captured = { key: key, body: io.read, content_type: content_type }
      :stored
    end

    result = Studio::EmailImage.store(:magic_link, io: StringIO.new("bytes"), content_type: "image/png")

    assert_equal :stored, result
    assert_equal({ key: :magic_link, body: "bytes", content_type: "image/png" }, captured)
  end

  def test_label_and_known_delegate
    assert_equal "Magic-link sign-in", Studio::EmailImage.label("magic_link")
    assert Studio::EmailImage.known?("magic_link")
    refute Studio::EmailImage.known?("nope")
  end

  def test_variants_delegates_in_the_legacy_shape
    assert_equal Studio::EmailCatalog.variants, Studio::EmailImage.variants
  end

  # --- the surface engine 0.33 shipped --------------------------------------

  def test_register_delegates_and_lands_in_the_one_registry
    Studio::EmailImage.register("winnings", label: "Contest winnings")

    assert_includes Studio::EmailCatalog.keys, "winnings",
      "there must be ONE registry — a shim that kept its own would silently split the catalog"
    assert_equal "Contest winnings", Studio::EmailCatalog.label("winnings")
  end

  def test_resolution_helpers_delegate
    stub_module(Studio::EmailCatalog, :record) { |_key| nil }
    # Both seams: preview_url resolves layered-first through preview_asset_path,
    # source() still asks default_asset_path. The shim only forwards, so stubbing
    # one and asserting the other would test the stub rather than the delegation.
    stub_module(Studio::EmailCatalog, :preview_asset_path) { |_key| "/assets/emails/magic-link.png" }
    stub_module(Studio::EmailCatalog, :default_asset_path) { |_key| "/assets/emails/magic-link.png" }

    assert_nil Studio::EmailImage.url("magic_link")
    assert_equal "/assets/emails/magic-link.png", Studio::EmailImage.preview_url("magic_link")
    # The shim forwards, so it reports whatever the catalog reports — and
    # :default split into :app_asset / :engine_default. magic_link is one of the
    # engine's own STANDARD two, so its artwork really is the engine's.
    assert_equal :engine_default, Studio::EmailImage.source("magic_link")
  end

  def test_constants_still_resolve_through_the_old_name
    assert_equal Studio::EmailCatalog::PURPOSE, Studio::EmailImage::PURPOSE
    assert_equal Studio::EmailCatalog::ASPECT_RATIO, Studio::EmailImage::ASPECT_RATIO
    assert_equal Studio::EmailCatalog::MAX_WIDTH, Studio::EmailImage::MAX_WIDTH
  end

  # A typo must still raise rather than silently no-op — the reason the shim
  # delegates explicitly instead of via method_missing.
  def test_an_unknown_method_still_raises
    assert_raises(NoMethodError) { Studio::EmailImage.no_such_method }
  end
end
