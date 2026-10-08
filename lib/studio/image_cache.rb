require "ipaddr"
require "socket"

module Studio
  module ImageCache
    EXT_BY_TYPE = {
      "image/png"  => "png",
      "image/jpeg" => "jpg",
      "image/jpg"  => "jpg",
      "image/webp" => "webp",
      "image/gif"  => "gif"
    }.freeze

    ALLOWED_CONTENT_TYPES = EXT_BY_TYPE.keys.freeze

    # Per-call cap on the bytes we'll fetch from a remote source_url. 50MB
    # covers high-res photos comfortably; anything larger should be uploaded
    # via source_path (local file) to bypass this cap intentionally.
    MAX_REMOTE_BYTES = 50 * 1024 * 1024

    class InvalidSourceURL < ArgumentError; end
    class UnsupportedContentType < ArgumentError; end
    class SourceTooLarge < StandardError; end

    # Caches an image at S3 under a folder per owner. Every call stores the
    # unmodified source as variant "original", plus one resized variant per
    # entry in widths.
    #
    # Layout:
    #   {key_prefix}/original.{ext}
    #   {key_prefix}/{width}.{ext}
    #
    # Source: provide EITHER source_url (HTTP fetch) OR source_path (local
    # file). source_url is recorded on each ImageCache row regardless — for
    # source_path callers, pass the original URL too if you want it tracked.
    #
    # source_url is validated against SSRF (see THE SSRF GUARD below): the
    # scheme must be http/https and the host must be public, however it is
    # written and wherever its name resolves. The fetch then connects to the
    # address that was vetted, and vets every redirect the same way.
    #
    # Idempotent: variants already present in ImageCache are skipped. If
    # nothing is missing, the source is never read.
    def self.cache!(owner:, purpose:, key_prefix:, widths:, source_url: nil, source_path: nil, content_type: "image/png")
      raise ArgumentError, "either source_url or source_path is required" if source_url.nil? && source_path.nil?

      unless ALLOWED_CONTENT_TYPES.include?(content_type)
        raise UnsupportedContentType, "content_type #{content_type.inspect} not in allowlist (#{ALLOWED_CONTENT_TYPES.join(", ")})"
      end

      validate_source_url!(source_url) if source_url

      ext = EXT_BY_TYPE[content_type]
      requested = ["original", *widths.map(&:to_s)]

      existing = ::ImageCache.where(owner: owner, purpose: purpose).index_by(&:variant)
      missing  = requested - existing.keys
      return existing if missing.empty?

      require "mini_magick"

      body = if source_path
        File.binread(source_path)
      else
        fetch_remote(source_url)
      end

      missing.each do |variant|
        if variant == "original"
          payload = body
          s3_key  = "#{key_prefix}/original.#{ext}"
        else
          img = MiniMagick::Image.read(body)
          # Cap ImageMagick resources per-invocation to prevent decompression-bomb DoS.
          img.combine_options do |c|
            c.limit "memory", "256MB"
            c.limit "map", "512MB"
            c.limit "width", "16KP"   # 16k pixel max width
            c.limit "height", "16KP"
            c.resize "#{variant}x"
          end
          payload = img.to_blob
          s3_key  = "#{key_prefix}/#{variant}.#{ext}"
        end

        Studio::S3.upload(
          key: s3_key,
          body: payload,
          content_type: content_type,
          cache_control: "public, max-age=31536000, immutable"
        )

        existing[variant] = ::ImageCache.create!(
          owner: owner,
          purpose: purpose,
          variant: variant,
          s3_key: s3_key,
          source_url: source_url,
          bytes: payload.bytesize,
          content_type: content_type
        )
      end

      existing
    end

    # ── THE SSRF GUARD ────────────────────────────────────────────────────────
    #
    # Three questions, asked in order, about the host of a remote source_url:
    #
    #   1. IS IT AN ADDRESS, HOWEVER IT IS WRITTEN? A bracketed IPv6 literal is
    #      parsed and any IPv4 address inside it (mapped, compatible, NAT64,
    #      6to4) is unwrapped. A numeric host is decoded the way inet_aton
    #      decodes it, which is what the OS hands a socket: `127.1`,
    #      `2130706433`, `0x7f.1` and `017700000001` are all 127.0.0.1.
    #   2. IS IT A NAME WE REFUSE ON SIGHT? `localhost`, `*.localhost`,
    #      `*.local`, `*.internal`, `*.lan`, after the trailing dot is stripped
    #      and the case folded.
    #   3. WHERE DOES THE NAME POINT? Every A and AAAA record is read, and ONE
    #      non-public address refuses the URL. A name that does not resolve is
    #      refused too.
    #
    # WHAT IT DOES NOT PROVE. The answer is true at the moment of the check. A
    # name can resolve differently a moment later, so a caller that checks here
    # and then fetches BY NAME has a gap between the two. `fetch_remote` below
    # has no such gap: it connects to the address it vetted. A caller with its
    # own HTTP client closes it the same way, with `vet_source_url!` and
    # `pinned_http`. A caller that hands the URL to a third party's fetcher
    # cannot close it at all, and should say so.

    # Every range a fetch must not reach, by family. Anything outside is public.
    NON_PUBLIC_RANGES = {
      "0.0.0.0/8"       => "unspecified",
      "10.0.0.0/8"      => "private",
      "100.64.0.0/10"   => "carrier-grade NAT",
      "127.0.0.0/8"     => "loopback",
      "169.254.0.0/16"  => "link-local",
      "172.16.0.0/12"   => "private",
      "192.0.0.0/24"    => "IETF protocol assignment",
      "192.0.2.0/24"    => "documentation",
      "192.168.0.0/16"  => "private",
      "198.18.0.0/15"   => "benchmarking",
      "198.51.100.0/24" => "documentation",
      "203.0.113.0/24"  => "documentation",
      "224.0.0.0/4"     => "multicast",
      "240.0.0.0/4"     => "reserved",
      "::/128"          => "unspecified",
      "::1/128"         => "loopback",
      "64:ff9b:1::/48"  => "local NAT64",
      "100::/64"        => "discard",
      "2001:db8::/32"   => "documentation",
      "fc00::/7"        => "unique-local",
      "fe80::/10"       => "link-local",
      "fec0::/10"       => "site-local",
      "ff00::/8"        => "multicast"
    }.map { |cidr, label| [IPAddr.new(cidr), label].freeze }.freeze

    # IPv6 prefixes that carry an IPv4 address, and where in the 128 bits it sits
    # (the right shift that brings it to the low 32).
    EMBEDDED_IPV4 = {
      "::ffff:0:0/96" => 0,  # IPv4-mapped
      "::/96"         => 0,  # IPv4-compatible (deprecated, still parsed)
      "64:ff9b::/96"  => 0,  # NAT64
      "2002::/16"     => 80  # 6to4
    }.map { |cidr, shift| [IPAddr.new(cidr), shift].freeze }.freeze

    INTERNAL_HOSTNAMES = %w[localhost].freeze
    INTERNAL_SUFFIXES = %w[.localhost .local .internal .lan].freeze

    HOSTNAME_LABEL = /\A[a-z0-9_](?:[a-z0-9_-]*[a-z0-9_])?\z/
    NUMERIC_LABEL = /\A(?:0x[0-9a-f]*|[0-9]+)\z/

    # Seconds per DNS attempt, and for the whole lookup.
    RESOLVE_TIMEOUTS = [2, 2].freeze
    RESOLVE_DEADLINE = 6

    MAX_REDIRECTS = 5
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30

    # What a check answers: the parsed URI, the host as it was judged (folded,
    # no trailing dot), and the public addresses it was vetted against, IPv4
    # first. `addresses` is empty only when no resolver was used.
    VettedSource = Struct.new(:uri, :host, :addresses, keyword_init: true)

    # One HTTP exchange, not followed.
    Hop = Struct.new(:status, :reason, :location, :body, :headers, keyword_init: true)

    # The resolver every name goes through: the hosts file, then DNS, the order
    # the OS uses. Answers address strings; raises when DNS does.
    SYSTEM_RESOLVER = lambda do |host|
      require "timeout"
      Timeout.timeout(RESOLVE_DEADLINE) { Studio::ImageCache.system_addresses(host) }
    end

    class << self
      # A callable `host -> [address strings]` every check resolves names with.
      # Set one to answer from somewhere other than the system resolver; a test
      # suite sets one to decide what a name resolves to. nil restores the
      # default.
      attr_writer :resolver

      def resolver
        @resolver || default_resolver
      end
    end

    # The system resolver, except under a Rails test environment, where the
    # default is NO resolution: names are judged on their text alone, as they
    # were before resolution existed. A consumer suite passes made-up hosts
    # (`cdn.example.com`) through this guard and must neither reach DNS nor
    # change its answers with the network. Literal addresses and refused names
    # are judged identically in every environment.
    def self.default_resolver(rails = (defined?(::Rails) ? ::Rails : nil))
      test_env = rails.respond_to?(:env) && rails.env.respond_to?(:test?) && rails.env.test?
      test_env ? nil : SYSTEM_RESOLVER
    end

    # SSRF guard for a remote source_url. Raises InvalidSourceURL on anything
    # that reaches, or might reach, an internal service; returns the parsed URI.
    #
    # `resolver:` is the callable names are resolved with (default:
    # `Studio::ImageCache.resolver`). Passing nil checks the text only.
    def self.validate_source_url!(url, resolver: self.resolver)
      vet_source_url!(url, resolver: resolver).uri
    end

    # The same check, answering a VettedSource: the URI, the judged host, and
    # the addresses it was vetted against. A caller that makes the request
    # itself connects to one of `addresses` (see `pinned_http`) so the name
    # cannot resolve differently between this check and the connection.
    def self.vet_source_url!(url, resolver: self.resolver)
      require "uri"
      uri = URI.parse(url)
      unless %w[http https].include?(uri.scheme)
        raise InvalidSourceURL, "URL scheme must be http or https, got #{uri.scheme.inspect}"
      end

      raw = uri.host.to_s
      raise InvalidSourceURL, "URL missing host: #{url.inspect}" if raw.empty?

      if raw.start_with?("[")
        ip = parse_address(raw.delete_prefix("[").delete_suffix("]")) ||
          raise(InvalidSourceURL, "Malformed IP host #{raw.inspect}")
        refuse_non_public!(ip, "URL host #{raw}")
        return VettedSource.new(uri: uri, host: ip.to_s, addresses: [ip.to_s])
      end

      host = raw.downcase.delete_suffix(".")
      raise InvalidSourceURL, "URL missing host: #{url.inspect}" if host.empty?

      if (ip = decode_numeric_ipv4(host))
        refuse_non_public!(ip, "URL host #{raw}")
        unless host == ip.to_s
          raise InvalidSourceURL, "URL host #{raw} is a non-canonical IPv4 address (#{ip}); write it as a dotted quad"
        end
        return VettedSource.new(uri: uri, host: host, addresses: [ip.to_s])
      end

      unless hostname?(host)
        raise InvalidSourceURL, "URL host is not a hostname: #{raw.inspect}"
      end
      if INTERNAL_HOSTNAMES.include?(host) || host.end_with?(*INTERNAL_SUFFIXES)
        raise InvalidSourceURL, "URL points to internal hostname: #{host.inspect}"
      end

      addresses = resolver ? resolve_public!(host, resolver) : []
      VettedSource.new(uri: uri, host: host, addresses: addresses)
    end

    # True when `address` (a String or IPAddr) is one a fetch may reach.
    def self.public_address?(address)
      ip = address.is_a?(IPAddr) ? address : parse_address(address.to_s)
      !ip.nil? && non_public_reason(ip).nil?
    end

    # The IPv4 address a numeric host means to inet_aton, or nil when the host
    # is a name. One to four parts; each decimal, `0x` hex, or leading-zero
    # octal; the last part fills whatever bytes the earlier ones left. A host
    # whose last label is a number is never a name (no TLD is numeric), so one
    # that does not decode is refused rather than handed to a resolver.
    def self.decode_numeric_ipv4(host)
      host = host.to_s.downcase
      parts = host.split(".", -1)
      return nil unless parts.last.to_s.match?(NUMERIC_LABEL)

      malformed = InvalidSourceURL.new("Malformed numeric host #{host.inspect}")
      raise malformed if parts.size > 4

      values = parts.map do |part|
        raise malformed unless part.match?(NUMERIC_LABEL)

        if part.start_with?("0x") then part.delete_prefix("0x").to_i(16)
        elsif part.start_with?("0") && part.size > 1
          raise malformed unless part.match?(/\A[0-7]+\z/)

          part.to_i(8)
        else part.to_i(10)
        end
      end

      *leading, last = values
      raise malformed if leading.any? { |value| value > 0xff }
      raise malformed if last >= 256**(4 - leading.size)

      IPAddr.new(leading.each_with_index.sum { |value, index| value << (8 * (3 - index)) } + last, Socket::AF_INET)
    end

    # Every address the system resolver gives for `host`: the hosts file first
    # (a hit there is the whole answer, as it is for the OS), then every A and
    # AAAA record. `hosts:` and `dns:` exist so a test can stand in for both.
    def self.system_addresses(host, hosts: nil, dns: nil)
      require "resolv"
      local = (hosts || Resolv::Hosts.new).getaddresses(host).map(&:to_s)
      return local unless local.empty?

      lookup = lambda do |client|
        client.timeouts = RESOLVE_TIMEOUTS
        [Resolv::DNS::Resource::IN::A, Resolv::DNS::Resource::IN::AAAA]
          .flat_map { |type| client.getresources(host, type) }
          .map { |record| record.address.to_s }
      end
      dns ? lookup.call(dns) : Resolv::DNS.open(&lookup)
    end

    # Fetches a remote source_url. Every hop is vetted, redirects included, and
    # every connection is made to an address that hop was vetted against, so
    # there is no window in which the name can point somewhere else.
    #
    # A non-2xx answer raises OpenURI::HTTPError with the status on `io.status`,
    # as the open-uri fetch this replaced did.
    def self.fetch_remote(source_url, resolver: self.resolver)
      url = source_url.to_s
      previous = nil
      hop = nil

      (MAX_REDIRECTS + 1).times do
        vetted = vet_source_url!(url, resolver: resolver)
        if previous&.scheme == "https" && vetted.uri.scheme == "http"
          raise InvalidSourceURL, "redirection forbidden: #{previous} -> #{vetted.uri}"
        end

        hop = request_hop(vetted)
        return hop.body if (200..299).cover?(hop.status)
        raise http_error(hop, vetted.uri) unless [301, 302, 303, 307, 308].include?(hop.status) && !hop.location.to_s.empty?

        previous = vetted.uri
        url = URI.join(vetted.uri, hop.location).to_s
      end

      raise http_error(hop, previous, "too many redirects (more than #{MAX_REDIRECTS})")
    end

    # One GET, to the first vetted address that accepts a connection. An
    # address that cannot be reached (an AAAA record on a host with no IPv6
    # route) falls through to the next; the last one's error is raised.
    def self.request_hop(vetted)
      require "net/http"
      candidates = vetted.addresses.empty? ? [nil] : vetted.addresses
      unreachable = [Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EADDRNOTAVAIL,
                     Net::OpenTimeout, SocketError]

      candidates.each_with_index do |address, index|
        return get_from(vetted.uri, address)
      rescue *unreachable
        raise if index == candidates.size - 1
      end
    end

    # A Net::HTTP for `uri` that connects to `address` and nowhere else. The
    # name still goes in the Host header and is what TLS verifies the
    # certificate against. No proxy is used, even when the environment names
    # one: a proxy would resolve the name again, somewhere this check cannot
    # see. `address` nil connects by name (only when nothing was resolved).
    def self.pinned_http(uri, address)
      require "net/http"
      http = Net::HTTP.new(uri.hostname, uri.port, nil)
      http.ipaddr = address if address
      if uri.scheme == "https"
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http
    end

    def self.get_from(uri, address)
      pinned_http(uri, address).start do |http|
        http.request(Net::HTTP::Get.new(uri.request_uri)) do |response|
          body = +"".b
          response.read_body do |chunk|
            body << chunk
            if body.bytesize > MAX_REMOTE_BYTES
              raise SourceTooLarge, "remote payload exceeds cap #{MAX_REMOTE_BYTES} bytes"
            end
          end
          return Hop.new(status: response.code.to_i, reason: response.message.to_s, location: response["location"],
                         body: body, headers: response.to_hash.transform_values { |values| values.join(", ") })
        end
      end
    end
    private_class_method :get_from

    def self.http_error(hop, uri, message = nil)
      require "open-uri"
      require "stringio"
      io = StringIO.new(hop.body.to_s)
      OpenURI::Meta.init(io)
      io.status = [hop.status.to_s, hop.reason.to_s]
      io.base_uri = uri
      hop.headers.each { |name, value| io.meta_add_field(name, value) }
      OpenURI::HTTPError.new(message || "#{hop.status} #{hop.reason}", io)
    end
    private_class_method :http_error

    def self.parse_address(text)
      return nil if text.include?("%") # a zone id names an interface on THIS machine

      IPAddr.new(text)
    rescue IPAddr::Error
      nil
    end
    private_class_method :parse_address

    def self.hostname?(host)
      host.size <= 253 && host.split(".", -1).all? { |label| label.size <= 63 && label.match?(HOSTNAME_LABEL) }
    end
    private_class_method :hostname?

    # The IPv4 address an IPv6 address carries, or the address itself.
    def self.unwrap(ip)
      return ip unless ip.ipv6?

      _, shift = EMBEDDED_IPV4.find { |range, _| range.include?(ip) }
      return ip if shift.nil? || ip.to_i <= 1 # :: and ::1 are IPv6's own, not IPv4 in a wrapper

      IPAddr.new((ip.to_i >> shift) & 0xffffffff, Socket::AF_INET)
    end
    private_class_method :unwrap

    # Why this address is not public, or nil when it is.
    def self.non_public_reason(ip)
      [ip, unwrap(ip)].uniq.each do |candidate|
        _, label = NON_PUBLIC_RANGES.find { |range, _| range.family == candidate.family && range.include?(candidate) }
        return label if label
      end
      nil
    end
    private_class_method :non_public_reason

    def self.refuse_non_public!(ip, subject)
      reason = non_public_reason(ip)
      return if reason.nil?

      inner = unwrap(ip)
      named = inner == ip ? ip.to_s : "#{inner} (written as #{ip})"
      raise InvalidSourceURL, "#{subject} points to a non-public address: #{named} [#{reason}]"
    end
    private_class_method :refuse_non_public!

    def self.resolve_public!(host, resolver)
      answers =
        begin
          Array(resolver.call(host)).map(&:to_s)
        rescue StandardError => e
          raise InvalidSourceURL, "URL host #{host.inspect} could not be resolved: #{e.class}: #{e.message}"
        end
      raise InvalidSourceURL, "URL host #{host.inspect} did not resolve to any address" if answers.empty?

      ips = answers.map do |answer|
        ip = parse_address(answer) ||
          raise(InvalidSourceURL, "URL host #{host.inspect} resolved to something that is not an address: #{answer.inspect}")
        refuse_non_public!(ip, "URL host #{host.inspect} resolves to #{answers.size} address(es), and one")
        ip.ipv4_mapped? ? ip.native : ip
      end
      ips.partition(&:ipv4?).flatten.map(&:to_s).uniq
    end
    private_class_method :resolve_public!
  end
end
