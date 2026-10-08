# frozen_string_literal: true

require "test_helper"
require "tempfile"
require_relative "../../../lib/studio/image_cache"
require_relative "../../../lib/studio/knowledge_recording"
require_relative "../../support/knowledge_recording_listener"

# [unit] Studio::KnowledgeRecording: what counts as a recording, and the
# guarded fetch of one from a URL.
#
# NO REAL DNS, NO OUTSIDE NETWORK. The fetch tests run real Net::HTTP against a
# listener this file owns on 127.0.0.1 (test/support/knowledge_recording_listener.rb).
# Every host, name and path here is invented.
class StudioKnowledgeRecordingTest < Minitest::Test
  include KnowledgeRecordingListener

  KR = Studio::KnowledgeRecording
  MP4 = ("\x00\x00\x00\x18ftypisom\x00\x00\x02\x00".b + "isomiso2mp41".b).freeze
  BLOCK = (MP4 + ("\x00" * 65_500)).freeze
  HTML = "<!doctype html><html><body>Please sign in</body></html>"

  def setup
    @files = []
    remember_connection!
  end

  def teardown
    restore_connection!
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

  def test_a_name_with_no_extension_is_judged_by_its_bytes_alone
    found = KR.identify!(file_of(MP4), filename: "recording")
    assert_equal ["video/mp4", "mp4"], [found.content_type, found.extension]
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

  # Scheme and host, nothing else: a credential can sit in the path as easily
  # as in the query.
  def test_redact_keeps_scheme_and_host_and_nothing_else
    assert_equal "https://files.example.com/…", KR.redact("https://files.example.com/a/call.mp4?token=SECRET")
    assert_equal "https://files.example.com/…", KR.redact("https://files.example.com/dl/SECRET-IN-PATH/call.mp4")
    assert_equal "https://files.example.com/…", KR.redact("https://user:SECRET@files.example.com:8443/a#SECRET")
    assert_equal "https://files.example.com/…", KR.redact("https://files.example.com")
    assert_equal "ftp://example.com/…", KR.redact("ftp://example.com/a")
    assert_equal "(an unparsable URL)", KR.redact("https://exa mple.com/?token=SECRET")
    assert_equal "(a URL with no host)", KR.redact("token=SECRET")
    assert_equal "(a URL with no host)", KR.redact(nil)
  end

  # ─── the fetch ───

  def fetch(url, **options, &block)
    block ||= ->(path) { [File.binread(path), path] }
    KR.fetch(url, resolver: dns, **options, &block)
  end

  def refuse_fetch(klass, url = "https://files.example.com/call.mp4", **options)
    assert_raises(klass) { fetch(url, **options) { flunk "nothing may be yielded" } }
  end

  def test_fetch_stores_the_body_yields_it_and_deletes_it_afterwards
    body = MP4 + Random.new(3).bytes(200_000)
    with_listener("/a/standup.mp4?token=SECRET" => respond(200, { "Content-Type" => "video/mp4" }, body)) do |heads|
      bytes, path = fetch("https://files.example.com/a/standup.mp4?token=SECRET")
      assert_equal body, bytes
      refute File.exist?(path), "the temporary file is gone once the block returns"
      refute_match(/standup|SECRET/, path, "nothing of the URL names the file")

      head = heads.pop
      assert_match(/^Accept-Encoding: identity\r$/i, head, "no gzip is asked for, so the byte cap counts what arrives")
      assert_match(/^User-Agent: studio-engine knowledge recording fetch\r$/i, head)
    end
  end

  def test_the_block_is_yielded_the_path_and_nothing_from_the_url
    with_listener("/dl/SECRET-IN-PATH" => respond(200, {}, MP4)) do |_heads|
      yielded = nil
      KR.fetch("https://files.example.com/dl/SECRET-IN-PATH", resolver: dns) { |*args| yielded = args }
      assert_equal 1, yielded.size
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

  def test_the_temporary_file_is_deleted_when_the_block_raises_or_is_interrupted
    [RuntimeError, Interrupt, SignalException].each do |klass|
      seen = nil
      with_listener("/call.mp4" => respond(200, {}, MP4)) do |_heads|
        assert_raises(klass) do
          fetch("https://files.example.com/call.mp4") do |path|
            seen = path
            raise klass, klass == SignalException ? "SIGTERM" : "boom"
          end
        end
      end
      refute File.exist?(seen), "#{klass} leaves no file behind"
    end
  end

  # Every refusal here happens BEFORE a connection: the seam is never asked.
  def test_urls_refused_before_any_connection
    resolver = dns("rebound.example.com" => ["10.0.0.5"], "mixed.example.com" => [PUBLIC_V4, "127.0.0.1"])
    {
      "http://files.example.com/call.mp4" => /https only/,
      "ftp://files.example.com/call.mp4" => /https only/,
      "file:///etc/passwd" => /https only/,
      "https://user:pw@files.example.com/call.mp4" => /user or password/,
      "https://files.example.com:8443/call.mp4" => /only port 443/,
      "https://files.example.com:80/call.mp4" => /only port 443/,
      "https://files.example.com:6379/" => /only port 443/,
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
      "https://cdn.example.net:8443/x" => /only port 443/,
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
      assert_equal MP4, fetch("https://files.example.com/call.mp4").first
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
    chain = lambda do |count|
      routes = (0...count).to_h { |i| ["/hop#{i}", respond(302, { "Location" => "/hop#{i + 1}" })] }
      routes.merge("/hop#{count}" => respond(200, {}, MP4))
    end
    with_listener(chain.call(KR::MAX_REDIRECTS)) do |_heads|
      assert_equal MP4, fetch("https://files.example.com/hop0").first
      assert_equal KR::MAX_REDIRECTS + 1, @asked.size
    end
    @asked.clear
    with_listener(chain.call(KR::MAX_REDIRECTS + 1)) do |_heads|
      error = refuse_fetch(KR::FetchFailed, "https://files.example.com/hop0")
      assert_match(/too many redirects \(more than #{KR::MAX_REDIRECTS}\)/, error.message)
      assert_equal KR::MAX_REDIRECTS + 1, @asked.size, "the request past the cap is never made"
    end
    @asked.clear
    with_listener("/loop" => respond(302, { "Location" => "/loop" })) do |_heads|
      refuse_fetch(KR::FetchFailed, "https://files.example.com/loop")
      assert_equal KR::MAX_REDIRECTS + 1, @asked.size
    end
  end

  # Net::HTTP reads whatever a block leaves unread, into memory, as the block
  # returns. A redirect or an error with a body that never ends must not be
  # read at all.
  def test_a_redirect_with_an_endless_body_is_followed_without_reading_it
    sent = Queue.new
    routes = { "/call.mp4" => endless(302, { "Location" => "/final.mp4" }, sent, block: BLOCK),
               "/final.mp4" => respond(200, {}, MP4) }
    with_listener(routes) { |_heads| assert_equal MP4, fetch("https://files.example.com/call.mp4").first }
    assert_operator total(sent), :<, 16 * 1024 * 1024, "the socket was closed, not drained"
  end

  def test_an_error_with_an_endless_body_fails_without_reading_it
    sent = Queue.new
    with_listener("/call.mp4" => endless(404, {}, sent, block: BLOCK)) do |_heads|
      assert_match(/answered 404/, refuse_fetch(KR::FetchFailed).message)
    end
    assert_operator total(sent), :<, 16 * 1024 * 1024
  end

  def test_other_statuses_are_failures_not_recordings
    [204, 206, 304, 401, 403, 500, 503].each do |status|
      body = [204, 304].include?(status) ? "" : MP4
      with_listener("/call.mp4" => respond(status, { "Content-Type" => "video/mp4" }, body)) do |_heads|
        refuse_fetch(KR::FetchFailed)
      end
    end
    with_listener("/call.mp4" => respond(302, {}, "")) { |_heads| refuse_fetch(KR::FetchFailed) }
  end

  # ─── a complete body or nothing ─────────────────────────────────────────────

  # THE BLOCKER (review round 1). Net::HTTP does not raise when a body with a
  # declared length ends early, so a download cut off partway (a CDN timeout
  # on a 1 GB file) was handed on as a complete recording.
  def test_a_body_shorter_than_its_declared_length_fails_and_is_never_yielded
    short = lambda do |socket|
      socket.write("HTTP/1.1 200 X\r\nConnection: close\r\nContent-Type: video/mp4\r\nContent-Length: 1000000\r\n\r\n")
      socket.write(MP4 + ("\x00" * 5000))
    end
    with_listener("/call.mp4" => short) do |heads|
      error = refuse_fetch(KR::FetchFailed)
      assert_match(/sent #{MP4.bytesize + 5000} bytes of 1000000 declared; the download was cut short/, error.message)
      heads.pop
      assert heads.empty?, "one request, no retry"
    end
  end

  def test_a_body_one_byte_short_fails_and_an_exact_one_is_stored
    body = MP4 + ("\x00" * 1000)
    one_short = lambda do |socket|
      socket.write("HTTP/1.1 200 X\r\nConnection: close\r\nContent-Length: #{body.bytesize}\r\n\r\n")
      socket.write(body[0...-1])
    end
    with_listener("/call.mp4" => one_short) { |_heads| refuse_fetch(KR::FetchFailed) }
    with_listener("/call.mp4" => respond(200, {}, body)) do |_heads|
      assert_equal body, fetch("https://files.example.com/call.mp4").first
    end
  end

  def test_a_content_length_that_is_not_one_number_is_refused
    ["12, 12", "-5", "abc", "", "1e3", "12 "].each do |value|
      raw = ->(socket) { socket.write("HTTP/1.1 200 X\r\nConnection: close\r\nContent-Length: #{value}\r\n\r\n#{MP4}") }
      with_listener("/call.mp4" => raw) do |_heads|
        assert_raises(KR::Refused, KR::FetchFailed, value.inspect) { fetch("https://files.example.com/call.mp4") { flunk value.inspect } }
      end
    end
    twice = ->(socket) { socket.write("HTTP/1.1 200 X\r\nConnection: close\r\nContent-Length: 28\r\nContent-Length: 2800\r\n\r\n#{MP4}") }
    with_listener("/call.mp4" => twice) { |_heads| assert_match(/not a number/, refuse_fetch(KR::Refused).message) }
  end

  def chunked(*pieces, finish: "0\r\n\r\n")
    lambda do |socket|
      socket.write("HTTP/1.1 200 X\r\nConnection: close\r\nContent-Type: video/mp4\r\nTransfer-Encoding: chunked\r\n\r\n")
      pieces.each { |piece| socket.write(piece) }
      socket.write(finish)
    end
  end

  def chunk(bytes) = "#{bytes.bytesize.to_s(16)}\r\n#{bytes}\r\n"

  def test_a_chunked_body_is_stored_whole
    with_listener("/call.mp4" => chunked(chunk(MP4), chunk("a" * 5000), chunk("b" * 70_000))) do |_heads|
      assert_equal MP4 + ("a" * 5000) + ("b" * 70_000), fetch("https://files.example.com/call.mp4").first
    end
  end

  def test_a_chunked_body_that_ends_before_its_last_chunk_fails
    { "between chunks" => chunked(chunk(MP4), chunk("a" * 5000), finish: ""),
      "inside a chunk" => chunked(chunk(MP4), "1000\r\nonly a little", finish: ""),
      "inside a chunk-size line" => chunked(chunk(MP4), "10", finish: "") }.each do |name, route|
      with_listener("/call.mp4" => route) do |heads|
        error = assert_raises(KR::FetchFailed, name) { fetch("https://files.example.com/call.mp4") { flunk name } }
        assert_match(/failed mid-fetch: EOFError/, error.message, name)
        heads.pop
        assert heads.empty?, "#{name}: one request, no retry"
      end
    end
  end

  # THE ONE CASE THAT CANNOT BE CHECKED, pinned so the README's sentence about
  # it stays true: no Content-Length and no chunking means the body ends when
  # the connection closes, and a cut there looks exactly like the end.
  def test_a_close_delimited_body_has_no_length_to_check
    undeclared = ->(socket) { socket.write("HTTP/1.1 200 X\r\nConnection: close\r\n\r\n#{MP4}cut here") }
    with_listener("/call.mp4" => undeclared) do |_heads|
      assert_equal "#{MP4}cut here".b, fetch("https://files.example.com/call.mp4").first
    end
  end

  # ─── the byte cap ───────────────────────────────────────────────────────────

  # No Content-Length is declared and the body never ends; the fetch stops at
  # the cap, while it streams.
  def test_the_byte_cap_stops_a_body_of_undeclared_length_while_it_streams
    sent = Queue.new
    cap = 300_000
    with_listener("/call.mp4" => endless(200, { "Content-Type" => "video/mp4" }, sent, block: BLOCK)) do |_heads|
      assert_match(/sent more than the #{cap}-byte cap/, refuse_fetch(KR::TooLarge, max_bytes: cap).message)
    end
    assert_operator total(sent), :<, 16 * 1024 * 1024, "the server was cut off near the cap, not read to the end"
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
    with_listener("/call.mp4" => endless(200, {}, Queue.new, block: BLOCK)) { |_heads| refuse_fetch(KR::TooLarge, max_bytes: cap) }
    assert_equal 1, sizes.size
    assert_operator sizes.first, :<=, cap, "a chunk is counted before it is written"
  ensure
    KR.define_singleton_method(:store, original)
  end

  def test_a_body_exactly_at_the_cap_is_stored
    body = MP4 + ("\x00" * 1000)
    with_listener("/call.mp4" => respond(200, {}, body)) do |_heads|
      assert_equal body, fetch("https://files.example.com/call.mp4", max_bytes: body.bytesize).first
    end
  end

  def test_a_declared_length_over_the_cap_is_refused_before_the_body
    with_listener("/call.mp4" => endless(200, { "Content-Length" => "5000000000" }, Queue.new, block: BLOCK)) do |_heads|
      assert_match(/declares 5000000000 bytes/, refuse_fetch(KR::TooLarge).message)
    end
  end

  # ─── what a server may send ─────────────────────────────────────────────────

  def test_a_declared_type_that_is_not_audio_or_video_is_refused_before_the_body
    ["text/html; charset=utf-8", "application/json", "application/pdf", "image/png", "text/plain"].each do |type|
      with_listener("/call.mp4" => endless(200, { "Content-Type" => type }, Queue.new, block: BLOCK)) do |_heads|
        assert_match(/not audio or video/, refuse_fetch(KR::NotARecording).message)
      end
    end
  end

  # A server's word is not enough: these all CLAIM a recording, or claim
  # nothing, and send a sign-in page. The first bytes refuse it.
  def test_a_body_that_is_not_a_recording_is_refused_at_its_first_bytes_whatever_was_declared
    [{ "Content-Type" => "video/mp4" }, { "Content-Type" => "application/octet-stream" }, {}].each do |headers|
      sent = Queue.new
      with_listener("/call.mp4" => endless(200, headers, sent, block: HTML * 1200)) do |_heads|
        assert_match(/did not send a recording/, refuse_fetch(KR::NotARecording).message)
      end
      assert_operator total(sent), :<, 16 * 1024 * 1024
    end
    with_listener("/call.mp4" => respond(200, { "Content-Type" => "video/mp4" }, "ftyp")) { |_heads| refuse_fetch(KR::NotARecording) }
    with_listener("/call.mp4" => respond(200, { "Content-Type" => "video/mp4" }, "")) { |_heads| refuse_fetch(KR::NotARecording) }
  end

  def test_a_compressed_body_is_refused
    %w[gzip deflate br].each do |encoding|
      with_listener("/call.mp4" => respond(200, { "Content-Type" => "video/mp4", "Content-Encoding" => encoding }, MP4)) do |_heads|
        assert_match(/only identity is read/, refuse_fetch(KR::Refused).message)
      end
    end
  end

  # ─── time, and bytes that never become body ─────────────────────────────────
  #
  # Review round 1 measured five responses that a deadline and a byte cap read
  # only on body chunks never stopped: with `deadline: 1` each was still
  # running at six seconds, three of them past a gigabyte of memory. Each is
  # served here for real. `stopped_within` is the wall clock; `grew` is the
  # process's own resident memory.

  def measure
    before = rss_megabytes
    started = KR.monotonic
    yield
    [KR.monotonic - started, rss_megabytes - before]
  end

  STATUS = "HTTP/1.1 200 X\r\nConnection: close\r\nContent-Type: video/mp4\r\n"

  def test_endless_header_lines_stop_at_the_undelivered_cap
    sent = Queue.new
    route = endless_raw(STATUS, "X-Filler: #{'h' * 1000}\r\n" * 60, sent)
    elapsed, grew = measure do
      with_listener("/call.mp4" => route) do |_heads|
        assert_match(/more than #{KR::MAX_UNDELIVERED_BYTES} bytes of headers or framing/, refuse_fetch(KR::FetchFailed).message)
      end
    end
    assert_operator elapsed, :<, 3
    assert_operator grew, :<, 64, "grew #{grew} MB"
    assert_operator total(sent), :<, 8 * 1024 * 1024, "the server was hung up on"
  end

  def test_one_endless_header_line_stops_at_the_undelivered_cap
    sent = Queue.new
    elapsed, grew = measure do
      with_listener("/call.mp4" => endless_raw("#{STATUS}X-Endless: ", "h" * 60_000, sent)) do |_heads|
        assert_match(/headers or framing/, refuse_fetch(KR::FetchFailed).message)
      end
    end
    assert_operator elapsed, :<, 3
    assert_operator grew, :<, 64, "grew #{grew} MB"
  end

  def test_an_endless_chunk_size_line_stops_at_the_undelivered_cap
    sent = Queue.new
    head = "#{STATUS}Transfer-Encoding: chunked\r\n\r\n#{chunk(MP4)}"
    elapsed, grew = measure do
      with_listener("/call.mp4" => endless_raw(head, "f" * 60_000, sent)) do |_heads|
        assert_match(/headers or framing/, refuse_fetch(KR::FetchFailed).message)
      end
    end
    assert_operator elapsed, :<, 3
    assert_operator grew, :<, 64, "grew #{grew} MB"
  end

  def test_endless_trailers_stop_at_the_undelivered_cap
    head = "#{STATUS}Transfer-Encoding: chunked\r\n\r\n#{chunk(MP4)}0\r\n"
    with_listener("/call.mp4" => endless_raw(head, "X-Trailer: #{'t' * 1000}\r\n" * 60, Queue.new)) do |_heads|
      assert_match(/headers or framing|mid-fetch/, refuse_fetch(KR::FetchFailed).message)
    end
  end

  def test_an_endless_stream_of_100_continue_stops
    sent = Queue.new
    elapsed, grew = measure do
      with_listener("/call.mp4" => endless_raw("", "HTTP/1.1 100 Continue\r\n\r\n" * 400, sent)) do |_heads|
        assert_match(/headers or framing/, refuse_fetch(KR::FetchFailed).message)
      end
    end
    assert_operator elapsed, :<, 3
    assert_operator grew, :<, 64, "grew #{grew} MB"
  end

  # Slow enough that no size cap is reached: only a clock can stop these.
  def test_headers_dripped_slowly_stop_at_the_header_deadline
    route = endless_raw(STATUS, "X-Drip: 1\r\n", Queue.new, every: 0.2)
    elapsed, = measure do
      with_listener("/call.mp4" => route) do |_heads|
        error = refuse_fetch(KR::FetchFailed, header_deadline: 1)
        assert_match(/did not finish in time/, error.message)
      end
    end
    assert_operator elapsed, :>=, 0.9
    assert_operator elapsed, :<, 2.5, "stopped at the header deadline, not a read timeout later (#{elapsed.round(2)} s)"
  end

  def test_100_continue_dripped_slowly_stops_at_the_header_deadline
    route = endless_raw("", "HTTP/1.1 100 Continue\r\n\r\n", Queue.new, every: 0.2)
    elapsed, = measure do
      with_listener("/call.mp4" => route) { |_heads| refuse_fetch(KR::FetchFailed, header_deadline: 1) }
    end
    assert_operator elapsed, :<, 2.5
  end

  def test_a_server_that_accepts_and_says_nothing_stops_at_the_header_deadline
    elapsed, = measure do
      with_listener("/call.mp4" => ->(_socket) { sleep 5 }) { |_heads| refuse_fetch(KR::FetchFailed, header_deadline: 1) }
    end
    assert_operator elapsed, :<, 1.8, "the wait itself is cut to the time left"
  end

  # 'A whole fetch: 3,600 seconds' has to be true of every phase. With one
  # second for the WHOLE fetch and the header deadline left at its default:
  def test_the_whole_fetch_deadline_covers_headers_redirects_and_body
    drip = endless_raw(STATUS, "X-Drip: 1\r\n", Queue.new, every: 0.2)
    slow_hops = (0..3).to_h do |i|
      ["/hop#{i}", lambda { |socket|
        sleep 0.6
        socket.write("HTTP/1.1 302 X\r\nConnection: close\r\nLocation: /hop#{i + 1}\r\nContent-Length: 0\r\n\r\n")
      }]
    end
    body_drip = endless_raw("#{STATUS}\r\n#{MP4}", "\x00" * 10, Queue.new, every: 0.2)
    chunk_drip = endless_raw("#{STATUS}Transfer-Encoding: chunked\r\n\r\n#{chunk(MP4)}", "f", Queue.new, every: 0.2)

    { "dripped headers" => ["/call.mp4", { "/call.mp4" => drip }],
      "slow redirects" => ["/hop0", slow_hops],
      "a dripped body" => ["/call.mp4", { "/call.mp4" => body_drip }],
      "a dripped chunk-size line" => ["/call.mp4", { "/call.mp4" => chunk_drip }] }.each do |name, (path, routes)|
      elapsed, = measure do
        with_listener(routes) do |_heads|
          error = assert_raises(KR::FetchFailed, name) { fetch("https://files.example.com#{path}", deadline: 1) { flunk name } }
          assert_match(/did not finish/, error.message, name)
        end
      end
      assert_operator elapsed, :<, 2.5, "#{name}: #{elapsed.round(2)} s against a 1 s deadline"
    end
  end

  # The header deadline is for the headers. Once they are in, a body may take
  # as long as the whole fetch allows.
  def test_a_body_may_outlast_the_header_deadline
    slow = lambda do |socket|
      socket.write("HTTP/1.1 200 X\r\nConnection: close\r\nContent-Length: #{MP4.bytesize + 4}\r\n\r\n#{MP4}")
      4.times do
        sleep 0.25
        socket.write("z")
      end
    end
    with_listener("/call.mp4" => slow) do |_heads|
      assert_equal "#{MP4}zzzz".b, fetch("https://files.example.com/call.mp4", header_deadline: 0.4).first
    end
  end

  def test_a_deadline_already_passed_makes_no_connection
    with_listener("/call.mp4" => respond(200, {}, MP4)) do |heads|
      refuse_fetch(KR::FetchFailed, deadline: -1)
      assert_empty @asked
      assert heads.empty?
    end
  end

  # Net::HTTP retries a GET once after a read timeout, on a new socket, and
  # calls the response block again. That would write the body to the sink
  # twice, and the second socket would carry no meter.
  def test_a_server_that_goes_silent_mid_body_fails_once_with_no_retry
    silent = lambda do |socket|
      socket.write("HTTP/1.1 200 X\r\nContent-Type: video/mp4\r\nContent-Length: 1000000\r\n\r\n")
      socket.write(MP4)
      sleep 6
    end
    with_listener("/call.mp4" => silent) do |heads|
      elapsed, = measure { assert_match(/failed mid-fetch: Net::ReadTimeout/, refuse_fetch(KR::FetchFailed).message) }
      assert_operator elapsed, :<, 3.5, "one 2 s read timeout, not two"
      heads.pop
      assert heads.empty?, "one request: the fetch turns Net::HTTP's retry off"
    end
  end

  def test_mid_fetch_transport_failures_are_fetch_failures_naming_only_the_host
    reset = lambda do |socket|
      socket.write("HTTP/1.1 200 X\r\nContent-Length: 1000000\r\n\r\n#{MP4}")
      socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii"))
    end
    garbage = ->(socket) { socket.write("this is not HTTP at all\r\n\r\n") }
    hangup = ->(_socket) {}
    { "a reset" => reset, "a response that is not HTTP" => garbage, "a hang-up before any response" => hangup }.each do |name, route|
      with_listener("/dl/SECRET-IN-PATH?token=SECRET" => route) do |_heads|
        error = assert_raises(KR::FetchFailed, name) { fetch("https://files.example.com/dl/SECRET-IN-PATH?token=SECRET") { flunk name } }
        assert_match(%r{\Ahttps://files\.example\.com/… }, error.message, name)
        refute_match(/SECRET/, error.message, name)
      end
    end
  end

  def test_a_tls_failure_is_a_fetch_failure
    KR.define_singleton_method(:connection) { |_uri, _address| Object.new.tap { |http| def http.max_retries=(_); end; def http.start = raise(OpenSSL::SSL::SSLError, "certificate verify failed"); def http.started? = false } }
    error = assert_raises(KR::FetchFailed) { fetch("https://files.example.com/call.mp4") { flunk } }
    assert_match(/failed mid-fetch: OpenSSL::SSL::SSLError: certificate verify failed/, error.message)
  end

  # ─── the meter ──────────────────────────────────────────────────────────────

  def test_the_fetch_turns_retries_off_and_meters_the_one_socket
    seen = nil
    original = KR::Meter.method(:install!)
    KR::Meter.define_singleton_method(:install!) do |http, stop_at|
      seen = [http.max_retries, http.started?]
      original.call(http, stop_at).tap { |meter| seen << http.instance_variable_get(:@socket).io.equal?(meter) }
    end
    with_listener("/call.mp4" => respond(200, {}, MP4)) { |_heads| fetch("https://files.example.com/call.mp4") }
    assert_equal [0, true, true], seen
  ensure
    KR::Meter.define_singleton_method(:install!, original)
  end

  # net-http offers no hook, so the meter reaches for two instance variables.
  # On a net-http where they are not what it expects, the fetch is REFUSED.
  def test_a_net_http_the_meter_cannot_read_is_refused_not_run_unmetered
    fake = Struct.new(:socket) { def instance_variable_get(name) = name == :@socket ? socket : nil }
    [nil, Object.new, Net::BufferedIO.new(nil)].each do |socket|
      error = assert_raises(KR::FetchFailed) { KR::Meter.install!(fake.new(socket), KR.monotonic + 5) }
      assert_match(/cannot be metered, so the fetch was not made/, error.message)
    end
  end

  def test_the_meter_counts_what_has_not_become_body_and_cuts_waits_to_the_time_left
    reader, writer = IO.pipe
    meter = KR::Meter.new(reader, KR.monotonic + 0.3)
    writer.write("x" * 40_000)
    assert_equal 40_000, meter.read_nonblock(40_000).bytesize
    meter.delivered!
    writer.write("x" * 40_000)
    meter.read_nonblock(40_000)
    writer.write("x" * 40_000)
    assert_raises(KR::Meter::Overrun) { meter.read_nonblock(40_000) }

    assert_equal :wait_readable, meter.read_nonblock(10, exception: false)
    assert_nil meter.to_io.wait_readable(0.05), "a wait shorter than the time left runs out on its own: the caller's read timeout"
    started = KR.monotonic
    assert_raises(KR::Meter::Expired, "a 30 s wait is cut to the time left, and running out then is the deadline") do
      meter.to_io.wait_readable(30)
    end
    assert_operator KR.monotonic - started, :<, 1
    assert_raises(KR::Meter::Expired) { meter.read_nonblock(10, exception: false) }
    assert_raises(KR::Meter::Expired) { meter.to_io.wait_readable(30) }
    assert_raises(KR::Meter::Expired) { meter.to_io.wait_writable(30) }
  ensure
    reader&.close
    writer&.close
  end

  # ─── addresses ──────────────────────────────────────────────────────────────

  def test_an_unreachable_address_falls_through_to_the_next_vetted_one
    resolver = dns("files.example.com" => [DEAD_V4, PUBLIC_V4])
    with_listener("/call.mp4" => respond(200, {}, MP4)) do |_heads|
      assert_equal MP4, KR.fetch("https://files.example.com/call.mp4", resolver: resolver) { |path| File.binread(path) }
      assert_equal [DEAD_V4, PUBLIC_V4], @asked.map(&:last)
    end
  end

  def test_only_a_failure_to_connect_moves_to_the_next_address
    resolver = dns("files.example.com" => [PUBLIC_V4, OTHER_V4])
    with_listener("/call.mp4" => respond(500, {}, "no")) do |_heads|
      assert_raises(KR::FetchFailed) { KR.fetch("https://files.example.com/call.mp4", resolver: resolver) { flunk } }
      assert_equal [PUBLIC_V4], @asked.map(&:last), "a request that was answered is not repeated elsewhere"
    end
  end

  def test_at_most_max_addresses_are_tried_and_the_failure_names_no_address
    many = (1..12).map { |n| "93.184.216.#{100 + n}" }
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
    refute_match(/93\.184|SECRET/, error.message)
  end

  def test_a_connection_that_does_not_open_in_time_is_unreachable
    stuck = Object.new
    def stuck.max_retries=(_); end
    def stuck.start = sleep(5)
    def stuck.started? = false
    KR.define_singleton_method(:connection) { |_uri, _address| stuck }
    started = KR.monotonic
    error = assert_raises(KR::FetchFailed) { fetch("https://files.example.com/call.mp4", deadline: 0.5) { flunk } }
    assert_operator KR.monotonic - started, :<, 2, "the connect is cut to the time the fetch has left"
    assert_match(/could not connect/, error.message)
  end

  # ─── what an error may print ────────────────────────────────────────────────

  # A download URL carries its credential in the query or in the path. No
  # error may print either.
  def test_no_error_message_carries_the_query_string_or_the_path
    path = "/dl/PATH-SECRET/call.mp4?token=QUERY-SECRET"
    url = "https://files.example.com#{path}"
    messages = []
    record = ->(&run) { messages << assert_raises(KR::Error, &run).message }
    short = ->(socket) { socket.write("HTTP/1.1 200 X\r\nConnection: close\r\nContent-Length: 999999\r\n\r\n#{MP4}") }

    with_listener(path => respond(404, {}, "gone")) { |_| record.call { fetch(url) } }
    with_listener(path => respond(200, { "Content-Type" => "text/html" }, HTML)) { |_| record.call { fetch(url) } }
    with_listener(path => respond(200, {}, HTML)) { |_| record.call { fetch(url) } }
    with_listener(path => respond(200, { "Content-Encoding" => "gzip" }, MP4)) { |_| record.call { fetch(url) } }
    with_listener(path => respond(200, { "Content-Length" => "5000000000" }, "")) { |_| record.call { fetch(url) } }
    with_listener(path => respond(200, {}, MP4 * 100)) { |_| record.call { fetch(url, max_bytes: 100) } }
    with_listener(path => respond(302, { "Location" => path })) { |_| record.call { fetch(url) } }
    with_listener(path => respond(302, { "Location" => "http://files.example.com#{path}" })) { |_| record.call { fetch(url) } }
    with_listener(path => short) { |_| record.call { fetch(url) } }
    with_listener(path => ->(_socket) {}) { |_| record.call { fetch(url) } }
    with_listener(path => ->(_socket) { sleep 3 }) { |_| record.call { fetch(url, header_deadline: 0.3) } }
    with_listener(path => endless_raw("HTTP/1.1 200 X\r\n", "X: #{'h' * 1000}\r\n" * 60, Queue.new)) { |_| record.call { fetch(url) } }
    with_listener({}) { |_| record.call { fetch(url.sub("https", "http")) } }
    with_listener({}) { |_| record.call { fetch(url.sub("files.example.com", "127.0.0.1")) } }
    with_listener({}) { |_| record.call { fetch(url.sub("files.example.com", "u:p@files.example.com")) } }
    with_listener({}) { |_| record.call { fetch(url.sub("files.example.com", "files.example.com:8443")) } }
    with_listener({}) { |_| record.call { fetch("https:///x/PATH-SECRET?token=QUERY-SECRET") } }

    assert_equal 17, messages.size
    messages.each { |message| refute_match(/SECRET|call\.mp4|\/dl\//, message) }
  end
end
