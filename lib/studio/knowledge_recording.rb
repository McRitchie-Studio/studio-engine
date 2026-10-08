# frozen_string_literal: true

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
  # THE BOUNDS, each a constant below:
  #   MAX_BYTES           4 GB a recording, local or fetched
  #   MAX_URL_BYTES       8,192 bytes a URL, the first one and every redirect
  #   MAX_REDIRECTS       3
  #   MAX_ADDRESSES       4 vetted addresses tried for one host
  #   FETCH_DEADLINE      3,600 s for a whole fetch, redirects included
  #   connect / read      Studio::ImageCache::OPEN_TIMEOUT (10 s) and
  #                       READ_TIMEOUT (30 s), set by its pinned_http
  #   HEAD_BYTES          16 bytes read to identify a file
  #   MAX_FILENAME_CHARS  80 characters of a file name kept in the object key
  module KnowledgeRecording
    class Error < StandardError; end
    # The source was refused before, or instead of, being stored.
    class Refused < Error; end
    class NotARecording < Refused; end
    class TooLarge < Refused; end
    class FetchFailed < Error; end

    # 4 GB. Recordings run 100 MB to 1 GB; this leaves room for a long
    # meeting in high definition and still fits a dyno's ephemeral disk.
    MAX_BYTES = 4 * 1024 * 1024 * 1024
    # Long enough for a presigned download URL, short enough that a redirect
    # cannot hand us a megabyte of Location header to parse.
    MAX_URL_BYTES = 8_192
    MAX_REDIRECTS = 3
    MAX_ADDRESSES = 4
    # One hour for the whole fetch. The read timeout bounds one silent gap; a
    # server that sends a byte every 29 seconds would otherwise hold the dyno
    # until the byte cap, which at that rate is never.
    FETCH_DEADLINE = 3_600
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
      # `filename` is the name whose extension is judged (default: the path's).
      # `strict_extension: false` is for a fetched URL, whose path is the
      # server's to name: an extension off the list is then ignored instead of
      # refused. One that names a DIFFERENT container is refused either way.
      def identify!(path, filename: nil, strict_extension: true, max_bytes: MAX_BYTES)
        path = path.to_s
        raise Refused, "no such file: #{path}" unless File.file?(path)

        head, size = File.open(path, "rb") { |file| [file.read(HEAD_BYTES), file.size] }
        raise NotARecording, "#{File.basename(path)} is empty" if size.zero?
        raise TooLarge, "#{File.basename(path)} is #{size} bytes, over the #{max_bytes}-byte cap" if size > max_bytes

        container = container_of(head) ||
          raise(NotARecording, "#{File.basename(path)} is not a recording: its first bytes are not MP4, MOV, M4A, " \
                               "WebM, MP3, WAV or Ogg")
        extension = extension_for(container, head, filename || path, strict_extension)
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

      # `url` as it may be printed or logged: scheme, host and path. The query
      # is dropped because a download URL usually carries its credential there.
      def redact(url)
        require "uri"
        uri = URI.parse(url.to_s)
        return "(a URL with no host)" if uri.host.to_s.empty?

        "#{uri.scheme}://#{uri.host}#{uri.path.to_s[0, 200]}#{'?…' if uri.query}"
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

      # Downloads `url` to a temporary file and yields its path and a file
      # name taken from the final URL. The file is deleted when the block
      # returns or raises.
      #
      # THIS IS A SERVER-SIDE FETCH OF A CALLER-SUPPLIED URL, run with the
      # bucket's credentials in the process. Every hop, the first and each
      # redirect, goes through Studio::ImageCache.vet_source_url! (the engine's
      # one SSRF guard: public addresses only, however the host is written and
      # wherever its name resolves), must be https, may carry no user:password,
      # and is connected to an address that hop was vetted against
      # (ImageCache.pinned_http), so the name cannot resolve somewhere else
      # between the check and the connection. A host that vets to NO address
      # (no resolver) is refused rather than connected to by name.
      #
      # `resolver:` is the callable names resolve with. The default is the
      # guard's own, or the system resolver where the guard's default is none
      # (a Rails test environment): this fetch never runs unresolved.
      def fetch(url, max_bytes: MAX_BYTES, resolver: default_resolver, deadline: FETCH_DEADLINE)
        require "tempfile"
        stop_at = monotonic + deadline
        current = url.to_s
        hop = nil

        Tempfile.create(["studio-knowledge-recording", ".part"]) do |sink|
          sink.binmode
          # Bounded: MAX_REDIRECTS + 1 requests at most.
          (MAX_REDIRECTS + 1).times do
            vetted = vet!(current, resolver)
            hop = request(vetted, sink, max_bytes, stop_at)
            break unless hop.is_a?(String)

            current = join_location(vetted.uri, hop)
          end
          raise FetchFailed, "too many redirects (more than #{MAX_REDIRECTS}) from #{redact(url)}" if hop.is_a?(String)

          sink.flush
          return yield(sink.path, File.basename(URI.parse(current).path.to_s))
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

      private

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def extension_for(container, head, name, strict)
        allowed = CONTAINERS.fetch(container)
        given = File.extname(name.to_s).delete_prefix(".").downcase
        return default_extension(container, head) if given.empty?
        return given if allowed.include?(given)

        if TYPES.key?(given) || strict
          raise NotARecording, "the name ends in .#{given[0, 16]} but the bytes are #{container} " \
                               "(expected one of: #{allowed.map { |ext| ".#{ext}" }.join(', ')})"
        end

        default_extension(container, head)
      end

      def default_extension(container, head)
        return CONTAINERS.fetch(container).first unless container == :isobmff

        ISOBMFF_BRANDS.fetch(head.to_s.b.byteslice(8, 4).to_s, "mp4")
      end

      # One hop through the guard, plus what this fetch adds to it: https
      # only, no credentials in the URL, a length cap, and at least one vetted
      # address to pin the connection to.
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
      def request(vetted, sink, max_bytes, stop_at)
        require "net/http"
        unreachable = [Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EADDRNOTAVAIL,
                       Net::OpenTimeout, SocketError]
        candidates = vetted.addresses.first(MAX_ADDRESSES)

        candidates.each_with_index do |address, index|
          sink.rewind
          sink.truncate(0)
          return get(vetted.uri, address, sink, max_bytes, stop_at)
        rescue *unreachable => error
          next unless index == candidates.size - 1

          raise FetchFailed, "could not connect to #{vetted.host}: #{error.class}"
        end
      end

      # THE RESPONSE BODY IS NEVER READ UNBOUNDED. Net::HTTP drains whatever a
      # block leaves unread, into memory, when the block returns; so a redirect
      # or an error is left by `throw`, which unwinds past the drain and closes
      # the socket with the body unread.
      def get(uri, address, sink, max_bytes, stop_at)
        catch(:answered) do
          connection(uri, address).start do |http|
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

              check_headers!(response, uri, max_bytes)
              store(response, sink, max_bytes, stop_at, uri)
              throw :answered, :stored
            end
          end
        end
      end

      def check_headers!(response, uri, max_bytes)
        encoding = response["content-encoding"].to_s.strip.downcase
        unless encoding.empty? || encoding == "identity"
          raise Refused, "#{redact(uri.to_s)} answered with Content-Encoding #{encoding[0, 32].inspect}; only identity is read"
        end

        declared = response["content-type"].to_s.split(";").first.to_s.strip.downcase
        unless declared.empty? || declared.start_with?("video/", "audio/") || GENERIC_CONTENT_TYPES.include?(declared)
          raise NotARecording, "#{redact(uri.to_s)} answered #{declared[0, 64].inspect}, not audio or video"
        end

        length = response["content-length"].to_s
        return unless length.match?(/\A\d{1,20}\z/) && length.to_i > max_bytes

        raise TooLarge, "#{redact(uri.to_s)} declares #{length} bytes, over the #{max_bytes}-byte cap"
      end

      # Streams the body to `sink`. Each chunk is counted BEFORE it is written,
      # so the file on disk never passes max_bytes; the first HEAD_BYTES are
      # judged as soon as they arrive, so a page of HTML sent as octet-stream
      # stops at its first chunk; and the clock is read on every chunk.
      def store(response, sink, max_bytes, stop_at, uri)
        written = 0
        head = +"".b
        judged = false
        response.read_body do |chunk|
          written += chunk.bytesize
          raise TooLarge, "#{redact(uri.to_s)} sent more than the #{max_bytes}-byte cap" if written > max_bytes
          raise FetchFailed, "#{redact(uri.to_s)} did not finish within #{FETCH_DEADLINE} seconds" if monotonic > stop_at

          unless judged
            head << chunk.byteslice(0, HEAD_BYTES - head.bytesize)
            if head.bytesize >= HEAD_BYTES
              judged = true
              container_of(head) || raise(NotARecording, "#{redact(uri.to_s)} did not send a recording")
            end
          end
          sink.write(chunk)
        end
        raise NotARecording, "#{redact(uri.to_s)} sent #{written} bytes, too few to be a recording" unless judged
      end
    end
  end
end
