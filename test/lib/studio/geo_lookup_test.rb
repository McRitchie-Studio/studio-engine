# frozen_string_literal: true

require "test_helper"
require "geocoder"

# [unit] Studio::Geo::Lookup — the IP provider every app gets, and the two
# settings whose absence kills geo silently.
#
# The precedence case is the one that bites a real app: this runs in EVERY host
# on boot, so an engine that overwrote a host's own Geocoder configuration would
# change a shipped app's IP provider on a gem bump. Measured — turf-monster's
# suite asserts its own cache class, and an earlier draft of this replaced it.
class StudioGeoLookupTest < Minitest::Test
  HostCache = Class.new do
    def [](_url)
      nil
    end

    def []=(_url, _value)
      nil
    end
  end

  def setup
    @original = Geocoder.config.to_hash.dup
  end

  def teardown
    Geocoder.configure(**@original)
  end

  # Geocoder.configure MERGES, so the provider hash has to be cleared explicitly —
  # otherwise a token set by one test leaks into the next one's assertions.
  def reset_geocoder!
    Geocoder.configure(cache: nil, use_https: false, ip_lookup: :ipinfo_io, timeout: 1, ipinfo_io: {})
  end

  # ipinfo 301-redirects http -> https with a non-JSON body and Geocoder does not
  # follow it, so a plain-HTTP lookup silently returns NOTHING on every request
  # and every geo gate fails closed. This is the assertion that keeps that from
  # happening twice.
  def test_it_configures_https_and_a_cache
    reset_geocoder!

    assert Studio::Geo::Lookup.configure!
    assert Geocoder.config.use_https, "ipinfo over plain HTTP silently returns no result"
    assert_instance_of Studio::Geo::Lookup::RailsCache, Geocoder.config.cache
    assert_equal :ipinfo_io, Geocoder.config.ip_lookup
  end

  # A host that set its own cache store configured this deliberately.
  def test_it_leaves_a_host_configuration_alone
    reset_geocoder!
    host_cache = HostCache.new
    Geocoder.configure(cache: host_cache, ip_lookup: :ipinfo_io)

    refute Studio::Geo::Lookup.configure!(force: false)
    assert_same host_cache, Geocoder.config.cache, "the host's own setup must survive a gem bump"
  end

  def test_a_host_that_configured_nothing_is_configured
    reset_geocoder!

    assert Studio::Geo::Lookup.configure!(force: false)
    assert_instance_of Studio::Geo::Lookup::RailsCache, Geocoder.config.cache
  end

  # A blank token is the anonymous tier — dormant, not broken. An app must not
  # need a secret before it can place anybody.
  def test_a_missing_token_is_a_safe_no_op
    reset_geocoder!
    previous = ENV["IPINFO_API_TOKEN"]
    ENV.delete("IPINFO_API_TOKEN")

    assert Studio::Geo::Lookup.configure!
    assert_nil Geocoder.config.ipinfo_io[:api_key] if Geocoder.config.ipinfo_io.is_a?(Hash)
  ensure
    ENV["IPINFO_API_TOKEN"] = previous unless previous.nil?
  end

  def test_a_token_is_forwarded_to_the_provider
    reset_geocoder!

    assert Studio::Geo::Lookup.configure!(api_key: "token-123")
    assert_equal "token-123", Geocoder.config.ipinfo_io[:api_key]
  end
end
