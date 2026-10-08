# frozen_string_literal: true

module Studio
  module KnowledgePreview
    # A byte filter between the inflater and the XML parser.
    #
    # The reader's other bounds (inflate budget, deadline, parsed-text budget)
    # all sit in Ruby, BETWEEN XML nodes. The parser, libxml, does its own
    # allocating INSIDE one read, before any node comes out, and for some
    # input it spends fifteen to forty times the bytes it was given: a
    # megabyte of ATTLIST or ENTITY declarations, a start tag with a million
    # attributes, or sixty start tags of a megabyte each left open inside one
    # another, costs it a gigabyte or more that no Ruby-side bound ever sees.
    # So this sits BELOW the parser and never hands it such input.
    #
    # It is a tokenizer of the least XML that needs telling apart, and no
    # more: text, a tag (with its quoted attribute values), and the three
    # constructs that may hold "<" freely (comment, CDATA section, processing
    # instruction). On that it enforces:
    #
    #   1. UTF-8 markup from the first byte. The part must open with "<", or
    #      a UTF-8 byte-order mark and then "<", and hold no NUL byte. With
    #      the parser told the bytes are UTF-8 (Xlsx#each_node passes the
    #      encoding, which makes libxml ignore any encoding the part declares
    #      for itself), the bytes scanned here are the characters parsed
    #      there, so a UTF-16 part cannot hide from the scan.
    #   2. No document type declaration. A DTD is where ATTLIST and ENTITY
    #      live; no workbook has one, and libxml has no option to forbid it.
    #      The match is exact-case because libxml's is: "<!doctype" is a
    #      syntax error there, not a DTD.
    #   3. MAX_TOKEN_BYTES for a text node or a CDATA section, which is where
    #      a cell's text lives, and MAX_ASIDE_BYTES for ALL the comments and
    #      processing instructions in a part together: no workbook needs
    #      them at any length, and the parser keeps each one it meets under
    #      an open element until that element ends.
    #   4. MAX_OPEN_TAG_BYTES for start tags, counted across every element
    #      that is OPEN at once, the one being read included. The parser keeps
    #      an open element's attributes alive until its end tag, so bounding
    #      each tag alone still lets nesting multiply it; this bounds what is
    #      alive. A workbook's elements nest eight deep in tags of a hundred
    #      bytes.
    #   5. MAX_DEPTH open elements and MAX_NAMESPACE_DECLARATIONS in a part.
    #      The parser interns every namespace prefix for the life of the
    #      parse, so small tags each declaring a new one grow it without any
    #      single token being large.
    #
    # It answers IO#read for the parser. A refusal ends the stream (the parser
    # is handed nothing of the chunk that crossed the line) and is kept as
    # `failure`, because an exception raised inside the parser's read callback
    # does not reliably come out as itself; the caller raises it afterwards.
    class XmlGuard
      # Excel's longest cell is 32,767 characters. At four UTF-8 bytes each
      # that is 131 KB, and written as numeric character references about
      # 330 KB, so a megabyte is three times the longest text a real part
      # holds.
      MAX_TOKEN_BYTES = 1_048_576
      # Comments and processing instructions, summed over the part. Workbook
      # writers emit the XML declaration and nothing else of the kind. The
      # parser keeps the ones under an open element alive, so a cap on each
      # would still let a thousand small ones add up.
      MAX_ASIDE_BYTES = 65_536
      # The start tags a workbook writer produces are tens to hundreds of
      # bytes; the root's namespace declarations make the longest, a kilobyte
      # or two. This allows thirty times that, summed over open elements.
      MAX_OPEN_TAG_BYTES = 65_536
      # libxml's own nesting limit; the stack here never outgrows it.
      MAX_DEPTH = 256
      # A real part declares its namespaces once, on the root: a few dozen.
      MAX_NAMESPACE_DECLARATIONS = 1_024
      # The parser may ask for any amount; it is given at most this much at a
      # time, so nothing reaches it more than one chunk ahead of the scan.
      CHUNK_BYTES = 16_384

      BOM = "\xEF\xBB\xBF".b
      NUL = "\x00".b
      OPEN = "<".b
      DOCTYPE = "<!DOCTYPE".b
      NAMESPACE = "xmlns".b
      # opener => [terminator, which limit], for the constructs that may
      # contain "<".
      OPAQUE = { "<!--".b => ["-->".b, :aside], "<![CDATA[".b => ["]]>".b, :token], "<?".b => ["?>".b, :aside] }.freeze
      # The longest opener; a "<" this close to the end of what has arrived
      # waits for the next chunk before it is classified.
      LOOKAHEAD = 9
      TAG_STOP = /["'>]/n
      SLASH = 47
      CLOSE = 62
      BANG = 33
      QUERY = 63
      EMPTY = "".b.freeze

      attr_reader :failure

      def initialize(io, max_token_bytes: MAX_TOKEN_BYTES, max_aside_bytes: MAX_ASIDE_BYTES,
                     max_open_tag_bytes: MAX_OPEN_TAG_BYTES,
                     max_namespace_declarations: MAX_NAMESPACE_DECLARATIONS, chunk_bytes: CHUNK_BYTES)
        @io = io
        @max_token = max_token_bytes
        @max_aside = max_aside_bytes
        @limit = max_token_bytes # the limit the current token is held to
        @aside = false           # the current token is a comment or instruction
        @aside_bytes = 0         # comments and instructions seen so far, in all
        @max_open = max_open_tag_bytes
        @max_namespaces = max_namespace_declarations
        @chunk_bytes = chunk_bytes
        @opened = false
        @pending = +"".b   # read from the source, not yet handed to the parser
        @carry = +"".b     # handed over already, not yet classified by the scan
        @state = :text     # :text, :tag or :opaque
        @token = 0         # bytes of the current text or opaque token
        @terminator = nil  # what ends the current opaque token
        @tag = 0           # bytes of the tag being read
        @quote = nil       # the quote character an attribute value is inside
        @closing = false   # the tag being read is an end tag
        @last = nil        # the last byte of the tag read so far
        @open = []         # the size of each open element's start tag
        @open_bytes = 0
        @namespaces = 0
        @namespace_tail = EMPTY
      end

      def read(length = nil, _outbuf = nil)
        return nil if @failure

        open_part unless @opened
        return nil if @failure

        chunk = @pending.empty? ? @io.read(wanted(length)) : @pending.slice!(0, wanted(length))
        return nil if chunk.nil? || chunk.empty?

        chunk = chunk.b
        scan(chunk)
        @failure ? nil : chunk
      end

      private

      def wanted(length)
        length.nil? ? @chunk_bytes : [length, @chunk_bytes].min
      end

      def refuse(error)
        @failure = error
        @pending = +"".b
        nil
      end

      def too_large
        refuse(TooLarge.new("its XML holds more in one place than a preview reads"))
      end

      # Gathers the first four bytes before anything is handed over: a byte
      # order mark is three, and what follows it decides.
      def open_part
        @opened = true
        while @pending.bytesize < 4
          more = @io.read(@chunk_bytes)
          break if more.nil? || more.empty?

          @pending << more.b
        end
        start = @pending.start_with?(BOM) ? @pending.byteslice(3, 1) : @pending.byteslice(0, 1)
        refuse(Unreadable.new("its XML is not UTF-8")) unless start == OPEN || @pending.empty?
      end

      def scan(chunk)
        return refuse(Unreadable.new("its XML is not UTF-8")) if chunk.include?(NUL)

        data = @carry + chunk
        position = 0
        while position < data.bytesize
          position =
            case @state
            when :text then text(data, position)
            when :tag then tag(data, position)
            else opaque(data, position)
            end
          return if @failure || position.nil?
        end
        @carry = +"".b
      end

      # --- text ---------------------------------------------------------------------

      def text(data, position)
        found = data.index(OPEN, position)
        if found.nil?
          grow(data.bytesize - position)
          return data.bytesize
        end

        grow(found - position)
        return nil if @failure

        # By far the commonest case, so it is decided on one byte and
        # allocates nothing: a "<" not followed by "!" or "?" is a tag.
        following = data.getbyte(found + 1)
        return hold(data, found) if following.nil?
        return start_tag(found, following) unless following == BANG || following == QUERY
        # Not enough bytes yet to tell "<!--" from "<!DOCTYPE" from "<![CDATA[".
        return hold(data, found) if data.bytesize - found < LOOKAHEAD

        if data.byteslice(found, DOCTYPE.bytesize) == DOCTYPE
          return refuse(Unreadable.new("it carries a document type declaration, which no workbook has"))
        end

        opener, (terminator, kind) = OPAQUE.find { |open, _| data.byteslice(found, open.bytesize) == open }
        # "<!" followed by anything else is not XML the parser will accept;
        # it is passed on as a tag for the parser to refuse.
        return start_tag(found, following) unless opener

        @token = 0
        @state = :opaque
        @terminator = terminator
        @aside = kind == :aside
        # An aside starts where the last one stopped: its limit is a total.
        @token = @aside_bytes if @aside
        @limit = @aside ? @max_aside : @max_token
        grow(opener.bytesize)
        @failure ? nil : found + opener.bytesize
      end

      def start_tag(found, following)
        @token = 0
        @state = :tag
        @tag = 0
        @quote = nil
        @namespace_tail = EMPTY
        @closing = following == SLASH
        @last = nil
        spend_tag(1)
        @failure ? nil : found + 1
      end

      def grow(bytes)
        @token += bytes
        too_large if @token > @limit
      end

      # --- tags ---------------------------------------------------------------------

      # Reads to the end of a quoted value, or to the next quote or the ">"
      # that ends the tag. A ">" inside a quoted value is only a character.
      def tag(data, position)
        if @quote
          found = data.index(@quote, position)
          return leave_tag(data, position, data.bytesize) if found.nil?

          @quote = nil
          return leave_tag(data, position, found + 1)
        end

        found = data.index(TAG_STOP, position)
        finish = found || data.bytesize
        # A stretch too short to hold "xmlns" (most of them: "<c r=", "<t>")
        # is not looked at, unless an earlier stretch left a tail to join.
        if finish - position >= NAMESPACE.bytesize || !@namespace_tail.empty? || found.nil?
          count_namespaces(data.byteslice(position, finish - position), continues: found.nil?)
          return nil if @failure
        end
        return leave_tag(data, position, data.bytesize) if found.nil?

        if data.getbyte(found) == CLOSE
          before = found > position ? data.getbyte(found - 1) : @last
          after = leave_tag(data, position, found + 1)
          return nil if @failure

          end_tag(before == SLASH)
          return @failure ? nil : after
        end

        @quote = data.byteslice(found, 1)
        leave_tag(data, position, found + 1)
      end

      def leave_tag(data, from, to)
        spend_tag(to - from)
        return nil if @failure

        @last = data.getbyte(to - 1) if to > from
        to
      end

      # The tag being read counts against the open-tag budget as it grows, so
      # a tag that would overspend it is refused before the parser has it all.
      def spend_tag(bytes)
        @tag += bytes
        too_large if @open_bytes + @tag > @max_open
      end

      # Counts "xmlns" in a stretch of a tag that is outside any quoted
      # value. When the stretch runs to the end of what has arrived, its last
      # four bytes are kept, so a declaration split across chunks is counted.
      def count_namespaces(segment, continues:)
        text = @namespace_tail + segment.to_s
        @namespaces += text.scan(NAMESPACE).size
        @namespace_tail = continues ? (text.byteslice(-(NAMESPACE.bytesize - 1)..) || text) : EMPTY
        too_large if @namespaces > @max_namespaces
      end

      def end_tag(self_closing)
        if @closing
          @open_bytes -= @open.pop || 0
        elsif !self_closing
          @open << @tag
          @open_bytes += @tag
          too_large if @open.size > MAX_DEPTH
        end
        @state = :text
        @token = 0
      end

      # --- comments, CDATA sections, processing instructions ------------------------

      def opaque(data, position)
        found = data.index(@terminator, position)
        if found.nil?
          # The terminator may be split across chunks: its last bytes wait.
          keep = [@terminator.bytesize - 1, data.bytesize - position].min
          grow(data.bytesize - position - keep)
          return @failure ? nil : hold(data, data.bytesize - keep)
        end

        grow(found + @terminator.bytesize - position)
        return nil if @failure

        @aside_bytes = @token if @aside
        @aside = false
        @state = :text
        @limit = @max_token
        @token = 0
        found + @terminator.bytesize
      end

      # Leaves the tail of `data` for the next chunk to finish, and stops the
      # scan. Those bytes were handed to the parser already; a few bytes of an
      # unfinished opener are nothing it can act on.
      def hold(data, from)
        @carry = data.byteslice(from, data.bytesize - from) || +"".b
        nil
      end
    end
  end
end
