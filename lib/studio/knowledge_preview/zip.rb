# frozen_string_literal: true

require "zlib"
require "stringio"

module Studio
  module KnowledgePreview
    # The least of a zip reader an .xlsx needs: the central directory, and each
    # entry as a STREAM that inflates on demand.
    #
    # Written on Zlib (stdlib) rather than on rubyzip for two reasons. The
    # consumers lock different rubyzip majors (2.4 and 3.x), and none of them
    # carries it outside the test group, so a gemspec dependency would put a
    # new runtime gem in every app for one admin page. And a streaming reader
    # is the control a preview wants: an entry is inflated only as far as the
    # caller reads it, and never past `inflate_cap`, so a small file that
    # declares a huge sheet (or lies about its sizes) costs what was read, not
    # what it claims.
    #
    # Deliberately unsupported, each refused with Unreadable so the page falls
    # back to the download link: zip64, encrypted entries, and any compression
    # other than stored (0) and deflate (8). Sizes and offsets come from the
    # central directory, so entries written with a trailing data descriptor
    # read correctly.
    class Zip
      EOCD_SIGNATURE    = "PK\x05\x06".b
      CENTRAL_SIGNATURE = "PK\x01\x02".b
      LOCAL_SIGNATURE   = "PK\x03\x04".b
      EOCD_MIN_SIZE     = 22
      # An end-of-central-directory record may be followed by a comment of up
      # to 65,535 bytes; it is never further from the end than this.
      EOCD_SEARCH_WINDOW = EOCD_MIN_SIZE + 0xFFFF
      MAX_ENTRIES = 5_000
      ZIP64_MARKER = 0xFFFFFFFF

      Entry = Struct.new(:name, :flags, :compression, :compressed_size, :local_offset)

      # Reads a deflate stream a few kilobytes of compressed input at a time.
      # The small step is the bomb defence: deflate tops out near 1000:1, so
      # one step can add about four megabytes to the buffer and no more.
      class InflateIO
        STEP = 4096

        def initialize(compressed, cap)
          @compressed = compressed
          @position = 0
          @cap = cap
          @produced = 0
          @buffer = +"".b
          @inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
          @finished = false
        end

        # IO#read's contract as Nokogiri's reader uses it: up to `length`
        # bytes, and nil once the stream is exhausted.
        def read(length = nil, _outbuf = nil)
          fill while !@finished && (length.nil? || @buffer.bytesize < length)
          return nil if @buffer.empty? && !length.nil?

          length.nil? ? @buffer.slice!(0, @buffer.bytesize) : @buffer.slice!(0, length)
        end

        def close
          @inflater.close unless @inflater.closed?
        end

        private

        def fill
          chunk = @compressed.byteslice(@position, STEP)
          if chunk.nil? || chunk.empty?
            @finished = true
            return
          end

          @position += chunk.bytesize
          out = @inflater.inflate(chunk)
          @produced += out.bytesize
          raise TooLarge, "it expands past the #{@cap / 1_048_576} MB preview limit" if @produced > @cap

          @buffer << out
          @finished = true if @inflater.finished?
        end
      end

      def initialize(bytes, inflate_cap:)
        @bytes = bytes.b
        @inflate_cap = inflate_cap
        @entries = read_central_directory
      end

      def names
        @entries.keys
      end

      def entry?(name)
        @entries.key?(normalize(name))
      end

      # Yields an IO over the entry's uncompressed bytes, or returns nil when
      # the archive has no such entry.
      def open(name)
        entry = @entries[normalize(name)]
        return nil unless entry

        io = io_for(entry)
        begin
          yield io
        ensure
          io.close
        end
      end

      private

      def normalize(name)
        name.to_s.delete_prefix("/")
      end

      def read_central_directory
        window_start = [@bytes.bytesize - EOCD_SEARCH_WINDOW, 0].max
        eocd = @bytes.rindex(EOCD_SIGNATURE)
        raise Unreadable, "it is not a zip archive" if eocd.nil? || eocd < window_start
        raise Unreadable, "its zip directory is cut short" if eocd + EOCD_MIN_SIZE > @bytes.bytesize

        count, _size, offset = @bytes.byteslice(eocd + 10, 10).unpack("vVV")
        raise Unreadable, "it is a zip64 archive" if offset == ZIP64_MARKER || count == 0xFFFF
        raise Unreadable, "it holds too many zip entries" if count > MAX_ENTRIES

        entries = {}
        position = offset
        count.times do
          header = @bytes.byteslice(position, 46)
          unless header && header.bytesize == 46 && header.start_with?(CENTRAL_SIGNATURE)
            raise Unreadable, "its zip directory is damaged"
          end

          flags, compression = header.byteslice(8, 4).unpack("vv")
          compressed_size = header.byteslice(20, 4).unpack1("V")
          name_length, extra_length, comment_length = header.byteslice(28, 6).unpack("vvv")
          local_offset = header.byteslice(42, 4).unpack1("V")
          name = @bytes.byteslice(position + 46, name_length).to_s.force_encoding(Encoding::UTF_8)
          raise Unreadable, "it is a zip64 archive" if [compressed_size, local_offset].include?(ZIP64_MARKER)

          entries[normalize(name)] = Entry.new(name, flags, compression, compressed_size, local_offset)
          position += 46 + name_length + extra_length + comment_length
        end
        entries
      end

      def io_for(entry)
        raise Unreadable, "it is password-protected" if entry.flags.anybits?(1)

        local = @bytes.byteslice(entry.local_offset, 30)
        unless local && local.bytesize == 30 && local.start_with?(LOCAL_SIGNATURE)
          raise Unreadable, "its zip entries are damaged"
        end

        name_length, extra_length = local.byteslice(26, 4).unpack("vv")
        data = @bytes.byteslice(entry.local_offset + 30 + name_length + extra_length, entry.compressed_size)
        raise Unreadable, "its zip entries are cut short" if data.nil? || data.bytesize < entry.compressed_size

        case entry.compression
        when 0
          raise TooLarge, "it expands past the #{@inflate_cap / 1_048_576} MB preview limit" if data.bytesize > @inflate_cap

          StringIO.new(data)
        when 8 then InflateIO.new(data, @inflate_cap)
        else raise Unreadable, "it uses a zip compression this preview cannot read"
        end
      end
    end
  end
end
