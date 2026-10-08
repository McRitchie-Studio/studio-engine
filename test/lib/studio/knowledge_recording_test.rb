# frozen_string_literal: true

require "test_helper"
require "socket"
require "tempfile"
require "timeout"
require "net/http"
require_relative "../../../lib/studio/image_cache"
require_relative "../../../lib/studio/knowledge_recording"

# [unit] Studio::KnowledgeRecording: what counts as a recording, and the
# guarded fetch of one from a URL.
#
# NO REAL DNS, NO OUTSIDE NETWORK. Names resolve through an injected resolver.
# The fetch tests run real Net::HTTP against a listener this file owns on
# 127.0.0.1: the `connection` seam is replaced so that a connection the code
# pinned to a (made-up) public address lands on that listener, in plain HTTP.
# What the seam was ASKED for is recorded, and that is what the pinning
# assertions read. Every host, name and path here is invented.
class StudioKnowledgeRecordingTest < Minitest::Test
  KR = Studio::KnowledgeRecording
  PUBLIC_V4 = "93.184.216.34"
  OTHER_V4 = "93.184.216.35"
  MP4 = ("\x00\x00\x00\x18ftypisom\x00\x00\x02\x00".b + "isomiso2mp41".b).freeze
  HTML = "<!doctype html><html><body>Please sign in</body></html>"

  def setup
    @files = []
    @asked = []
    @original_connection = KR.method(:connection)
  end

  def teardown
    KR.define_singleton_method(:connection, @original_connection)
    @files.each(&:close!)
  end

  def file_of(bytes, name = ["recording", ".bin"])
    file = Tempfile.new(name)
    file.binmode
    file.write(bytes)
    file.flush
    @files << file
    file.path
  end

  # ─── what counts as a recording ─────────────────────────────────────────────

  HEADS = {
    "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00".b => [:isobmff, "mp4", "video/mp4"],
    "\x00\x00\x00\x14ftypqt  \x00\x00\x00\x00".b => [:isobmff, "mov", "video/quicktime"],
    "\x00\x00\x00\x1CftypM4A \x00\x00\x00\x00".b => [:isobmff, "m4a", "audio/mp4"],
    "\x1A\x45\xDF\xA3\x01\x00\x00\x00\x00\x00\x00\x1F\x42\x86\x81\x01".b => [:webm, "webm", "video/webm"],
    "ID3\x04\x00\x00\x00\x00\x00\x23TSSE\x00\x00".b => [:mp3, "mp3", "audio/mpeg"],
    "\xFF\xFB\x90\x64\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".b => [:mp3, "mp3", "audio/mpeg"],
    "RIFF\x24\x08\x00\x00WAVEfmt ".b => [:wav, "wav", "audio/wav"],
    "OggS\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".b => [:ogg, "ogg", "audio/ogg"]
  }.freeze

  def test_the_first_bytes_name_the_container_and_the_stored_type
    HEADS.each do |head, (container, extension, type)|
      assert_equal container, KR.container_of(head), head.inspect
      found = KR.identify!(file_of(head + ("\x00" * 64)), filename: "call")
      assert_equal [type, extension, head.bytesize + 64], [found.content_type, found.extension, found.byte_size]
    end
  end

  def test_bytes_that_are_no_recording_are_refused_whatever_the_name
    [HTML, "%PDF-1.7\n%\xE2\xE3\xCF\xD3\n1 0 obj", "PK\x03\x04\x14\x00\x00\x00\x08\x00\x00\x00\x00\x00\x00\x00",
     "#!/bin/sh\necho hello world\n", "RIFF\x24\x08\x00\x00AVI LIST", "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01",
     "\xFF\xF1\x50\x80\x00\x1F\xFC\x00\x00\x00\x00\x00\x00\x00\x00\x00", "ftyp", "ID", "\x00\x00\x00\x18ftyp"].each do |bytes|
      %w[call.mp4 call.mp3 call].each do |name|
        assert_raises(KR::NotARecording, "#{bytes.b[0, 12].inspect} as #{name}") do
          KR.identify!(file_of(bytes.b), filename: name)
        end
      end
    end
  end

  def test_the_extension_picks_within_a_container
    { "call.mp4" => "video/mp4", "call.M4V" => "video/mp4", "call.mov" => "video/quicktime",
      "call.m4a" => "audio/mp4", "call" => "video/mp4" }.each do |name, type|
      assert_equal type, KR.identify!(file_of(MP4), filename: name).content_type, name
    end
    webm = HEADS.keys[3] + ("\x00" * 16)
    assert_equal "audio/webm", KR.identify!(file_of(webm), filename: "call.weba").content_type
    ogg = HEADS.keys[7] + ("\x00" * 16)
    assert_equal "video/ogg", KR.identify!(file_of(ogg), filename: "call.ogv").content_type
  end

  def test_an_extension_that_disagrees_with_the_bytes_is_refused
    error = assert_raises(KR::NotARecording) { KR.identify!(file_of(MP4), filename: "call.webm") }
    assert_match(/ends in \.webm but the bytes are isobmff/, error.message)
    assert_raises(KR::NotARecording) { KR.identify!(file_of(MP4), filename: "call.mp3") }
    # Off the list entirely: refused for a local file, whose name the operator chose.
    %w[call.txt call.html call.mkv call.exe call.mp4.php].each do |name|
      assert_raises(KR::NotARecording, name) { KR.identify!(file_of(MP4), filename: name) }
    end
  end

  def test_a_fetched_name_off_the_list_is_ignored_but_a_contradicting_one_is_still_refused
    found = KR.identify!(file_of(MP4), filename: "download.php", strict_extension: false)
    assert_equal ["video/mp4", "mp4"], [found.content_type, found.extension]
    assert_raises(KR::NotARecording) { KR.identify!(file_of(MP4), filename: "call.mp3", strict_extension: false) }
  end

  def test_every_stored_type_is_audio_or_video
    assert(KR::TYPES.values.all? { |type| type.start_with?("audio/", "video/") })
    assert_equal KR::TYPES.keys.sort, KR::CONTAINERS.values.flatten.sort, "every extension belongs to one container"
  end

  # Replacing a recording trashes the old object with ONE CopyObject, which
  # moves at most 5 GiB. A cap above that would store what can never be replaced.
  def test_the_byte_cap_fits_what_the_trash_can_move
    require_relative "../../../lib/studio/s3"
    assert_operator KR::MAX_BYTES, :<=, Studio::S3::Trash::MAX_COPY_BYTES
  end

  def test_empty_missing_oversized_and_directory_sources_are_refused
    assert_raises(KR::NotARecording) { KR.identify!(file_of("")) }
    assert_raises(KR::Refused) { KR.identify!("/no/such/recording.mp4") }
    assert_raises(KR::Refused) { KR.identify!(Dir.tmpdir) }
    error = assert_raises(KR::TooLarge) { KR.identify!(file_of(MP4), filename: "call.mp4", max_bytes: MP4.bytesize - 1) }
    assert_match(/over the #{MP4.bytesize - 1}-byte cap/, error.message)
  end

  def test_only_the_head_of_the_file_is_read
    path = file_of(MP4 + ("\x00" * 100_000))
    sizes = []
    original = File.instance_method(:read)
    File.send(:define_method, :read) do |*args|
      sizes << args.first if path == self.path
      original.bind(self).call(*args)
    end
    begin
      KR.identify!(path, filename: "call.mp4")
    ensure
      File.send(:define_method, :read, original)
    end
    assert_equal [KR::HEAD_BYTES], sizes
  end

  def test_filename_for_keeps_a_bounded_base_and_the_earned_extension
    assert_equal "standup.mp4", KR.filename_for("standup.MOV", "mp4")
    assert_equal "recording.mp4", KR.filename_for("", "mp4")
    assert_equal "recording.mp4", KR.filename_for(nil, "mp4")
    assert_equal "download.mp4", KR.filename_for("/a/b/download", "mp4")
    assert_equal "#{'n' * KR::MAX_FILENAME_CHARS}.mp4", KR.filename_for("#{'n' * 500}.mp4", "mp4")
  end

  def test_web_link_answers_only_an_http_link_a_page_may_render
    assert_equal "https://notes.example.com/calls/abc?x=1", KR.web_link(" https://notes.example.com/calls/abc?x=1 ")
    assert_equal "http://notes.example.com/", KR.web_link("http://notes.example.com/")
    ["javascript:alert(1)", "data:text/html,<script>1</script>", "file:///etc/passwd", "ftp://example.com/a",
     "//example.com/a", "/calls/abc", "notes.example.com", "https://", "https:///path", "", nil, "ht tp://x",
     "JAVASCRIPT:alert(1)", "https://example.com/#{'a' * KR::MAX_URL_BYTES}"].each do |value|
      assert_nil KR.web_link(value), value.inspect
    end
  end

  def test_redact_drops_the_query
    assert_equal "https://files.example.com/a/call.mp4?…", KR.redact("https://files.example.com/a/call.mp4?token=SECRET")
    assert_equal "https://files.example.com/a", KR.redact("https://files.example.com/a")
    assert_equal "(an unparsable URL)", KR.redact("https://exa mple.com/?token=SECRET")
    assert_equal "(a URL with no host)", KR.redact("token=SECRET")
  end

  # ─── the fetch ──────────────────────────────────────────────────────────────

  # Serves `routes` (request path => a lambda handed the socket) on 127.0.0.1,
  # one request per connection, and records each request head.
  def with_listener(routes)
    server = TCPServer.new("127.0.0.1", 0)
    heads = Queue.new
    thread = Thread.new do
      loop do
        client = server.accept
        Thread.new(client) do |socket|
          head = +""
          head << socket.readpartial(4096) until head.include?("\r\n\r\n")
          heads << head
          routes.fetch(head[/\AGET (\S+)/, 1]).call(socket)
        rescue Errno::EPIPE, Errno::ECONNRESET, IOError, KeyError
          nil
        ensure
          socket.close unless socket.closed?
        end
      end
    rescue IOError, Errno::EBADF
      nil
    end
    port = server.addr[1]
    asked = @asked
    KR.define_singleton_method(:connection) do |uri, address|
      asked << [uri.to_s, address]
      raise Errno::ECONNREFUSED, "refused #{address}" if address == "93.184.216.99"

      http = Net::HTTP.new("127.0.0.1", port, nil)
      http.open_timeout = 2
      http.read_timeout = 2
      http
    end
    Timeout.timeout(20) { yield heads }
  ensure
    server&.close
    thread&.join(2)
  end

  def respond(status, headers = {}, body = "")
    lambda do |socket|
      lines = ["HTTP/1.1 #{status} X", "Connection: close"]
      lines << "Content-Length: #{body.bytesize}" unless headers.key?("Content-Length") || headers.key?("Transfer-Encoding")
      headers.each { |name, value| lines << "#{name}: #{value}" }
      socket.write("#{lines.join("\r\n")}\r\n\r\n")
      socket.write(body)
    end
  end

  # A response whose body never ends: 64 KB blocks until the peer hangs up.
  # `sent` receives the running total.
  def endless(status, headers, sent, block: MP4 + ("\x00" * 65_500))
    lambda do |socket|
      socket.write("HTTP/1.1 #{status} X\r\nConnection: close\r\n#{headers.map { |n, v| "#{n}: #{v}\r\n" }.join}\r\n")
      loop do
        socket.write(block)
        sent << block.bytesize
      end
    end
  end

  def dns(map = {})
    known = { "files.example.com" => [PUBLIC_V4], "cdn.example.net" => [OTHER_V4] }.merge(map)
    ->(host) { known.fetch(host) }
  end

  def fetch(url, **options, &block)
    block ||= ->(path, name) { [File.binread(path), name, path] }
    KR.fetch(url, resolver: dns, **options, &block)
  end

  def test_fetch_stores_the_body_yields_it_and_deletes_it_afterwards
    body = MP4 + Random.new(3).bytes(200_000)
    with_listener("/a/standup.mp4?token=SECRET" => respond(200, { "Content-Type" => "video/mp4" }, body)) do |heads|
      bytes, name, path = fetch("https://files.example.com/a/standup.mp4?token=SECRET")
      assert_equal body, bytes
      assert_equal "standup.mp4", name
      refute File.exist?(path), "the temporary file is gone once the block returns"

      head = heads.pop
      assert_match(/^Accept-Encoding: identity\r$/i, head, "no gzip is asked for, so the byte cap counts what arrives")
      assert_match(/^User-Agent: studio-engine knowledge recording fetch\r$/i, head)
    end
  end

  def test_the_connection_is_pinned_to_the_address_the_hop_was_vetted_against
    with_listener("/call.mp4" => respond(200, {}, MP4)) do |_heads|
      fetch("https://files.example.com/call.mp4")
      assert_equal [["https://files.example.com/call.mp4", PUBLIC_V4]], @asked
    end
  end

  def test_production_connections_are_the_guards_pinned_connection
    http = @original_connection.call(URI.parse("https://files.example.com/call.mp4"), PUBLIC_V4)
    assert_equal PUBLIC_V4, http.ipaddr
    assert http.use_ssl?
    assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode
    assert_equal Studio::ImageCache::OPEN_TIMEOUT, http.open_timeout
    assert_equal Studio::ImageCache::READ_TIMEOUT, http.read_timeout
    assert_equal false, http.proxy?
  end

  def test_the_temporary_file_is_deleted_when_the_block_raises
    seen = nil
    with_listener("/call.mp4" => respond(200, {}, MP4)) do |_heads|
      assert_raises(RuntimeError) do
        fetch("https://files.example.com/call.mp4") do |path, _name|
          seen = path
          raise "boom"
        end
      end
    end
    refute File.exist?(seen)
  end

  # Every refusal here happens BEFORE a connection: the seam is never asked.
  def test_urls_refused_before_any_connection
    resolver = dns("rebound.example.com" => ["10.0.0.5"], "mixed.example.com" => [PUBLIC_V4, "127.0.0.1"])
    {
      "http://files.example.com/call.mp4" => /https only/,
      "ftp://files.example.com/call.mp4" => /https only/,
      "file:///etc/passwd" => /https only/,
      "https://user:pw@files.example.com/call.mp4" => /user or password/,
      "https://127.0.0.1/call.mp4" => /loopback/,
      "https://127.1/call.mp4" => /127\.0\.0\.1/,
      "https://2130706433/call.mp4" => /127\.0\.0\.1/,
      "https://0x7f.0.0.1/call.mp4" => /127\.0\.0\.1/,
      "https://[::1]/call.mp4" => /loopback/,
      "https://[::ffff:10.0.0.5]/call.mp4" => /10\.0\.0\.5/,
      "https://10.0.0.5/call.mp4" => /private/,
      "https://192.168.1.1/call.mp4" => /private/,
      "https://172.16.0.9/call.mp4" => /private/,
      "https://169.254.169.254/latest/meta-data" => /link-local/,
      "https://localhost/call.mp4" => /internal hostname/,
      "https://localhost./call.mp4" => /internal hostname/,
      "https://db.internal/call.mp4" => /internal hostname/,
      "https://rebound.example.com/call.mp4" => /10\.0\.0\.5/,
      "https://mixed.example.com/call.mp4" => /127\.0\.0\.1/,
      "https://unknown.example.org/call.mp4" => /could not be resolved/,
      "https://exa mple.com/call.mp4" => /unparsable/,
      "https:///call.mp4" => /host/,
      "" => /https only/,
      "HTTP://files.example.com/call.mp4" => /https only/,
      "//files.example.com/call.mp4" => /https only/,
      " https://files.example.com/call.mp4" => /https only/,
      "https://files.example.com/#{'a' * KR::MAX_URL_BYTES}" => /over the #{KR::MAX_URL_BYTES}-byte cap/
    }.each do |url, named|
      with_listener({}) do |heads|
        error = assert_raises(KR::Refused, "expected #{url[0, 60].inspect} refused") do
          KR.fetch(url, resolver: resolver) { flunk "the block must not run" }
        end
        assert_match named, error.message, url[0, 60]
        assert_empty @asked, "no connection is opened for #{url[0, 60].inspect}"
        assert heads.empty?
      end
    end
  end

  def test_a_host_vetted_against_no_address_is_refused_not_connected_to_by_name
    with_listener({}) do |_heads|
      error = assert_raises(KR::Refused) { KR.fetch("https://files.example.com/call.mp4", resolver: nil) { flunk } }
      assert_match(/vetted against no address/, error.message)
      assert_empty @asked
    end
  end

  def test_the_default_resolver_is_never_none
    previous = Studio::ImageCache.instance_variable_get(:@resolver)
    Studio::ImageCache.resolver = nil
    refute_nil KR.default_resolver
    custom = ->(_host) { [PUBLIC_V4] }
    Studio::ImageCache.resolver = custom
    assert_same custom, KR.default_resolver
  ensure
    Studio::ImageCache.resolver = previous
  end

  # THE TOP TRAP: a public URL that redirects inward. The new host goes through
  # the guard again, and the refused hop is never requested.
  def test_a_redirect_to_a_refused_target_is_refused_and_never_requested
    resolver = dns("rebound.example.com" => ["10.0.0.5"])
    { "https://127.0.0.1/latest" => /loopback/, "https://[::ffff:127.0.0.1]/x" => /127\.0\.0\.1/,
      "https://2130706433/x" => /127\.0\.0\.1/, "https://localhost./x" => /internal hostname/,
      "https://169.254.169.254/latest/meta-data" => /link-local/, "https://rebound.example.com/x" => /10\.0\.0\.5/,
      "http://cdn.example.net/call.mp4" => /https only/, "http://127.0.0.1/x" => /https only/,
      "file:///etc/passwd" => /https only/, "https://user:pw@cdn.example.net/x" => /user or password/,
      "//10.0.0.5/x" => /private/, "https://cdn.example.net/#{'a' * KR::MAX_URL_BYTES}" => /cap/ }.each do |target, named|
      @asked.clear
      with_listener("/call.mp4" => respond(302, { "Location" => target })) do |heads|
        error = assert_raises(KR::Refused, "redirect to #{target[0, 60]}") do
          KR.fetch("https://files.example.com/call.mp4", resolver: resolver) { flunk "the block must not run" }
        end
        assert_match named, error.message, target[0, 60]
        assert_equal [["https://files.example.com/call.mp4", PUBLIC_V4]], @asked, "only the first hop is ever connected"
        heads.pop
        assert heads.empty?
      end
    end
  end

  def test_a_public_redirect_is_followed_vetted_again_and_pinned_to_the_new_hosts_address
    routes = { "/call.mp4" => respond(302, { "Location" => "https://cdn.example.net/store/final.mp4?sig=SECRET" }),
               "/store/final.mp4?sig=SECRET" => respond(200, {}, MP4) }
    with_listener(routes) do |_heads|
      bytes, name, = fetch("https://files.example.com/call.mp4")
      assert_equal MP4, bytes
      assert_equal "final.mp4", name, "the name comes from the URL that answered"
      assert_equal [["https://files.example.com/call.mp4", PUBLIC_V4],
                    ["https://cdn.example.net/store/final.mp4?sig=SECRET", OTHER_V4]], @asked
    end
  end

  def test_a_relative_redirect_stays_on_the_vetted_host
    routes = { "/a/call.mp4" => respond(307, { "Location" => "../b/final.mp4" }), "/b/final.mp4" => respond(200, {}, MP4) }
    with_listener(routes) do |_heads|
      assert_equal MP4, fetch("https://files.example.com/a/call.mp4").first
      assert_equal "https://files.example.com/b/final.mp4", @asked.last.first
    end
  end

  def test_redirects_are_followed_up_to_the_cap_and_no_further
    chain = ->(count) do
      routes = (0...count).to_h { |i| ["/hop#{i}", respond(302, { "Location" => "/hop#{i + 1}" })] }
      routes.merge("/hop#{count}" => respond(200, {}, MP4))
    end
    with_listener(chain.call(KR::MAX_REDIRECTS)) do |_heads|
      assert_equal MP4, fetch("https://files.example.com/hop0").first
      assert_equal KR::MAX_REDIRECTS + 1, @asked.size
    end
    @asked.clear
    with_listener(chain.call(KR::MAX_REDIRECTS + 1)) do |_heads|
      error = assert_raises(KR::FetchFailed) { fetch("https://files.example.com/hop0") }
      assert_match(/too many redirects \(more than #{KR::MAX_REDIRECTS}\)/, error.message)
      assert_equal KR::MAX_REDIRECTS + 1, @asked.size, "the request past the cap is never made"
    end
    @asked.clear
    with_listener("/loop" => respond(302, { "Location" => "/loop" })) do |_heads|
      assert_raises(KR::FetchFailed) { fetch("https://files.example.com/loop") }
      assert_equal KR::MAX_REDIRECTS + 1, @asked.size
    end
  end

  # Net::HTTP reads whatever a block leaves unread, into memory, as the block
  # returns. A redirect or an error with a body that never ends must not be
  # read at all.
  def test_a_redirect_with_an_endless_body_is_followed_without_reading_it
    sent = Queue.new
    routes = { "/call.mp4" => endless(302, { "Location" => "/final.mp4" }, sent), "/final.mp4" => respond(200, {}, MP4) }
    with_listener(routes) do |_heads|
      assert_equal MP4, fetch("https://files.example.com/call.mp4").first
    end
    assert_operator sent.size * 65_536, :<, 16 * 1024 * 1024, "the socket was closed, not drained"
  end

  def test_an_error_with_an_endless_body_fails_without_reading_it
    sent = Queue.new
    with_listener("/call.mp4?token=SECRET" => endless(404, {}, sent)) do |_heads|
      error = assert_raises(KR::FetchFailed) { fetch("https://files.example.com/call.mp4?token=SECRET") }
      assert_match(/answered 404/, error.message)
    end
    assert_operator sent.size * 65_536, :<, 16 * 1024 * 1024
  end

  def test_other_statuses_are_failures_not_recordings
    [204, 206, 304, 401, 403, 500, 503].each do |status|
      with_listener("/call.mp4" => respond(status, { "Content-Type" => "video/mp4" }, status == 204 || status == 304 ? "" : MP4)) do |_heads|
        assert_raises(KR::FetchFailed, status.to_s) { fetch("https://files.example.com/call.mp4") { flunk } }
      end
    end
    with_listener("/call.mp4" => respond(302, {}, "")) do |_heads|
      assert_raises(KR::FetchFailed, "a redirect with no Location") { fetch("https://files.example.com/call.mp4") { flunk } }
    end
  end

  # THE BYTE CAP IS ENFORCED WHILE STREAMING. No Content-Length is declared and
  # the body never ends; the fetch stops at the cap.
  def test_the_byte_cap_stops_a_body_of_undeclared_length_while_it_streams
    sent = Queue.new
    cap = 300_000
    with_listener("/call.mp4" => endless(200, { "Content-Type" => "video/mp4" }, sent)) do |_heads|
      error = assert_raises(KR::TooLarge) { fetch("https://files.example.com/call.mp4", max_bytes: cap) { flunk } }
      assert_match(/sent more than the #{cap}-byte cap/, error.message)
    end
    assert_operator sent.size * 65_536, :<, 16 * 1024 * 1024, "the server was cut off near the cap, not read to the end"
  end

  def test_what_reaches_the_disk_never_passes_the_cap
    cap = 100_000
    sizes = []
    original = KR.method(:store)
    KR.define_singleton_method(:store) do |response, sink, *rest|
      original.call(response, sink, *rest)
    ensure
      sink.flush
      sizes << File.size(sink.path)
    end
    with_listener("/call.mp4" => endless(200, {}, Queue.new)) do |_heads|
      assert_raises(KR::TooLarge) { fetch("https://files.example.com/call.mp4", max_bytes: cap) { flunk } }
    end
    assert_equal 1, sizes.size
    assert_operator sizes.first, :<=, cap, "a chunk is counted before it is written"
  ensure
    KR.define_singleton_method(:store, original)
  end

  # THE BLOCKER (review round 1). Net::HTTP does not raise when a body with a
  # declared length ends early, so a download cut off partway (a CDN timeout
  # on a 1 GB file) was handed on as a complete recording.
  def test_a_body_shorter_than_its_declared_length_fails_and_is_never_yielded
    short = lambda do |socket|
      socket.write("HTTP/1.1 200 X\r\nConnection: close\r\nContent-Type: video/mp4\r\nContent-Length: 1000000\r\n\r\n")
      socket.write(MP4 + ("\x00" * 5000))
    end
    with_listener("/call.mp4" => short) do |heads|
      error = assert_raises(KR::FetchFailed) { fetch("https://files.example.com/call.mp4") { flunk "a short body must not be yielded" } }
      assert_match(/of 1000000 declared/, error.message)
      heads.pop
      assert heads.empty?, "one request, no retry"
    end
  end

  def test_a_body_exactly_at_the_cap_is_stored
    body = MP4 + ("\x00" * 1000)
    with_listener("/call.mp4" => respond(200, {}, body)) do |_heads|
      assert_equal body, fetch("https://files.example.com/call.mp4", max_bytes: body.bytesize).first
    end
  end

  def test_a_declared_length_over_the_cap_is_refused_before_the_body
    sent = Queue.new
    with_listener("/call.mp4" => endless(200, { "Content-Length" => "5000000000" }, sent)) do |_heads|
      error = assert_raises(KR::TooLarge) { fetch("https://files.example.com/call.mp4") { flunk } }
      assert_match(/declares 5000000000 bytes/, error.message)
    end
  end

  def test_a_declared_type_that_is_not_audio_or_video_is_refused_before_the_body
    ["text/html; charset=utf-8", "application/json", "application/pdf", "image/png", "text/plain"].each do |type|
      with_listener("/call.mp4" => endless(200, { "Content-Type" => type }, Queue.new)) do |_heads|
        error = assert_raises(KR::NotARecording, type) { fetch("https://files.example.com/call.mp4") { flunk } }
        assert_match(/not audio or video/, error.message)
      end
    end
  end

  # A server's word is not enough: these all CLAIM a recording, or claim
  # nothing, and send a sign-in page. The first bytes refuse it.
  def test_a_body_that_is_not_a_recording_is_refused_at_its_first_bytes_whatever_was_declared
    [{ "Content-Type" => "video/mp4" }, { "Content-Type" => "application/octet-stream" }, {}].each do |headers|
      sent = Queue.new
      with_listener("/call.mp4" => endless(200, headers, sent, block: HTML * 1200)) do |_heads|
        error = assert_raises(KR::NotARecording, headers.inspect) { fetch("https://files.example.com/call.mp4") { flunk } }
        assert_match(/did not send a recording/, error.message)
      end
      assert_operator sent.size * HTML.bytesize * 1200, :<, 16 * 1024 * 1024
    end
    with_listener("/call.mp4" => respond(200, { "Content-Type" => "video/mp4" }, "ftyp")) do |_heads|
      assert_raises(KR::NotARecording, "too short to judge") { fetch("https://files.example.com/call.mp4") { flunk } }
    end
    with_listener("/call.mp4" => respond(200, { "Content-Type" => "video/mp4" }, "")) do |_heads|
      assert_raises(KR::NotARecording, "empty") { fetch("https://files.example.com/call.mp4") { flunk } }
    end
  end

  def test_a_compressed_body_is_refused
    %w[gzip deflate br].each do |encoding|
      with_listener("/call.mp4" => respond(200, { "Content-Type" => "video/mp4", "Content-Encoding" => encoding }, MP4)) do |_heads|
        error = assert_raises(KR::Refused) { fetch("https://files.example.com/call.mp4") { flunk } }
        assert_match(/only identity is read/, error.message)
      end
    end
  end

  def test_the_whole_fetch_has_a_deadline_read_on_every_chunk
    with_listener("/call.mp4" => endless(200, { "Content-Type" => "video/mp4" }, Queue.new)) do |_heads|
      error = assert_raises(KR::FetchFailed) { fetch("https://files.example.com/call.mp4", deadline: -1) { flunk } }
      assert_match(/did not finish within/, error.message)
    end
  end

  def test_a_server_that_goes_silent_hits_the_read_timeout
    silent = lambda do |socket|
      socket.write("HTTP/1.1 200 X\r\nContent-Type: video/mp4\r\nContent-Length: 1000000\r\n\r\n")
      socket.write(MP4)
      sleep 6
    end
    with_listener("/call.mp4" => silent) do |_heads|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(Net::ReadTimeout) { fetch("https://files.example.com/call.mp4") { flunk } }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    end
  end

  def test_an_unreachable_address_falls_through_to_the_next_vetted_one
    resolver = dns("files.example.com" => ["93.184.216.99", PUBLIC_V4])
    with_listener("/call.mp4" => respond(200, {}, MP4)) do |_heads|
      assert_equal MP4, KR.fetch("https://files.example.com/call.mp4", resolver: resolver) { |path, _| File.binread(path) }
      assert_equal ["93.184.216.99", PUBLIC_V4], @asked.map(&:last)
    end
  end

  def test_at_most_max_addresses_are_tried_and_the_failure_names_no_address
    resolver = dns("files.example.com" => ["93.184.216.99"] * 3 + ["93.184.216.99", PUBLIC_V4, OTHER_V4])
    many = (1..12).map { |n| "93.184.216.#{100 + n}" }
    KR.define_singleton_method(:connection) { |_uri, _address| flunk }
    with_listener("/call.mp4" => respond(200, {}, MP4)) do |_heads|
      asked = @asked
      KR.define_singleton_method(:connection) do |uri, address|
        asked << [uri.to_s, address]
        raise Errno::ECONNREFUSED
      end
      error = assert_raises(KR::FetchFailed) do
        KR.fetch("https://files.example.com/call.mp4?token=SECRET", resolver: ->(_host) { many }) { flunk }
      end
      assert_equal many.first(KR::MAX_ADDRESSES), @asked.map(&:last)
      assert_match(/could not connect to files\.example\.com/, error.message)
      refute_nil resolver
    end
  end

  # A download URL carries its credential in the query. No error may print it.
  def test_no_error_message_carries_the_query_string
    url = "https://files.example.com/call.mp4?token=SECRET-TOKEN-VALUE"
    messages = []
    record = ->(&run) { messages << assert_raises(KR::Error, &run).message }

    with_listener("/call.mp4?token=SECRET-TOKEN-VALUE" => respond(404, {}, "gone")) { |_| record.call { fetch(url) } }
    with_listener("/call.mp4?token=SECRET-TOKEN-VALUE" => respond(200, { "Content-Type" => "text/html" }, HTML)) { |_| record.call { fetch(url) } }
    with_listener("/call.mp4?token=SECRET-TOKEN-VALUE" => respond(200, {}, HTML)) { |_| record.call { fetch(url) } }
    with_listener("/call.mp4?token=SECRET-TOKEN-VALUE" => respond(200, { "Content-Encoding" => "gzip" }, MP4)) { |_| record.call { fetch(url) } }
    with_listener("/call.mp4?token=SECRET-TOKEN-VALUE" => respond(200, { "Content-Length" => "5000000000" }, "")) { |_| record.call { fetch(url) } }
    with_listener("/call.mp4?token=SECRET-TOKEN-VALUE" => respond(200, {}, MP4 * 100)) { |_| record.call { fetch(url, max_bytes: 100) } }
    with_listener("/call.mp4?token=SECRET-TOKEN-VALUE" => respond(302, { "Location" => "/call.mp4?token=SECRET-TOKEN-VALUE" })) { |_| record.call { fetch(url) } }
    with_listener("/call.mp4?token=SECRET-TOKEN-VALUE" => respond(302, { "Location" => "http://files.example.com/x?token=SECRET-TOKEN-VALUE" })) { |_| record.call { fetch(url) } }
    with_listener({}) { |_| record.call { fetch(url.sub("https", "http")) } }
    with_listener({}) { |_| record.call { fetch(url.sub("files.example.com", "127.0.0.1")) } }
    with_listener({}) { |_| record.call { fetch(url.sub("files.example.com", "u:p@files.example.com")) } }
    with_listener({}) { |_| record.call { fetch("https:///x?token=SECRET-TOKEN-VALUE") } }

    assert_equal 12, messages.size
    messages.each { |message| refute_match(/SECRET/, message) }
  end
end
