# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../lib/studio/s3"

# [unit] Studio.s3_key_prefix — the optional key namespace INSIDE the bucket that
# lets a satellite app (mcritchie-industries, moms-app) share an already-
# provisioned bucket instead of standing up its own pair.
#
# The contract these assert, because getting any of them wrong silently writes
# objects nobody can read back:
#
#   1. Unset (every app shipped before this) -> keys are byte-identical. This is
#      the regression that matters most: a prefix leaking in by default would
#      orphan every existing ImageCache row in mcritchie-studio + turf-monster.
#   2. Set -> every operation that names an object namespaces it the SAME way,
#      including .url (the public URL an email banner is served from). A prefix
#      applied on upload but not on url yields a 404 image in every inbox.
#   3. .list returns LOGICAL keys — the prefix stripped back off — so a caller
#      can feed any result straight back into download/delete/url.
#   4. A prefix written without a trailing slash still namespaces as a folder.
class S3KeyPrefixTest < Minitest::Test
  KEY = "email_banners/magic_link-ab12cd34.png"

  def setup
    @previous_bucket_prefix = Studio.s3_bucket_prefix
    @previous_key_prefix    = Studio.s3_key_prefix
    Studio.s3_bucket_prefix = "mcritchie-studio"
    Studio.s3_key_prefix    = nil
  end

  def teardown
    Studio.s3_bucket_prefix = @previous_bucket_prefix
    Studio.s3_key_prefix    = @previous_key_prefix
  end

  # --- 1. unset: unchanged for every already-shipped app --------------------

  def test_no_prefix_leaves_keys_untouched
    assert_equal "", Studio::S3.key_prefix
    assert_equal KEY, Studio::S3.full_key(KEY)
    assert_equal KEY, Studio::S3.logical_key(KEY)
  end

  def test_no_prefix_url_is_the_bare_key
    assert_equal "https://mcritchie-studio-dev.s3.us-east-2.amazonaws.com/#{KEY}",
                 Studio::S3.url(key: KEY)
  end

  # --- 2. set: every object-naming path namespaces identically --------------

  def test_prefix_namespaces_the_key
    Studio.s3_key_prefix = "mcritchie-industries/"

    assert_equal "mcritchie-industries/", Studio::S3.key_prefix
    assert_equal "mcritchie-industries/#{KEY}", Studio::S3.full_key(KEY)
  end

  def test_prefix_namespaces_the_public_url_too
    Studio.s3_key_prefix = "mcritchie-industries/"

    # The URL an email banner is fetched from. If this skipped the prefix the
    # upload would succeed and every delivered email would show a broken image.
    assert_equal "https://mcritchie-studio-dev.s3.us-east-2.amazonaws.com/mcritchie-industries/#{KEY}",
                 Studio::S3.url(key: KEY)
  end

  def test_logical_key_is_the_inverse_of_full_key
    Studio.s3_key_prefix = "mcritchie-industries/"

    assert_equal KEY, Studio::S3.logical_key(Studio::S3.full_key(KEY))
  end

  def test_logical_key_leaves_a_foreign_key_alone
    Studio.s3_key_prefix = "mcritchie-industries/"

    # An object from ANOTHER app's namespace in the shared bucket must not be
    # mangled into something that looks like ours.
    assert_equal "moms-app/#{KEY}", Studio::S3.logical_key("moms-app/#{KEY}")
  end

  # --- 3. a prefix without a trailing slash still namespaces as a folder -----

  def test_prefix_normalizes_a_missing_trailing_slash
    Studio.s3_key_prefix = "mcritchie-industries"

    assert_equal "mcritchie-industries/", Studio::S3.key_prefix
    assert_equal "mcritchie-industries/#{KEY}", Studio::S3.full_key(KEY)
  end

  # --- 4. configured? degrades instead of raising ---------------------------

  def test_configured_is_false_without_a_bucket_prefix
    Studio.s3_bucket_prefix = nil

    refute Studio::S3.configured?,
      "an app with no bucket prefix must report unconfigured, not raise"
  end

  def test_configured_is_true_with_a_bucket_prefix
    assert Studio::S3.configured?
  end

  def test_bucket_still_raises_for_a_caller_that_wants_the_error
    Studio.s3_bucket_prefix = nil

    assert_raises(Studio::S3::NotConfigured) { Studio::S3.bucket }
  end
end
