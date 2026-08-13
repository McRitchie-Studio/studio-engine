# frozen_string_literal: true

module Studio
  # The shape, dedupe rule and growth cap for `users.ip_locations` — the jsonb
  # array recording the distinct places an account has been seen from.
  #
  # Deliberately PURE: it takes the existing array and returns a new one. No
  # ActiveRecord, no clock beyond what the caller passes, no geo lookup. That
  # keeps the analytics shape identical in every app while leaving the RESOLUTION
  # to the host — turf-monster already resolves IP → state/country through
  # Geocoder in ApplicationController#detect_geo_state and can hand the result
  # straight here; an app with no geo lookup at all still gets a useful record of
  # the distinct IPs.
  #
  # An entry:
  #
  #   { "ip" => "203.0.113.7", "country" => "US", "region" => "TX",
  #     "city" => "Austin", "first_seen_at" => "2026-08-13T21:00:00Z",
  #     "last_seen_at" => "2026-08-14T09:30:00Z", "count" => 4 }
  #
  # String keys throughout, ISO-8601 times: this round-trips through jsonb, and a
  # symbol-keyed hash written today would come back string-keyed tomorrow.
  module IpLocations
    # Distinct locations kept per user, most-recently-seen first. A cap is not
    # optional for a column that grows on sign-in: an account that travels, or
    # sits behind a rotating consumer IP, would otherwise grow this row without
    # bound and drag every SELECT that loads the user along with it.
    MAX_ENTRIES = 50

    # Loopback and private ranges. A dev session signs in from 127.0.0.1 all day
    # and a container from 10.x; recording those buys nothing and would crowd the
    # real entries out of the cap.
    SKIPPED_IP = /\A(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.|::1\z|fe80:|f[cd])/i

    module_function

    # Returns the array to store. Appends a new entry when this location has not
    # been seen before; otherwise refreshes the existing one in place.
    def push(entries, ip:, country: nil, region: nil, city: nil, at: nil)
      at  = normalize_time(at)
      ip  = ip.to_s.strip
      key = location_key(ip: ip, country: country, region: region, city: city)
      return normalize(entries) if key.nil?

      existing = normalize(entries)
      match    = existing.find { |e| e["key"] == key }

      if match
        match["last_seen_at"] = at
        match["count"]        = match["count"].to_i + 1
        # The IP within a location legitimately changes (a reassigned lease); the
        # LOCATION is what we deduped on, so keep the freshest address for it.
        match["ip"] = ip if ip.present?
      else
        existing << {
          "key" => key, "ip" => ip.presence, "country" => presence(country),
          "region" => presence(region), "city" => presence(city),
          "first_seen_at" => at, "last_seen_at" => at, "count" => 1
        }
      end

      existing.sort_by { |e| e["last_seen_at"].to_s }.reverse.first(MAX_ENTRIES)
    end

    # Has this account been seen here before? The question a caller asks to avoid
    # a write on every single request.
    def seen?(entries, ip: nil, country: nil, region: nil, city: nil)
      key = location_key(ip: ip.to_s.strip, country: country, region: region, city: city)
      return false if key.nil?

      normalize(entries).any? { |e| e["key"] == key }
    end

    # What the location is, for deduping. Geo when we have any of it — two
    # sign-ins from Austin are ONE location even from different addresses, which
    # is the whole point of tracking places rather than addresses. Falls back to
    # the IP when the lookup gave us nothing, so an app with no geo still records
    # something useful. nil (record nothing) when there is neither.
    def location_key(ip:, country: nil, region: nil, city: nil)
      geo = [country, region, city].map { |v| presence(v) }
      return "geo:" + geo.map(&:to_s).join("|").downcase if geo.any?
      return nil if ip.blank? || ip.match?(SKIPPED_IP)

      "ip:#{ip.downcase}"
    end

    def normalize(entries)
      Array(entries).filter_map do |entry|
        next unless entry.respond_to?(:to_h)

        row = entry.to_h.transform_keys(&:to_s)
        next if row.empty?

        # Backfill for rows written before these fields existed, so an upgrade in
        # place neither duplicates locations it already holds nor treats them as
        # the stalest thing in the column.
        row["key"] ||= location_key(ip: row["ip"].to_s, country: row["country"],
                                    region: row["region"], city: row["city"])
        # A stored row is evidence of at least one sighting.
        row["count"] = 1 if row["count"].to_i < 1
        row["last_seen_at"] ||= row["first_seen_at"]
        row
      end
    end

    def normalize_time(value)
      return value if value.is_a?(String) && value.present?
      return Time.now.utc.iso8601 if value.nil?

      value.respond_to?(:utc) ? value.utc.iso8601 : value.to_s
    end

    def presence(value)
      str = value.to_s.strip
      str.empty? ? nil : str
    end
  end
end
