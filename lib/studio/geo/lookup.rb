# frozen_string_literal: true

module Studio
  module Geo
    # The IP -> location provider, configured once for every app that installs
    # this gem. Separate from Studio::Geo itself, which stays pure: this is the
    # half that knows about Geocoder, Rails.cache and the network.
    #
    # Two settings here are not preferences — they are the difference between a
    # working gate and a silently dead one:
    #
    #   use_https   ipinfo.io 301-redirects http -> https with a non-JSON body,
    #               and Geocoder does not follow the redirect. A plain-HTTP
    #               lookup therefore returns NO RESULT ("response was not valid
    #               JSON") on every request — no exception, no log line the app
    #               would notice — and every geo-gated feature fails closed for
    #               every visitor. It cost turf-monster two weeks of blocked
    #               payments before anyone connected the two.
    #
    #   cache       The anonymous tier rate-limits by REQUESTING IP, and a
    #               platform's egress IPs are shared with every other tenant on
    #               that dyno, so the quota can be exhausted by traffic that is
    #               not yours. When it is, lookups 429 and every visitor reads as
    #               unplaceable. A cross-process cache keyed by the lookup URL
    #               (which embeds the IP) collapses repeat visitors and every
    #               uptime-monitor hit into one lookup per TTL. Geocoder writes
    #               the cache only for VALID responses, so a 429 or a timeout is
    #               never cached and simply retries on the next request.
    module Lookup
      # Adapts Rails.cache to the []/[]= duck Geocoder's Generic cache store
      # expects, adding the TTL that Rails.cache.write supports and Geocoder
      # never passes.
      class RailsCache
        def initialize(ttl: 86_400)
          @ttl = ttl
        end

        def [](url)
          ::Rails.cache.read(url)
        end

        def []=(url, value)
          ::Rails.cache.write(url, value, expires_in: @ttl)
        end
      end

      module_function

      # Returns true when the provider was configured, false when it was left
      # alone. Both are normal answers:
      #
      #   · no geocoder gem — an app can include Studio::GeoDetection with no
      #     lookup at all and simply never place anyone; every gate then behaves
      #     as it does for an unplaceable visitor;
      #   · the HOST already configured Geocoder — its own configuration wins.
      #     A host that has set a cache store has set this up deliberately, and
      #     an engine that overwrote it would be changing a shipped app's IP
      #     provider on a gem bump. Measured: turf-monster's suite asserts its
      #     own cache class, and this method used to replace it.
      #
      # `force:` is how the engine's own re-configuration (and a host that wants
      # the shared setup back) says "yes, mine".
      def configure!(provider: Studio.geo_ip_provider,
                     api_key: nil,
                     timeout: Studio.geo_lookup_timeout,
                     cache_ttl: Studio.geo_cache_ttl,
                     force: true)
        return false unless available?
        return false if !force && host_configured?

        api_key ||= resolved_api_key

        options = {
          ip_lookup: provider,
          use_https: true,
          timeout: timeout,
          units: :mi,
          cache: RailsCache.new(ttl: cache_ttl),
          cache_options: { prefix: "geocoder:" }
        }
        # An authenticated key lifts the anonymous rate limit. A blank one is a
        # safe no-op — the anonymous tier — so this stays dormant until the app
        # sets a token rather than failing closed on a missing secret.
        options[provider] = { api_key: api_key } if api_key

        ::Geocoder.configure(**options)
        true
      end

      # The marker of a deliberate host setup. Geocoder ships with no cache store
      # at all, and every configuration worth respecting sets one — including
      # this module's.
      def host_configured?
        !::Geocoder.config.cache.nil?
      end

      def available?
        require "geocoder"
        true
      rescue LoadError
        false
      end

      def resolved_api_key
        key = Studio.geo_ip_api_key
        key = key.call if key.respond_to?(:call)
        key = ENV["IPINFO_API_TOKEN"] if key.nil? || key.to_s.strip.empty?
        return nil if key.nil? || key.to_s.strip.empty?

        key.to_s
      end
    end
  end
end
