# frozen_string_literal: true

require "test_helper"
require "socket"
require "open-uri"
require_relative "../../../lib/studio/image_cache"

# [unit] Studio::ImageCache's SSRF guard: validate_source_url!, vet_source_url!
# and the fetch that follows them.
#
# The regression: the guard read the URL's text and nothing else, so a loopback
# or private address written any way but a plain dotted quad went through, and a
# public-looking name that RESOLVES to one was never asked. Found reviewing
# mcritchie-studio PR 1958, whose Appearances::FetchableUrl delegates here.
#
# NO REAL DNS, NO REAL NETWORK. Every resolution goes through an injected
# resolver, and the one socket this file opens is a listener it owns on
# 127.0.0.1.
class StudioImageCacheUrlGuardTest < Minitest::Test
  IC = Studio::ImageCache
  PUBLIC_V4 = "93.184.216.34"
  PUBLIC_V6 = "2606:2800:220:1:248:1893:25c8:1946"

  # A resolver that must not be asked: a literal address or a blocked name is
  # judged before any lookup.
  NEVER = ->(host) { raise "resolver was asked about #{host.inspect}" }

  def resolver(map)
    ->(host) { map.fetch(host) }
  end

  def refuse!(url, resolver: NEVER, match: nil)
    error = assert_raises(IC::InvalidSourceURL, "expected #{url.inspect} refused") do
      IC.validate_source_url!(url, resolver: resolver)
    end
    assert_match(match, error.message, "refusing #{url.inspect}") if match
    error
  end

  # ─── literal addresses in disguise ──────────────────────────────────────────

  def test_refuses_mapped_ipv6_loopback
    ["http://[::ffff:127.0.0.1]/a.png", "https://[::FFFF:127.0.0.1]:8443/a.png", "http://[::ffff:7f00:1]/a.png",
     "http://[0:0:0:0:0:ffff:127.0.0.1]/a.png"].each do |url|
      refuse!(url, match: /127\.0\.0\.1/)
    end
  end

  def test_refuses_mapped_ipv6_private_link_local_and_metadata
    { "http://[::ffff:10.0.0.5]/a.png" => /10\.0\.0\.5/,
      "http://[::ffff:172.16.4.4]/a.png" => /172\.16\.4\.4/,
      "http://[::ffff:192.168.1.1]/a.png" => /192\.168\.1\.1/,
      "http://[::ffff:169.254.169.254]/latest/meta-data" => /169\.254\.169\.254/,
      "http://[::ffff:a9fe:a9fe]/latest/meta-data" => /169\.254\.169\.254/,
      "http://[::ffff:0.0.0.0]/a.png" => /0\.0\.0\.0/ }.each do |url, named|
      refuse!(url, match: named)
    end
  end

  # The other ways an IPv6 literal carries an IPv4 address: IPv4-compatible,
  # NAT64 and 6to4. Each is unwrapped and the address inside is judged.
  def test_refuses_other_ipv6_forms_that_embed_an_internal_ipv4
    ["http://[::127.0.0.1]/a.png", "http://[::7f00:1]/a.png", "http://[64:ff9b::7f00:1]/a.png",
     "http://[64:ff9b::10.0.0.5]/a.png", "http://[2002:7f00:1::]/a.png", "http://[2002:a00:5::1]/a.png"].each do |url|
      refuse!(url)
    end
  end

  def test_refuses_ipv6_loopback_unspecified_link_local_unique_local_and_multicast
    ["http://[::1]/a.png", "http://[0:0:0:0:0:0:0:1]/a.png", "http://[::]/a.png", "http://[fe80::1]/a.png",
     "http://[febf::1]/a.png", "http://[fc00::1]/a.png", "http://[fd12:3456:789a::1]/a.png", "http://[ff02::1]/a.png",
     "http://[fec0::1]/a.png"].each do |url|
      refuse!(url)
    end
  end

  # 127.1, 2130706433, 0x7f.1 and 017700000001 are all 127.0.0.1 to inet_aton,
  # which is what the OS hands a socket. The message names the decoded address,
  # so each form is shown to have been PARSED, not merely disliked.
  def test_refuses_short_and_integer_ipv4
    { "http://127.1/a.png" => "127.0.0.1",
      "http://127.0.1/a.png" => "127.0.0.1",
      "http://2130706433/a.png" => "127.0.0.1",
      "http://10.1/a.png" => "10.0.0.1",
      "http://192.168.257/a.png" => "192.168.1.1",
      "http://3232235777/a.png" => "192.168.1.1",
      "http://2852039166/latest/meta-data" => "169.254.169.254",
      "http://0/a.png" => "0.0.0.0" }.each do |url, decoded|
      refuse!(url, match: /#{Regexp.escape(decoded)}/)
    end
  end

  def test_refuses_hex_ipv4
    { "http://0x7f.1/a.png" => "127.0.0.1",
      "http://0x7f000001/a.png" => "127.0.0.1",
      "http://0X7F.0x0.0x0.0x1/a.png" => "127.0.0.1",
      "http://0xa.0.0.5/a.png" => "10.0.0.5",
      "http://0xa9fea9fe/latest/meta-data" => "169.254.169.254",
      "http://0xc0a80101/a.png" => "192.168.1.1" }.each do |url, decoded|
      refuse!(url, match: /#{Regexp.escape(decoded)}/)
    end
  end

  def test_refuses_octal_ipv4
    { "http://017700000001/a.png" => "127.0.0.1",
      "http://0177.0.0.1/a.png" => "127.0.0.1",
      "http://0177.1/a.png" => "127.0.0.1",
      "http://012.0.0.5/a.png" => "10.0.0.5",
      "http://0300.0250.1.1/a.png" => "192.168.1.1" }.each do |url, decoded|
      refuse!(url, match: /#{Regexp.escape(decoded)}/)
    end
  end

  # A numeric host that is not a plain dotted quad is refused even when it
  # decodes to a public address: `010.8.8.8` is 8.8.8.8 to inet_aton and
  # 10.8.8.8 to a parser that reads it as decimal, and the party that fetches is
  # not always the party that checked.
  def test_refuses_a_non_canonical_numeric_host_even_when_it_decodes_public
    { "http://134744072/a.png" => "8.8.8.8",
      "http://8.8.2056/a.png" => "8.8.8.8",
      "http://0x8.8.8.8/a.png" => "8.8.8.8",
      "http://010.8.8.8/a.png" => "8.8.8.8" }.each do |url, decoded|
      refuse!(url, match: /#{Regexp.escape(decoded)}/)
    end
  end

  def test_refuses_a_numeric_host_no_resolver_would_parse
    ["http://1.2.3.4.5/a.png", "http://256.1.1.1/a.png", "http://4294967296/a.png", "http://09.1.1.1/a.png",
     "http://1.2.3.0x100/a.png", "http://example.123/a.png", "http://1..2/a.png"].each do |url|
      refuse!(url)
    end
  end

  def test_decode_numeric_ipv4_reads_each_form_as_inet_aton_does
    { "127.1" => "127.0.0.1", "127.0.1" => "127.0.0.1", "2130706433" => "127.0.0.1", "0x7f.1" => "127.0.0.1",
      "017700000001" => "127.0.0.1", "0177.0.0.1" => "127.0.0.1", "1.2.3.4" => "1.2.3.4", "1.2.772" => "1.2.3.4",
      "1.131844" => "1.2.3.4", "16909060" => "1.2.3.4", "0x1020304" => "1.2.3.4", "0" => "0.0.0.0",
      "4294967295" => "255.255.255.255" }.each do |host, decoded|
      assert_equal decoded, IC.decode_numeric_ipv4(host).to_s, "decoding #{host.inspect}"
    end
    assert_nil IC.decode_numeric_ipv4("cdn.example.com"), "a name is not a number"
    assert_nil IC.decode_numeric_ipv4("1e100.net"), "a name whose first label has digits is still a name"
  end

  # ─── every refused range, written plainly ───────────────────────────────────

  def test_refuses_every_non_public_ipv4_range
    ["0.0.0.0", "0.1.2.3", "10.0.0.5", "10.255.255.255", "100.64.0.1", "100.127.255.254", "127.0.0.1", "127.255.255.254",
     "169.254.169.254", "169.254.0.1", "172.16.4.4", "172.31.255.255", "192.168.1.1", "224.0.0.1", "239.255.255.250",
     "240.0.0.1", "255.255.255.255"].each do |ip|
      refuse!("http://#{ip}/a.png", match: /#{Regexp.escape(ip)}/)
      assert_equal false, IC.public_address?(ip), "#{ip} is not public"
    end
  end

  def test_the_edges_of_each_range_stay_public
    ["9.255.255.255", "11.0.0.1", "100.63.255.255", "100.128.0.1", "126.255.255.255", "128.0.0.1", "169.253.255.255",
     "169.255.0.1", "172.15.255.255", "172.32.0.1", "192.167.255.255", "192.169.0.1", "223.255.255.255"].each do |ip|
      assert_equal true, IC.public_address?(ip), "#{ip} is public"
      assert_equal ip, IC.validate_source_url!("https://#{ip}/a.png", resolver: NEVER).host
    end
  end

  # ─── names ──────────────────────────────────────────────────────────────────

  def test_refuses_trailing_dot_localhost
    ["http://localhost./a.png", "https://LOCALHOST.:3000/a.png", "http://LocalHost/a.png", "http://printer.local./a.png",
     "http://hub.internal./a.png", "http://nas.LAN./a.png", "http://app.localhost/a.png", "http://app.localhost./a.png"].each do |url|
      refuse!(url, match: /internal hostname/)
    end
  end

  def test_a_trailing_dot_does_not_hide_a_literal_address
    ["http://127.0.0.1./a.png", "http://10.0.0.5./a.png", "http://2130706433./a.png", "http://127.1./a.png"].each do |url|
      refuse!(url)
    end
  end

  def test_refuses_a_host_that_is_not_a_hostname
    ["http://%31%32%37.0.0.1/a.png", "http://a..b/a.png", "http://-a.example.com/a.png", "http://localhost../a.png",
     "http://#{"a" * 64}.example.com/a.png", "http://#{(["abcdefgh"] * 30).join(".")}.com/a.png"].each do |url|
      refuse!(url)
    end
  end

  def test_refuses_name_resolving_private
    { "127.0.0.1" => /127\.0\.0\.1/, "10.0.0.5" => /10\.0\.0\.5/, "172.16.4.4" => /172\.16\.4\.4/,
      "192.168.1.1" => /192\.168\.1\.1/, "169.254.169.254" => /169\.254\.169\.254/, "100.64.0.1" => /100\.64\.0\.1/,
      "0.0.0.0" => /0\.0\.0\.0/, "224.0.0.1" => /224\.0\.0\.1/, "::1" => /::1/, "fe80::1" => /fe80::1/,
      "fd00::1" => /fd00::1/, "::ffff:127.0.0.1" => /127\.0\.0\.1/ }.each do |address, named|
      error = refuse!("https://cdn.example.com/a.png", resolver: resolver("cdn.example.com" => [address]), match: named)
      assert_match(/cdn\.example\.com/, error.message)
    end
  end

  # ANY, not all: one private record among public ones is the rebinding shape.
  def test_refuses_a_name_when_any_one_address_is_non_public
    refuse!("https://cdn.example.com/a.png",
            resolver: resolver("cdn.example.com" => [PUBLIC_V4, "10.0.0.5"]), match: /10\.0\.0\.5/)
    refuse!("https://cdn.example.com/a.png",
            resolver: resolver("cdn.example.com" => [PUBLIC_V4, PUBLIC_V6, "fe80::1"]), match: /fe80::1/)
  end

  def test_refuses_a_name_that_does_not_resolve
    refuse!("https://cdn.example.com/a.png", resolver: ->(_) { [] }, match: /did not resolve/)
    refuse!("https://cdn.example.com/a.png", resolver: ->(_) { nil }, match: /did not resolve/)
    refuse!("https://cdn.example.com/a.png", resolver: ->(_) { raise Timeout::Error, "dns timed out" },
                                             match: /could not be resolved.*dns timed out/)
    refuse!("https://cdn.example.com/a.png", resolver: ->(_) { ["not-an-address"] }, match: /not-an-address/)
  end

  def test_the_name_is_resolved_without_its_trailing_dot_and_in_lower_case
    asked = []
    IC.validate_source_url!("https://CDN.Example.COM./a.png", resolver: ->(host) { asked << host; [PUBLIC_V4] })
    assert_equal ["cdn.example.com"], asked
  end

  # ─── what is still allowed ──────────────────────────────────────────────────

  def test_allows_public_https
    public_dns = resolver("cdn.example.com" => [PUBLIC_V4, PUBLIC_V6])
    ["https://cdn.example.com/sheets/a.png", "HTTPS://CDN.example.com/a.png?x=1", "http://cdn.example.com/a.png",
     "https://cdn.example.com:8443/a.png", "https://cdn.example.com./a.png"].each do |url|
      uri = IC.validate_source_url!(url, resolver: public_dns)
      assert_kind_of URI::HTTP, uri, "the return value is still the parsed URI"
      assert_equal URI.parse(url), uri
    end
  end

  def test_allows_public_literal_addresses_without_asking_a_resolver
    ["https://#{PUBLIC_V4}/a.png", "http://8.8.8.8/a.png", "https://[#{PUBLIC_V6}]/a.png",
     "https://[2001:4860:4860::8888]:443/a.png"].each do |url|
      assert_equal URI.parse(url), IC.validate_source_url!(url, resolver: NEVER)
    end
  end

  def test_still_refuses_what_it_refused_before
    ["ftp://cdn.example.com/a.png", "file:///etc/passwd", "javascript:alert(1)", "https:///a.png",
     "http://localhost/a.png", "http://printer.local/a.png", "http://hub.internal/a.png", "http://nas.lan/a.png",
     "http://127.0.0.1/a.png", "http://10.0.0.5/a.png", "http://169.254.169.254/latest/meta-data", "http://0.0.0.0/a.png",
     "http://[::1]/a.png", "http://[fe80::1]/a.png", "http://[fd00::1]/a.png"].each do |url|
      refuse!(url)
    end
    assert_raises(URI::InvalidURIError) { IC.validate_source_url!("not a url", resolver: NEVER) }
  end

  # ─── the vetted addresses, for a caller that fetches for itself ─────────────

  def test_vet_source_url_returns_the_addresses_it_vetted_ipv4_first
    vetted = IC.vet_source_url!("https://CDN.example.com./a.png",
                                resolver: resolver("cdn.example.com" => [PUBLIC_V6, PUBLIC_V4]))
    assert_equal URI.parse("https://CDN.example.com./a.png"), vetted.uri
    assert_equal "cdn.example.com", vetted.host
    assert_equal [PUBLIC_V4, PUBLIC_V6], vetted.addresses

    literal = IC.vet_source_url!("https://[#{PUBLIC_V6}]/a.png", resolver: NEVER)
    assert_equal [PUBLIC_V6], literal.addresses
  end

  # resolver: nil is the text-only check: literals and blocked names are still
  # judged, a name is not looked up, and no address is claimed as vetted.
  def test_a_nil_resolver_checks_the_text_only_and_vets_no_address
    vetted = IC.vet_source_url!("https://cdn.example.com/a.png", resolver: nil)
    assert_equal [], vetted.addresses
    refuse!("http://127.1/a.png", resolver: nil)
    refuse!("http://localhost./a.png", resolver: nil)
    refuse!("http://[::ffff:127.0.0.1]/a.png", resolver: nil)
  end

  # ─── which resolver is the default ──────────────────────────────────────────

  FakeRails = Struct.new(:env)
  FakeEnv = Struct.new(:name) do
    def test? = name == "test"
  end

  def test_the_default_resolver_is_the_system_one_except_under_a_rails_test_env
    assert_same IC::SYSTEM_RESOLVER, IC.default_resolver(FakeRails.new(FakeEnv.new("production")))
    assert_same IC::SYSTEM_RESOLVER, IC.default_resolver(FakeRails.new(FakeEnv.new("development")))
    assert_same IC::SYSTEM_RESOLVER, IC.default_resolver(nil)
    assert_same IC::SYSTEM_RESOLVER, IC.default_resolver(Module.new), "a bare Rails namespace has no env"
    assert_nil IC.default_resolver(FakeRails.new(FakeEnv.new("test")))
  end

  def test_a_configured_resolver_wins_and_is_what_validate_uses
    mine = resolver("cdn.example.com" => ["10.0.0.5"])
    IC.resolver = mine
    assert_same mine, IC.resolver
    assert_raises(IC::InvalidSourceURL) { IC.validate_source_url!("https://cdn.example.com/a.png") }
  ensure
    IC.resolver = nil
  end

  # ─── the system resolver, with the hosts file and DNS both faked ────────────

  class FakeHosts
    def initialize(map) = @map = map
    def getaddresses(name) = @map.fetch(name, [])
  end

  class FakeDns
    Record = Struct.new(:address)
    attr_reader :asked, :timeouts

    def initialize(a: [], aaaa: [], error: nil)
      @a = a
      @aaaa = aaaa
      @error = error
      @asked = []
    end

    def timeouts=(value)
      @timeouts = value
    end

    def getresources(name, type)
      raise @error if @error

      @asked << [name, type]
      (type == Resolv::DNS::Resource::IN::A ? @a : @aaaa).map { |address| Record.new(address) }
    end
  end

  def test_the_system_resolver_asks_for_every_a_and_aaaa_record_with_a_short_timeout
    dns = FakeDns.new(a: [PUBLIC_V4, "10.0.0.5"], aaaa: [PUBLIC_V6])
    assert_equal [PUBLIC_V4, "10.0.0.5", PUBLIC_V6], IC.system_addresses("cdn.example.com", hosts: FakeHosts.new({}), dns: dns)
    assert_equal [["cdn.example.com", Resolv::DNS::Resource::IN::A], ["cdn.example.com", Resolv::DNS::Resource::IN::AAAA]], dns.asked
    assert_equal IC::RESOLVE_TIMEOUTS, dns.timeouts
    assert_operator IC::RESOLVE_TIMEOUTS.sum, :<=, 5, "a short timeout"
  end

  # The OS resolver reads the hosts file first, so the check must too: a name
  # pinned to loopback in /etc/hosts is loopback whatever public DNS says.
  def test_the_system_resolver_reads_the_hosts_file_before_dns
    dns = FakeDns.new(a: [PUBLIC_V4])
    hosts = FakeHosts.new("cdn.example.com" => ["127.0.0.1"])
    assert_equal ["127.0.0.1"], IC.system_addresses("cdn.example.com", hosts: hosts, dns: dns)
    assert_empty dns.asked
  end

  def test_a_dns_failure_refuses_through_the_system_resolver
    broken = ->(host) { IC.system_addresses(host, hosts: FakeHosts.new({}), dns: FakeDns.new(error: Resolv::ResolvTimeout.new("timeout")))  }
    refuse!("https://cdn.example.com/a.png", resolver: broken, match: /could not be resolved/)
    empty = ->(host) { IC.system_addresses(host, hosts: FakeHosts.new({}), dns: FakeDns.new) }
    refuse!("https://cdn.example.com/a.png", resolver: empty, match: /did not resolve/)
  end

  # ─── the fetch: every hop vetted, every connection pinned ───────────────────

  # Replaces the one method that touches the network, yielding the hops asked.
  def with_hops(script)
    asked = []
    original = IC.method(:request_hop)
    IC.define_singleton_method(:request_hop) do |vetted|
      asked << vetted
      script.fetch(vetted.uri.to_s)
    end
    yield asked
  ensure
    IC.define_singleton_method(:request_hop, original)
  end

  def hop(status, body: "", location: nil, reason: "OK")
    IC::Hop.new(status: status, reason: reason, location: location, body: body, headers: {})
  end

  def test_fetch_remote_returns_the_body_and_hands_the_vetted_addresses_to_the_connection
    dns = resolver("cdn.example.com" => [PUBLIC_V4])
    with_hops("https://cdn.example.com/a.png" => hop(200, body: "PNG")) do |asked|
      assert_equal "PNG", IC.fetch_remote("https://cdn.example.com/a.png", resolver: dns)
      assert_equal [[PUBLIC_V4]], asked.map(&:addresses)
    end
  end

  # THE TOP TRAP. The old fetch was URI.open(redirect: true): a public URL that
  # answered 302 to http://127.0.0.1/ was followed with no second look.
  def test_fetch_remote_refuses_a_redirect_to_an_internal_address
    dns = resolver("cdn.example.com" => [PUBLIC_V4], "rebound.example.com" => ["10.0.0.5"])
    { "http://127.0.0.1/latest" => /127\.0\.0\.1/, "http://[::ffff:127.0.0.1]/x" => /127\.0\.0\.1/,
      "http://2130706433/x" => /127\.0\.0\.1/, "http://localhost./x" => /internal hostname/,
      "http://169.254.169.254/latest/meta-data" => /169\.254\.169\.254/,
      "https://rebound.example.com/x" => /10\.0\.0\.5/, "file:///etc/passwd" => /scheme/ }.each do |target, named|
      with_hops("https://cdn.example.com/a.png" => hop(302, location: target)) do |asked|
        error = assert_raises(IC::InvalidSourceURL, "redirect to #{target}") do
          IC.fetch_remote("https://cdn.example.com/a.png", resolver: dns)
        end
        assert_match named, error.message
        assert_equal ["https://cdn.example.com/a.png"], asked.map { |v| v.uri.to_s }, "the refused hop is never requested"
      end
    end
  end

  def test_fetch_remote_follows_a_public_redirect_and_vets_the_new_host
    dns = resolver("cdn.example.com" => [PUBLIC_V4], "img.example.net" => ["8.8.8.8"])
    with_hops("https://cdn.example.com/a.png" => hop(301, location: "/b.png"),
              "https://cdn.example.com/b.png" => hop(307, location: "https://img.example.net/c.png"),
              "https://img.example.net/c.png" => hop(200, body: "PNG")) do |asked|
      assert_equal "PNG", IC.fetch_remote("https://cdn.example.com/a.png", resolver: dns)
      assert_equal [[PUBLIC_V4], [PUBLIC_V4], ["8.8.8.8"]], asked.map(&:addresses)
    end
  end

  def test_fetch_remote_gives_up_on_a_redirect_loop
    dns = resolver("cdn.example.com" => [PUBLIC_V4])
    with_hops("https://cdn.example.com/a.png" => hop(302, location: "https://cdn.example.com/a.png")) do |asked|
      error = assert_raises(OpenURI::HTTPError) { IC.fetch_remote("https://cdn.example.com/a.png", resolver: dns) }
      assert_match(/redirect/, error.message)
      assert_equal IC::MAX_REDIRECTS + 1, asked.size
    end
  end

  # The hub's Athletes::DeadHeadshotSource reads `error.io.status` off an
  # OpenURI::HTTPError to tell a retired photo from a broken upload, so the
  # exception a failed fetch raises is part of the contract.
  def test_fetch_remote_raises_open_uri_http_error_carrying_the_status
    dns = resolver("cdn.example.com" => [PUBLIC_V4])
    with_hops("https://cdn.example.com/a.png" => hop(404, reason: "Not Found", body: "gone")) do
      error = assert_raises(OpenURI::HTTPError) { IC.fetch_remote("https://cdn.example.com/a.png", resolver: dns) }
      assert_equal "404 Not Found", error.message
      assert_equal %w[404 Not\ Found], error.io.status
      assert_equal "gone", error.io.read
    end
  end

  # ─── a real socket: the connection goes to the vetted address ───────────────

  # Serves one canned response per connection on 127.0.0.1 and records each
  # request head. The host in the URL (`*.invalid`) resolves nowhere, so a
  # request that arrives proves the socket went to the address it was handed.
  def with_listener(response)
    server = TCPServer.new("127.0.0.1", 0)
    heads = Queue.new
    thread = Thread.new do
      loop do
        client = server.accept
        head = +""
        head << client.readpartial(4096) until head.include?("\r\n\r\n")
        heads << head
        client.write(response)
        client.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    yield server.addr[1], heads
  ensure
    server&.close
    thread&.join(2)
  end

  def vetted(url, addresses)
    IC::VettedSource.new(uri: URI.parse(url), host: URI.parse(url).hostname, addresses: addresses)
  end

  def test_request_hop_connects_to_the_vetted_address_not_to_the_name
    with_listener("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 3\r\nConnection: close\r\n\r\nPNG") do |port, heads|
      result = IC.request_hop(vetted("http://cdn.pinned.invalid:#{port}/a.png?x=1", ["127.0.0.1"]))
      assert_equal 200, result.status
      assert_equal "PNG", result.body
      head = heads.pop
      assert_match %r{\AGET /a\.png\?x=1 HTTP/1\.1\r\n}, head
      assert_match(/^Host: cdn\.pinned\.invalid:#{port}\r$/i, head, "the Host header still names the host")
    end
  end

  # A dyno with no IPv6 route must not fail a host that has an AAAA record: an
  # address that cannot be reached falls through to the next vetted one.
  def test_request_hop_falls_through_to_the_next_vetted_address
    original = IC.method(:pinned_http)
    tried = []
    IC.define_singleton_method(:pinned_http) do |uri, address|
      tried << address
      raise Errno::ENETUNREACH, "no route to #{address}" if address == PUBLIC_V6

      original.call(uri, address)
    end
    with_listener("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK") do |port, _heads|
      result = IC.request_hop(vetted("http://cdn.pinned.invalid:#{port}/a.png", [PUBLIC_V6, "127.0.0.1"]))
      assert_equal "OK", result.body
      assert_equal [PUBLIC_V6, "127.0.0.1"], tried

      error = assert_raises(Errno::ENETUNREACH) { IC.request_hop(vetted("http://cdn.pinned.invalid:#{port}/a.png", [PUBLIC_V6])) }
      assert_match(/no route/, error.message, "the last address's own error is what surfaces")
    end
  ensure
    IC.define_singleton_method(:pinned_http, original) if original
  end

  def test_request_hop_reports_a_redirect_without_following_it
    with_listener("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1/latest\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") do |port, heads|
      result = IC.request_hop(vetted("http://cdn.pinned.invalid:#{port}/a.png", ["127.0.0.1"]))
      assert_equal 302, result.status
      assert_equal "http://127.0.0.1/latest", result.location
      heads.pop
      assert heads.empty?, "one request, and no second one to the Location"
    end
  end

  def test_request_hop_stops_reading_past_the_byte_cap
    body = "x" * 4096
    original = IC::MAX_REMOTE_BYTES
    IC.send(:remove_const, :MAX_REMOTE_BYTES)
    IC.const_set(:MAX_REMOTE_BYTES, 1024)
    with_listener("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}") do |port, _heads|
      assert_raises(IC::SourceTooLarge) { IC.request_hop(vetted("http://cdn.pinned.invalid:#{port}/a.png", ["127.0.0.1"])) }
    end
  ensure
    IC.send(:remove_const, :MAX_REMOTE_BYTES)
    IC.const_set(:MAX_REMOTE_BYTES, original)
  end

  def test_pinned_http_carries_the_address_keeps_the_name_for_tls_and_uses_no_proxy
    http = IC.pinned_http(URI.parse("https://cdn.example.com/a.png"), PUBLIC_V4)
    assert_equal PUBLIC_V4, http.ipaddr
    assert_equal "cdn.example.com", http.address, "TLS verifies the certificate against the name"
    assert_equal 443, http.port
    assert http.use_ssl?
    assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode
    assert_equal false, http.proxy?, "a proxy would resolve the name again, so none is used"
    refute IC.pinned_http(URI.parse("http://cdn.example.com/a.png"), PUBLIC_V4).use_ssl?
  end

  def test_the_fetch_no_longer_follows_redirects_through_open_uri
    source = File.read(File.expand_path("../../../lib/studio/image_cache.rb", __dir__))
    refute_match(/URI\.open/, source.gsub(/^\s*#.*$/, ""))
  end
end
