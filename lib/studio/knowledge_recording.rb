# frozen_string_literal: true

require "delegate"

module Studio
  # The rules for a knowledge document's RECORDING (the audio or video of a
  # meeting whose transcript is the document): what counts as one, how big it
  # may be, and how one is fetched from a URL. Studio::KnowledgeDoc#attach_recording!
  # and #attach_recording_from_url! are the callers; the upload itself is
  # Studio::S3::Multipart.
  #
  # Loaded on first use (`require "studio/knowledge_recording"`), not by
  # `require "studio"`, so an app that never attaches a recording pays nothing.
  #
  # WHAT COUNTS AS A RECORDING. The file's own first bytes decide, never a
  # name alone and never a header a remote server sent:
  #
  #   container            first bytes                stored as
  #   MP4 / M4V / MOV / M4A  ....ftyp                 video/mp4, video/quicktime, audio/mp4
  #   WebM                 1A 45 DF A3                video/webm, audio/webm
  #   MP3                  ID3, or an MPEG frame sync audio/mpeg
  #   WAV                  RIFF....WAVE               audio/wav
  #   Ogg                  OggS                       audio/ogg, video/ogg
  #
  # The extension picks WITHIN a container (`.m4a` is audio/mp4, `.mov` is
  # video/quicktime) and must agree with it: a file named `.mp4` whose bytes
  # are WebM is refused, and so is any extension off the list. The stored
  # content type always comes from TYPES, so the bucket never serves a
  # recording as text/html or anything else a browser would run.
  #
  # THE BOUNDS. README, "Knowledge recordings", walks every phase of a fetch
  # and of an upload with its time bound, its size bound and what is left
  # behind if the process dies there. The constants are below; `fetch` and
  # Meter say how each is enforced.
  module KnowledgeRecording
    class Error < StandardError; end
    # The source was refused before, or instead of, being stored.
    class Refused < Error; end
    class NotARecording < Refused; end
    class TooLarge < Refused; end
    class FetchFailed < Error; end

    # 4 GB. Recordings run 100 MB to 1 GB; this leaves room for a long
    # meeting in high definition and still fits a dyno's ephemeral disk.
    # It must stay at or under Studio::S3::Trash::MAX_COPY_BYTES (5 GiB): a
    # replaced recording is trashed with one CopyObject, and a larger object
    # could be stored but never replaced. The suite pins the two together.
    MAX_BYTES = 4 * 1024 * 1024 * 1024
    # Long enough for a presigned download URL, short enough that a redirect
    # cannot hand us a megabyte of Location header to parse.
    MAX_URL_BYTES = 8_192
    MAX_REDIRECTS = 3
    MAX_ADDRESSES = 4
    # One hour for the whole fetch: every connect, every response's headers,
    # every redirect and the body. Enforced on every read and write of the
    # socket (Meter), not only as body chunks arrive. The one thing that can
    # run past it is a DNS lookup already in flight (ImageCache's
    # RESOLVE_DEADLINE, 6 s).
    FETCH_DEADLINE = 3_600
    # Seconds for one address to accept a connection and finish TLS.
    CONNECT_DEADLINE = 20
    # Seconds from sending a request to having its status line and headers,
    # any 1xx responses included.
    HEADER_DEADLINE = 30
    # Bytes that may come off the socket without becoming body: the status
    # line, headers and 1xx responses of one hop together, and after that the
    # chunk-size lines and trailers between two pieces of body. Net::HTTP
    # buffers these in memory with no limit of its own.
    MAX_UNDELIVERED_BYTES = 64 * 1024
    # The only port fetched from. A download link is https on 443; any other
    # port would let the fetch be pointed at arbitrary services on public hosts.
    PORT = 443
    HEAD_BYTES = 16
    MAX_FILENAME_CHARS = 80
    # Refused before any bytes are read when the declared type is something
    # else. A server may say nothing, or octet-stream; the bytes still decide.
    GENERIC_CONTENT_TYPES = %w[application/octet-stream binary/octet-stream].freeze
    REDIRECT_STATUSES = [301, 302, 303, 307, 308].freeze

    # extension => the content type it is stored under.
    TYPES = {
      "mp4" => "video/mp4",
      "m4v" => "video/mp4",
      "mov" => "video/quicktime",
      "m4a" => "audio/mp4",
      "webm" => "video/webm",
      "weba" => "audio/webm",
      "mp3" => "audio/mpeg",
      "wav" => "audio/wav",
      "ogg" => "audio/ogg",
      "oga" => "audio/ogg",
      "ogv" => "video/ogg"
    }.freeze

    # container => the extensions that may name it. The first is the default
    # for a source with no extension.
    CONTAINERS = {
      isobmff: %w[mp4 m4v mov m4a],
      webm: %w[webm weba],
      mp3: %w[mp3],
      wav: %w[wav],
      ogg: %w[ogg oga ogv]
    }.freeze

    # ISO base media brands that name something other than the default.
    ISOBMFF_BRANDS = { "qt  " => "mov", "M4A " => "m4a", "M4B " => "m4a" }.freeze
    # Second byte of an MPEG-1/2/2.5 Layer III frame header after 0xFF.
    MP3_SYNC_BYTES = [0xFB, 0xFA, 0xF3, 0xF2, 0xE3, 0xE2].freeze
    EBML_MAGIC = "\x1A\x45\xDF\xA3".b.freeze

    # What `identify!` answers: the content type to store, the extension the
    # object key ends in, and the size read from the open file.
    Identified = Struct.new(:content_type, :extension, :byte_size, keyword_init: true)

    class << self
      # The container the first bytes name, or nil. `head` is at most
      # HEAD_BYTES long; nothing here scans.
      def container_of(head)
        head = head.to_s.b
        return :isobmff if head.bytesize >= 12 && head.byteslice(4, 4) == "ftyp"
        return :webm if head.start_with?(EBML_MAGIC)
        return :wav if head.bytesize >= 12 && head.start_with?("RIFF") && head.byteslice(8, 4) == "WAVE"
        return :ogg if head.start_with?("OggS")
        return :mp3 if head.start_with?("ID3")
        return :mp3 if head.bytesize >= 2 && head.getbyte(0) == 0xFF && MP3_SYNC_BYTES.include?(head.getbyte(1))

        nil
      end

      # Reads HEAD_BYTES of the file at `path` and answers an Identified, or
      # raises: NotARecording when the bytes are no container on the list or
      # the extension disagrees with them, TooLarge past MAX_BYTES.
      #
      # `filename` is the name whose extension is judged (default: the
      # path's). A name with no extension is judged by its bytes alone.
      def identify!(path, filename: nil, max_bytes: MAX_BYTES)
        path = path.to_s
        raise Refused, "no such file: #{path}" unless File.file?(path)

        head, size = File.open(path, "rb") { |file| [file.read(HEAD_BYTES), file.size] }
        raise NotARecording, "#{File.basename(path)} is empty" if size.zero?
        raise TooLarge, "#{File.basename(path)} is #{size} bytes, over the #{max_bytes}-byte cap" if size > max_bytes

        container = container_of(head) ||
          raise(NotARecording, "#{File.basename(path)} is not a recording: its first bytes are not MP4, MOV, M4A, " \
                               "WebM, MP3, WAV or Ogg")
        extension = extension_for(container, head, filename || path)
        Identified.new(content_type: TYPES.fetch(extension), extension: extension, byte_size: size)
      end

      # A file name for the object key: the source's base name, cut to
      # MAX_FILENAME_CHARS, with the extension the bytes earned. The caller
      # sanitizes it (Studio::KnowledgeDoc.sanitize_filename).
      def filename_for(name, extension)
        base = File.basename(name.to_s, ".*")[0, MAX_FILENAME_CHARS].to_s
        base = "recording" if base.strip.empty?
        "#{base}.#{extension}"
      end

      # `url` as it may be printed or logged: scheme and host, nothing else. A
      # download URL carries its credential in the query or in the path, and
      # every failure message reaches a log drain.
      def redact(url)
        require "uri"
        uri = URI.parse(url.to_s)
        return "(a URL with no host)" if uri.host.to_s.empty?

        "#{uri.scheme}://#{uri.host[0, 253]}/…"
      rescue URI::InvalidURIError
        "(an unparsable URL)"
      end

      # A link a page may render: an http(s) URL with a host, at most
      # MAX_URL_BYTES long. Answers the stripped String, or nil. This is the
      # check on recording_source_url, which is DISPLAYED and never fetched,
      # so it asks only that the link cannot be `javascript:` or `data:`.
      def web_link(value)
        require "uri"
        text = value.to_s.strip
        return nil if text.empty? || text.bytesize > MAX_URL_BYTES

        uri = URI.parse(text)
        %w[http https].include?(uri.scheme) && !uri.host.to_s.empty? ? text : nil
      rescue URI::InvalidURIError
        nil
      end

      # Downloads `url` to a temporary file and yields its path. The file is
      # deleted when the block returns or raises (an interrupt included).
      #
      # THIS IS A SERVER-SIDE FETCH OF A CALLER-SUPPLIED URL, run with the
      # bucket's credentials in the process. Every hop, the first and each
      # redirect, goes through Studio::ImageCache.vet_source_url! (the engine's
      # one SSRF guard: public addresses only, however the host is written and
      # wherever its name resolves), must be https on port 443, may carry no
      # user:password, and is connected to an address that hop was vetted
      # against (ImageCache.pinned_http), so the name cannot resolve somewhere
      # else between the check and the connection. A host that vets to NO
      # address (no resolver) is refused rather than connected to by name.
      #
      # WHAT IS YIELDED IS A COMPLETE BODY OR NOTHING. A response that declares
      # a Content-Length and sends any other number of bytes raises FetchFailed
      # before the block runs; so does a chunked body that ends before its last
      # chunk. A body with NO declared length and no chunking ends when the
      # server closes the connection, and a cut there cannot be told from the
      # end: that one case is unchecked.
      #
      # Nothing of the URL's path is used to name the file: a path can carry
      # the credential.
      #
      # `resolver:` is the callable names resolve with. The default is the
      # guard's own, or the system resolver where the guard's default is none
      # (a Rails test environment): this fetch never runs unresolved.
      def fetch(url, max_bytes: MAX_BYTES, resolver: default_resolver, deadline: FETCH_DEADLINE,
                header_deadline: HEADER_DEADLINE)
        require "tempfile"
        stop_at = monotonic + deadline
        current = url.to_s
        answer = nil

        Tempfile.create(["studio-knowledge-recording", ".part"]) do |sink|
          sink.binmode
          # Bounded: MAX_REDIRECTS + 1 requests at most.
          (MAX_REDIRECTS + 1).times do
            raise FetchFailed, "#{redact(url)} did not finish within #{deadline} seconds" if monotonic > stop_at

            vetted = vet!(current, resolver)
            answer = request(vetted, sink, max_bytes, stop_at, header_deadline)
            break unless answer.is_a?(String)

            current = join_location(vetted.uri, answer)
          end
          raise FetchFailed, "too many redirects (more than #{MAX_REDIRECTS}) from #{redact(url)}" if answer.is_a?(String)

          sink.flush
          return yield(sink.path)
        end
      end

      def default_resolver
        require "studio/image_cache"
        Studio::ImageCache.resolver || Studio::ImageCache::SYSTEM_RESOLVER
      end

      # The connection for one vetted address. A seam: the suite replaces it;
      # production is always the guard's pinned connection.
      def connection(uri, address)
        Studio::ImageCache.pinned_http(uri, address)
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      private

      def extension_for(container, head, name)
        allowed = CONTAINERS.fetch(container)
        given = File.extname(name.to_s).delete_prefix(".").downcase
        return default_extension(container, head) if given.empty?
        return given if allowed.include?(given)

        raise NotARecording, "the name ends in .#{given[0, 16]} but the bytes are #{container} " \
                             "(expected one of: #{allowed.map { |ext| ".#{ext}" }.join(', ')})"
      end

      def default_extension(container, head)
        return CONTAINERS.fetch(container).first unless container == :isobmff

        ISOBMFF_BRANDS.fetch(head.to_s.b.byteslice(8, 4).to_s, "mp4")
      end

      # One hop through the guard, plus what this fetch adds to it: https on
      # port 443 only, no credentials in the URL, a length cap, and at least
      # one vetted address to pin the connection to.
      def vet!(url, resolver)
        require "studio/image_cache"
        raise Refused, "URL is #{url.bytesize} bytes, over the #{MAX_URL_BYTES}-byte cap" if url.bytesize > MAX_URL_BYTES
        # Asked of the text first so a URL that is not https costs no DNS
        # lookup. The parsed scheme is checked again below; that one decides.
        unless url[0, 8].to_s.casecmp?("https://")
          raise Refused, "refused #{redact(url)}: a recording is fetched over https only"
        end

        vetted =
          begin
            Studio::ImageCache.vet_source_url!(url, resolver: resolver)
          rescue Studio::ImageCache::InvalidSourceURL => error
            raise Refused, "refused #{redact(url)}: #{error.message.gsub(url.inspect, redact(url))}"
          rescue URI::InvalidURIError
            raise Refused, "refused an unparsable URL"
          end

        raise Refused, "refused #{redact(url)}: a recording is fetched over https only" unless vetted.uri.scheme == "https"
        raise Refused, "refused #{redact(url)}: only port #{PORT} is fetched from" unless vetted.uri.port == PORT
        raise Refused, "refused #{redact(url)}: the URL carries a user or password" if vetted.uri.userinfo
        raise Refused, "refused #{redact(url)}: its host was vetted against no address" if vetted.addresses.empty?

        vetted
      end

      def join_location(base, location)
        raise Refused, "redirect Location is over the #{MAX_URL_BYTES}-byte cap" if location.bytesize > MAX_URL_BYTES

        URI.join(base, location).to_s
      rescue URI::InvalidURIError
        raise Refused, "refused a redirect to an unparsable URL from #{redact(base.to_s)}"
      end

      # One GET to the first vetted address that accepts a connection, at most
      # MAX_ADDRESSES of them. Answers :stored, or the Location of a redirect.
      # Only a failure to CONNECT moves on to the next address; once a request
      # has been sent, a failure is the fetch's failure.
      def request(vetted, sink, max_bytes, stop_at, header_deadline)
        candidates = vetted.addresses.first(MAX_ADDRESSES)

        candidates.each_with_index do |address, index|
          sink.rewind
          sink.truncate(0)
          return get(vetted.uri, address, sink, max_bytes, stop_at, header_deadline)
        rescue Unreachable => error
          next unless index == candidates.size - 1

          raise FetchFailed, "could not connect to #{vetted.host}: #{error.message}"
        end
      end

      # An address that would not take a connection in time.
      Unreachable = Class.new(StandardError)
      ConnectTimedOut = Class.new(StandardError)
      private_constant :Unreachable, :ConnectTimedOut

      # A connected, TLS-verified Net::HTTP for one address, or Unreachable.
      #
      # The Timeout here is the ONE place a timeout wrapper is used, and it
      # covers only the connect and the TLS handshake: Net::HTTP bounds the TCP
      # connect itself but gives each wait of the handshake its own
      # open_timeout, so a peer that drips handshake bytes is otherwise bounded
      # only by OpenSSL's size limits. It is safe here because nothing of ours
      # exists yet to be left half-done: no request has been sent and the sink
      # is empty, and Net::HTTP#connect closes the socket on any StandardError
      # (ConnectTimedOut is one) before re-raising. After this, no timeout
      # wrapper is used at all; time is bounded inside the reads (Meter).
      def open!(uri, address, stop_at)
        require "net/http"
        require "timeout"
        remaining = stop_at - monotonic
        raise FetchFailed, "#{redact(uri.to_s)} did not finish in time" if remaining <= 0

        http = connection(uri, address)
        # Net::HTTP retries an idempotent request once on a read timeout or a
        # reset, on a NEW socket, and calls the response block again: the body
        # would be written to the sink twice and the retry would be unmetered.
        http.max_retries = 0
        Timeout.timeout([CONNECT_DEADLINE, remaining].min, ConnectTimedOut) { http.start }
        http
      rescue ConnectTimedOut, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EADDRNOTAVAIL,
             Net::OpenTimeout, SocketError => error
        # The deadline can land just as the connection finishes; a socket
        # that did open is closed, not left for the collector.
        hang_up(http)
        raise Unreachable, error.class.name
      end

      # THE RESPONSE BODY IS NEVER READ UNBOUNDED. Net::HTTP drains whatever a
      # block leaves unread, into memory, when the block returns; so a redirect
      # or an error is left by `throw`, which unwinds past the drain, and the
      # connection is closed with the body unread.
      #
      # Every failure after the connection is made leaves here as FetchFailed
      # (or a Refused), naming the host and never the rest of the URL.
      def get(uri, address, sink, max_bytes, stop_at, header_deadline)
        require "openssl"
        http = open!(uri, address, stop_at)
        meter = Meter.install!(http, [stop_at, monotonic + header_deadline].min)

        catch(:answered) do
          request = Net::HTTP::Get.new(uri.request_uri)
          # identity: Net::HTTP would otherwise ask for gzip and inflate it,
          # and the byte cap must count what arrives, not what it expands to.
          request["Accept-Encoding"] = "identity"
          request["User-Agent"] = "studio-engine knowledge recording fetch"
          http.request(request) do |response|
            status = response.code.to_i
            if REDIRECT_STATUSES.include?(status) && !response["location"].to_s.empty?
              throw :answered, response["location"].to_s
            end
            raise FetchFailed, "#{redact(uri.to_s)} answered #{status}" unless status == 200

            declared = check_headers!(response, uri, max_bytes)
            # The headers are in: from here the clock is the whole fetch's.
            meter.delivered!
            meter.stop_at = stop_at
            store(response, sink, max_bytes, meter, uri, declared)
            throw :answered, :stored
          end
          raise FetchFailed, "#{redact(uri.to_s)} gave no response"
        end
      rescue Unreachable, Error
        raise
      rescue Meter::Expired
        raise FetchFailed, "#{redact(uri.to_s)} did not finish in time (#{HEADER_DEADLINE} seconds for a " \
                           "response's headers, #{FETCH_DEADLINE} for the whole fetch)"
      rescue Meter::Overrun
        raise FetchFailed, "#{redact(uri.to_s)} sent more than #{MAX_UNDELIVERED_BYTES} bytes of headers or framing"
      rescue Net::ReadTimeout, Net::WriteTimeout, Net::OpenTimeout, Net::ProtocolError, Net::HTTPBadResponse,
             Net::HTTPHeaderSyntaxError, EOFError, IOError, SystemCallError, SocketError, Timeout::Error,
             OpenSSL::SSL::SSLError => error
        detail = error.message.to_s[0, 160].gsub(/[^[:print:]]/, "?")
        raise FetchFailed, "#{redact(uri.to_s)} failed mid-fetch: #{error.class}: #{detail}"
      ensure
        hang_up(http)
      end

      def hang_up(http)
        http.finish if http&.started?
      rescue IOError, SystemCallError
        nil
      end

      # Answers the declared Content-Length (an Integer), or nil when the body
      # is chunked or declares none.
      def check_headers!(response, uri, max_bytes)
        encoding = response["content-encoding"].to_s.strip.downcase
        unless encoding.empty? || encoding == "identity"
          raise Refused, "#{redact(uri.to_s)} answered with Content-Encoding #{encoding[0, 32].inspect}; only identity is read"
        end

        declared = response["content-type"].to_s.split(";").first.to_s.strip.downcase
        unless declared.empty? || declared.start_with?("video/", "audio/") || GENERIC_CONTENT_TYPES.include?(declared)
          raise NotARecording, "#{redact(uri.to_s)} answered #{declared[0, 64].inspect}, not audio or video"
        end

        return nil if response.chunked?

        length = response["content-length"]
        return nil if length.nil?
        # Two Content-Length headers arrive joined by a comma; that, a sign or
        # a blank is a response this fetch cannot measure, so it is refused.
        raise Refused, "#{redact(uri.to_s)} sent a Content-Length that is not a number" unless length.match?(/\A\d{1,20}\z/)
        raise TooLarge, "#{redact(uri.to_s)} declares #{length} bytes, over the #{max_bytes}-byte cap" if length.to_i > max_bytes

        length.to_i
      end

      # Streams the body to `sink`. Each chunk is counted BEFORE it is written,
      # so the file on disk never passes max_bytes; the first HEAD_BYTES are
      # judged as soon as they arrive, so a page of HTML sent as octet-stream
      # stops at its first chunk; and each chunk tells the meter that what came
      # off the socket became body. When a length was declared, the body must
      # be exactly that long: Net::HTTP itself reports no error for a body that
      # ends early.
      def store(response, sink, max_bytes, meter, uri, declared)
        written = 0
        head = +"".b
        judged = false
        response.read_body do |chunk|
          meter.delivered!
          written += chunk.bytesize
          raise TooLarge, "#{redact(uri.to_s)} sent more than the #{max_bytes}-byte cap" if written > max_bytes

          unless judged
            head << chunk.byteslice(0, HEAD_BYTES - head.bytesize)
            if head.bytesize >= HEAD_BYTES
              judged = true
              container_of(head) || raise(NotARecording, "#{redact(uri.to_s)} did not send a recording")
            end
          end
          sink.write(chunk)
        end
        if declared && written != declared
          raise FetchFailed, "#{redact(uri.to_s)} sent #{written} bytes of #{declared} declared; the download was cut short"
        end
        raise NotARecording, "#{redact(uri.to_s)} sent #{written} bytes, too few to be a recording" unless judged
      end
    end

    # Sits between Net::HTTP's read buffer and the socket of ONE connection,
    # and bounds what Net::HTTP itself does not: how long the connection may
    # be read at all, and how many bytes may come off it without becoming body.
    #
    # WHY IT EXISTS. Net::HTTP reads the status line, headers, 1xx responses,
    # chunk-size lines and trailers itself, into memory, with no size limit and
    # only a per-read timeout. A server that sends header lines forever, one
    # endless line, an endless chunk-size line, a header every half second or
    # `100 Continue` forever was never stopped by a deadline or a byte cap
    # that only the body's chunks could see (review round 1, measured at
    # gigabytes of memory in seconds).
    #
    # HOW. Net::BufferedIO calls four things on its io: read_nonblock, to_io
    # (to wait on), write_nonblock and close. This wraps the io it was given
    # and overrides the first two:
    #   read_nonblock  refuses once the deadline has passed, and counts the
    #                  bytes read since `delivered!` was last called; past
    #                  MAX_UNDELIVERED_BYTES it raises Overrun. `fetch` calls
    #                  delivered! as each piece of body is handed to it.
    #   to_io          answers a waiter whose waits are cut to the time left,
    #                  so a silent socket is given up at the deadline, not a
    #                  read timeout later.
    # No thread is interrupted and nothing is raised asynchronously: every
    # stop is an ordinary exception raised in the reading thread, between
    # reads.
    #
    # It reaches into Net::HTTP for the buffer (the @socket and @io instance
    # variables; net-http offers no hook). `install!` REFUSES THE FETCH when
    # either is not what it expects, so a net-http this was not written for
    # cannot run unmetered. Written against net-http 0.9.1 and net-protocol
    # 0.2.2; the suite runs real Net::HTTP through it.
    class Meter < SimpleDelegator
      class Overrun < StandardError; end
      class Expired < StandardError; end

      Waiter = Struct.new(:io, :meter) do
        def wait_readable(timeout = nil) = meter.wait(io, :wait_readable, timeout)
        def wait_writable(timeout = nil) = meter.wait(io, :wait_writable, timeout)
        def inspect = "#<metered socket>"
      end

      attr_writer :stop_at

      def self.install!(http, stop_at)
        buffered = http.instance_variable_get(:@socket)
        raw = buffered.instance_variable_get(:@io) if buffered.is_a?(Net::BufferedIO)
        unless raw.respond_to?(:read_nonblock) && raw.respond_to?(:to_io)
          raise FetchFailed, "this net-http cannot be metered, so the fetch was not made (Studio::KnowledgeRecording::Meter)"
        end

        meter = new(raw, stop_at)
        buffered.instance_variable_set(:@io, meter)
        meter
      end

      def initialize(io, stop_at)
        super(io)
        @stop_at = stop_at
        @undelivered = 0
      end

      # What has come off the socket so far has been handed on as body.
      def delivered!
        @undelivered = 0
      end

      def read_nonblock(length, buffer = nil, exception: true)
        time_left(nil)
        result = __getobj__.read_nonblock(length, buffer, exception: exception)
        if result.is_a?(String)
          @undelivered += result.bytesize
          raise Overrun, "more than #{MAX_UNDELIVERED_BYTES} bytes" if @undelivered > MAX_UNDELIVERED_BYTES
        end
        result
      end

      def to_io
        Waiter.new(__getobj__.to_io, self)
      end

      # One wait on the socket, cut to the time left. A wait that ran out
      # because it was CUT is the deadline (Expired); one that ran out on its
      # own is the caller's read timeout (nil, as IO#wait_readable answers).
      def wait(io, direction, timeout)
        allowed = time_left(timeout)
        ready = io.public_send(direction, allowed)
        raise Expired, "deadline passed" if ready.nil? && (timeout.nil? || allowed < timeout)

        ready
      end

      # `timeout` cut to the seconds left before the deadline. Raises Expired
      # when none are left.
      def time_left(timeout)
        remaining = @stop_at - KnowledgeRecording.monotonic
        raise Expired, "deadline passed" if remaining <= 0

        timeout.nil? ? remaining : [timeout, remaining].min
      end
    end
  end
end
