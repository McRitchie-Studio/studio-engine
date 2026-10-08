# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../lib/studio/s3"
require "aws-sdk-s3"

# [unit] Studio::S3 on an S3-compatible endpoint (Cloudflare R2).
#
# The contract these assert, because each wrong answer fails quietly:
#
#   1. Unconfigured (every app shipped before this) -> the SAME client options
#      and the SAME amazonaws.com URL. An endpoint leaking in by default would
#      point production writes at a bucket that does not exist there.
#   2. An endpoint reaches the client, and a blank one reads as unset.
#   3. Explicit keys go to the client as a pair; half a pair RAISES rather than
#      falling back to whatever AWS_* key the dyno holds.
#   4. url on an endpoint needs Studio.s3_public_url; without it url RAISES
#      (R2 serves nothing anonymously, so any URL would be a broken image) and
#      upload still writes, returning nil instead of raising after the write.
#   5. signed_url and the real SDK client resolve to the configured endpoint.
class S3EndpointTest < Minitest::Test
  ENDPOINT = "https://acct123.r2.cloudflarestorage.com"
  KEY = "email_banners/magic_link-ab12cd34.png"
  SETTINGS = %i[s3_bucket_prefix s3_key_prefix s3_region s3_endpoint
                s3_access_key_id s3_secret_access_key s3_public_url].freeze

  def setup
    @previous = SETTINGS.to_h { |name| [name, Studio.public_send(name)] }
    Studio.s3_bucket_prefix = "moms-app"
    Studio.s3_key_prefix = nil
    Studio.s3_region = "us-east-2"
    Studio.s3_endpoint = nil
    Studio.s3_access_key_id = nil
    Studio.s3_secret_access_key = nil
    Studio.s3_public_url = nil
    Studio::S3.reset!
  end

  def teardown
    @previous.each { |name, value| Studio.public_send("#{name}=", value) }
    Studio::S3.reset!
  end

  # --- 1. unconfigured: unchanged ---------------------------------------------

  def test_unconfigured_client_options_are_region_only
    assert_equal({ region: "us-east-2" }, Studio::S3.client_options)
  end

  def test_unconfigured_url_is_the_amazonaws_url
    assert_equal "https://moms-app-dev.s3.us-east-2.amazonaws.com/#{KEY}", Studio::S3.url(key: KEY)
    assert Studio::S3.public_url?
  end

  # --- 2. endpoint --------------------------------------------------------------

  def test_endpoint_reaches_client_options
    Studio.s3_endpoint = ENDPOINT
    Studio.s3_region = "auto"

    assert_equal({ region: "auto", endpoint: ENDPOINT }, Studio::S3.client_options)
  end

  def test_blank_endpoint_reads_as_unset
    Studio.s3_endpoint = ""

    assert_nil Studio::S3.endpoint
    assert_equal({ region: "us-east-2" }, Studio::S3.client_options)
  end

  # --- 3. explicit keys -----------------------------------------------------------

  def test_explicit_key_pair_reaches_client_options
    Studio.s3_access_key_id = "id-123"
    Studio.s3_secret_access_key = "secret-456"

    opts = Studio::S3.client_options
    assert_equal "id-123", opts[:access_key_id]
    assert_equal "secret-456", opts[:secret_access_key]
  end

  def test_half_a_key_pair_raises
    Studio.s3_access_key_id = "id-123"

    error = assert_raises(Studio::S3::NotConfigured) { Studio::S3.client_options }
    assert_match(/must be set together/, error.message)

    Studio.s3_access_key_id = nil
    Studio.s3_secret_access_key = "secret-456"
    assert_raises(Studio::S3::NotConfigured) { Studio::S3.client_options }
  end

  # --- 4. public URL --------------------------------------------------------------

  def test_endpoint_without_public_url_refuses_to_build_a_url
    Studio.s3_endpoint = ENDPOINT

    refute Studio::S3.public_url?
    error = assert_raises(Studio::S3::NotConfigured) { Studio::S3.url(key: KEY) }
    assert_match(/s3_public_url/, error.message)
  end

  def test_public_url_serves_the_key_under_its_prefix
    Studio.s3_endpoint = ENDPOINT
    Studio.s3_public_url = "https://assets.example.com/"
    Studio.s3_key_prefix = "moms/"

    assert Studio::S3.public_url?
    assert_equal "https://assets.example.com/moms/#{KEY}", Studio::S3.url(key: KEY)
  end

  def test_upload_without_public_url_writes_then_returns_nil
    Studio.s3_endpoint = ENDPOINT
    stub = stub_client

    assert_nil Studio::S3.upload(key: KEY, body: "png", content_type: "image/png")
    put = stub.api_requests.find { |r| r[:operation_name] == :put_object }
    refute_nil put, "upload must still write when there is no public URL"
    assert_equal "moms-app-dev", put[:params][:bucket]
    assert_equal KEY, put[:params][:key]
  end

  def test_upload_with_public_url_returns_it
    Studio.s3_endpoint = ENDPOINT
    Studio.s3_public_url = "https://assets.example.com"
    stub_client

    assert_equal "https://assets.example.com/#{KEY}", Studio::S3.upload(key: KEY, body: "png")
  end

  # --- 5. the real SDK client and presigner honour the endpoint ------------------

  def test_sdk_client_and_signed_url_resolve_to_the_endpoint
    Studio.s3_endpoint = ENDPOINT
    Studio.s3_region = "auto"
    Studio.s3_access_key_id = "id-123"
    Studio.s3_secret_access_key = "secret-456"

    client = Studio::S3.client
    assert_equal ENDPOINT, client.config.endpoint.to_s
    assert_equal "id-123", client.config.credentials.access_key_id

    signed = Studio::S3.signed_url(key: KEY, expires_in: 60)
    assert_includes URI(signed).host, "acct123.r2.cloudflarestorage.com"
    assert_includes signed, "X-Amz-Signature="
  end

  # --- 6. inline signed URLs and head reads, for the knowledge preview ------------

  def test_signed_url_signs_an_inline_disposition_and_a_content_type_into_the_url
    Studio.s3_endpoint = ENDPOINT
    Studio.s3_region = "auto"
    Studio.s3_access_key_id = "id-123"
    Studio.s3_secret_access_key = "secret-456"

    signed = Studio::S3.signed_url(key: KEY, expires_in: 900,
                                   response_content_disposition: "inline", response_content_type: "application/pdf")
    uri = URI(signed)
    query = URI.decode_www_form(uri.query).to_h

    assert_includes uri.host, "acct123.r2.cloudflarestorage.com"
    assert_equal "inline", query["response-content-disposition"]
    assert_equal "application/pdf", query["response-content-type"]
    assert_equal "900", query["X-Amz-Expires"]
    refute_empty query["X-Amz-Signature"].to_s

    # The overrides are part of what is signed: the same key without them
    # signs differently, so they cannot be appended to a plain link.
    plain = URI.decode_www_form(URI(Studio::S3.signed_url(key: KEY, expires_in: 900)).query).to_h
    refute plain.key?("response-content-disposition")
    refute_equal plain["X-Amz-Signature"], query["X-Amz-Signature"]
  end

  def test_download_with_max_bytes_sends_a_range_and_without_it_sends_none
    Studio.s3_endpoint = ENDPOINT
    stub = stub_client
    stub.stub_responses(:get_object, { body: "head" })

    assert_equal "head", Studio::S3.download(key: KEY, max_bytes: 1024)
    assert_equal "head", Studio::S3.download(key: KEY)
    ranges = stub.api_requests.select { |r| r[:operation_name] == :get_object }.map { |r| r[:params][:range] }
    assert_equal ["bytes=0-1023", nil], ranges
  end

  def test_a_ranged_read_of_an_empty_object_is_the_empty_string
    Studio.s3_endpoint = ENDPOINT
    stub = stub_client
    stub.stub_responses(:get_object, "InvalidRange")

    assert_equal "", Studio::S3.download(key: KEY, max_bytes: 1024)
  end

  def test_download_refuses_a_max_bytes_that_is_not_a_positive_integer
    Studio.s3_endpoint = ENDPOINT
    stub = stub_client

    [0, -1, 1.5, "1024"].each do |bad|
      error = assert_raises(ArgumentError, bad.inspect) { Studio::S3.download(key: KEY, max_bytes: bad) }
      assert_match(/positive Integer/, error.message)
    end
    assert_empty stub.api_requests, "a bad range is refused before any request is built"
  end

  def test_download_does_not_swallow_other_errors
    Studio.s3_endpoint = ENDPOINT
    stub = stub_client
    stub.stub_responses(:get_object, "NoSuchKey")

    assert_raises(Aws::S3::Errors::NoSuchKey) { Studio::S3.download(key: KEY, max_bytes: 1024) }
  end

  private

  def stub_client
    client = Aws::S3::Client.new(region: "auto", endpoint: ENDPOINT, stub_responses: true,
                                 access_key_id: "x", secret_access_key: "y")
    Studio::S3.instance_variable_set(:@client, client)
    client
  end
end
