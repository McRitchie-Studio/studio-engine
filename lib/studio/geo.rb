# frozen_string_literal: true

require_relative "geo/countries"

module Studio
  # The house geo primitive: where a visitor appears to be, and whether this app
  # is willing to serve them there.
  #
  # Deliberately PURE — no ActiveRecord, no Rails, no request, no Geocoder call.
  # It takes plain strings and returns plain strings and booleans, which is what
  # makes the load-bearing half (the blocking policy) unit-testable a branch at a
  # time. The pieces that need the world live beside it:
  #
  #   Studio::GeoDetection  (controller concern) resolves IP -> region and caches
  #                         it in the session, then asks THIS module the verdict
  #   Studio::GeoSetting    (model) stores the operator's choices
  #   Studio::GeoHelper     (view helper) renders flags from these codes
  #
  # VOCABULARY, because the two halves of an address are easy to conflate:
  #
  #   country      ISO 3166-1 alpha-2, upcased — "US", "CA", "GB"
  #   subdivision  the state/province/region code WITHIN a country — "WA", "AB"
  #   region token the two joined, "US-WA", which is the only form stored
  #
  # The token matters. "CA" is California AND Canada, so a bare subdivision code
  # is only meaningful next to its country. A ban list of bare codes cannot say
  # which one it means; a list of tokens always can. Bare codes are still ACCEPTED
  # on input (turf-monster stored years of them) and normalized to tokens against
  # the app's home country on the way in — one vocabulary inside, tolerance at the
  # door.
  module Geo
    # US states + DC + PR, name => code. The map is here rather than in a host app
    # because two different surfaces need it: the geocoder hands back a full name
    # ("Washington") that has to become a code, and the published exclusion list
    # has to turn a code back into a name a reader recognises.
    US_SUBDIVISIONS = {
      "Alabama" => "AL", "Alaska" => "AK", "Arizona" => "AZ", "Arkansas" => "AR",
      "California" => "CA", "Colorado" => "CO", "Connecticut" => "CT", "Delaware" => "DE",
      "Florida" => "FL", "Georgia" => "GA", "Hawaii" => "HI", "Idaho" => "ID",
      "Illinois" => "IL", "Indiana" => "IN", "Iowa" => "IA", "Kansas" => "KS",
      "Kentucky" => "KY", "Louisiana" => "LA", "Maine" => "ME", "Maryland" => "MD",
      "Massachusetts" => "MA", "Michigan" => "MI", "Minnesota" => "MN", "Mississippi" => "MS",
      "Missouri" => "MO", "Montana" => "MT", "Nebraska" => "NE", "Nevada" => "NV",
      "New Hampshire" => "NH", "New Jersey" => "NJ", "New Mexico" => "NM", "New York" => "NY",
      "North Carolina" => "NC", "North Dakota" => "ND", "Ohio" => "OH", "Oklahoma" => "OK",
      "Oregon" => "OR", "Pennsylvania" => "PA", "Rhode Island" => "RI", "South Carolina" => "SC",
      "South Dakota" => "SD", "Tennessee" => "TN", "Texas" => "TX", "Utah" => "UT",
      "Vermont" => "VT", "Virginia" => "VA", "Washington" => "WA", "West Virginia" => "WV",
      "Wisconsin" => "WI", "Wyoming" => "WY",
      "District of Columbia" => "DC", "Puerto Rico" => "PR"
    }.freeze

    # code => name, for the published exclusion list and the admin grid labels.
    US_SUBDIVISION_NAMES = US_SUBDIVISIONS.invert.freeze

    # The editor grid's order: alphabetical by code, DC and PR last, which is how
    # every published US exclusion list a reader has seen is laid out.
    US_SUBDIVISION_CODES = ((US_SUBDIVISIONS.values - %w[DC PR]).sort + %w[DC PR]).freeze

    # Regional Indicator Symbol A. A country's two letters mapped into this block
    # render as one flag glyph on every platform that ships emoji.
    REGIONAL_INDICATOR_A = 0x1F1E6

    COUNTRY_CODE = /\A[A-Za-z]{2}\z/
    SUBDIVISION_CODE = /\A[A-Za-z]{1,3}\z/

    module_function

    # ---- normalization -----------------------------------------------------

    # "us" / " US " -> "US"; anything that is not two ASCII letters -> nil. A
    # geocoder that returns a full country name, an empty string, or nil all land
    # on nil rather than becoming a code that means nothing.
    def normalize_country(raw)
      return nil if raw.nil?

      code = raw.to_s.strip
      return nil unless code.match?(COUNTRY_CODE)

      code.upcase
    end

    # "Washington" -> "WA", "wa" -> "WA". A value that is neither a known US state
    # name nor a short code is passed through UNCHANGED (upcased only when it is
    # already code-shaped), because outside the US the geocoder's region string is
    # frequently the only identifier there is — "Alberta" is a real answer, and
    # dropping it would silently blank the visitor's location.
    def normalize_subdivision(raw)
      return nil if raw.nil?

      value = raw.to_s.strip
      return nil if value.empty?
      return value.upcase if value.match?(SUBDIVISION_CODE)

      US_SUBDIVISIONS[value] || value
    end

    # "US" + "WA" -> "US-WA". nil when either half is missing: a half-address is
    # not a region, and storing one would match every visitor from that country.
    def region_token(country, subdivision)
      country = normalize_country(country)
      subdivision = normalize_subdivision(subdivision)
      return nil if country.nil? || subdivision.nil?

      "#{country}-#{subdivision}"
    end

    # The inverse, tolerant of the legacy bare form. "US-WA" -> ["US", "WA"];
    # "WA" -> [home_country, "WA"]. A bare code is read as a subdivision of the
    # app's own country, which is the only reading that was ever meant when an app
    # stored one.
    def parse_region(token, home_country: "US")
      value = token.to_s.strip
      return [nil, nil] if value.empty?

      # A dash means the token carries BOTH halves — including "CU-", which is a
      # country with no subdivision (an app that blocks a whole country, and an
      # operator simulating it). Without the dash the value is a bare subdivision
      # of this app's own country, which is the only reading an older app ever
      # meant when it stored one.
      if value.include?("-")
        head, tail = value.split("-", 2)
        [normalize_country(head), normalize_subdivision(tail)]
      else
        [normalize_country(home_country), normalize_subdivision(value)]
      end
    end

    # Whatever the operator typed or an older app stored, as one canonical token.
    def normalize_region_token(token, home_country: "US")
      country, subdivision = parse_region(token, home_country: home_country)
      region_token(country, subdivision)
    end

    def country_name(code)
      COUNTRIES[normalize_country(code)]
    end

    def subdivision_name(code, country: "US")
      return nil if code.nil?
      return US_SUBDIVISION_NAMES[normalize_subdivision(code)] if normalize_country(country) == "US"

      nil
    end

    # ---- presentation ------------------------------------------------------

    # The country's flag as a regional-indicator emoji pair.
    #
    # Why an emoji rather than an asset: shipping ~250 country SVGs is a lot of
    # bytes for a 16px badge, and every platform already has the glyphs. Returns
    # nil for anything that is not exactly two ASCII letters, so a blank, a
    # malformed code, or a full country name renders text-only rather than
    # emitting garbage codepoints.
    def country_flag_emoji(alpha2)
      code = normalize_country(alpha2)
      return nil if code.nil?

      code.chars.map { |c| c.ord - "A".ord + REGIONAL_INDICATOR_A }.pack("U*")
    end

    # True when the visitor is outside the app's home country, and therefore must
    # NOT be shown a home-country subdivision flag. This is the load-bearing half
    # of flag selection: a subdivision flag lookup matches on a bare code, so an
    # Italian region normalising to "CA" would otherwise be shown the CALIFORNIA
    # flag — a wrong answer that looks right.
    def foreign?(country, home_country: "US")
      code = normalize_country(country)
      return false if code.nil?

      code != normalize_country(home_country)
    end

    # ---- freshness ---------------------------------------------------------

    # Should the caller re-run the IP lookup?
    #
    # A RESOLVED region is trusted for `ttl` (a day): people do not teleport, and
    # the lookup costs a network round trip on every request that misses. A BLANK
    # result is trusted only for `retry_ttl` (minutes), because a blank is usually
    # a transient failure — a provider timeout, a rate limit, an IP the provider
    # cannot place — and caching "nowhere" for a full day fails every geo-gated
    # feature closed until the visitor's IP changes.
    #
    # Compared as STRINGS to match the session-stored Time#to_s stamps (UTC, and
    # therefore lexicographically chronological). `now` is injectable so the TTL
    # policy is testable without sleeping.
    def stale?(detected_at:, resolved:, now: Time.now, ttl: 86_400, retry_ttl: 300)
      return true if detected_at.nil? || detected_at.to_s.strip.empty?

      window = resolved ? ttl : retry_ttl
      detected_at.to_s < (now - window).to_s
    end

    # ---- policy ------------------------------------------------------------

    # THE VERDICT. Is this visitor blocked?
    #
    #   enforcing            the operator's kill switch; false blocks nobody
    #   country/subdivision  where the visitor appears to be
    #   banned_countries     ISO alpha-2 codes this app refuses outright
    #   banned_subdivisions  region tokens ("US-WA") — bare codes tolerated
    #   home_country         this app's own country, for bare-code resolution
    #   fail_closed          how an UNDETECTABLE home-country visitor is treated
    #
    # Three ways to be blocked, in order:
    #
    #   1. the resolved country is on the country list;
    #   2. the resolved region is on the subdivision list;
    #   3. FAIL CLOSED — the app blocks specific subdivisions of its own country,
    #      and this visitor is in that country with NO detectable subdivision (a
    #      VPN, a datacenter IP, a provider outage, a lookup timeout). A blank
    #      could be any of the blocked regions masked by a failed lookup, so it
    #      cannot be waved through.
    #
    # Rule 3 is deliberately narrower than "block every blank": it only fires when
    # subdivision-level rules for the home country actually exist. An app that
    # blocks nothing at that grain is hiding nothing, so failing its visitors
    # closed would cost real users access to protect no rule. A resolved NON-home
    # country with a blank subdivision stays allowed for the same reason — only
    # the home-country ambiguity is dangerous.
    def blocked?(country:, subdivision:, banned_countries: [], banned_subdivisions: [],
                 home_country: "US", enforcing: true, fail_closed: true)
      return false unless enforcing

      home = normalize_country(home_country)
      country = normalize_country(country)
      subdivision = normalize_subdivision(subdivision)

      countries = Array(banned_countries).filter_map { |c| normalize_country(c) }
      return true if country && countries.include?(country)

      tokens = Array(banned_subdivisions).filter_map { |t| normalize_region_token(t, home_country: home) }
      token = region_token(country, subdivision)
      return true if token && tokens.include?(token)

      return false unless fail_closed
      return false unless subdivision.nil?
      return false unless country == home

      tokens.any? { |t| t.start_with?("#{home}-") }
    end
  end
end
