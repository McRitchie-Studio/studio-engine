# frozen_string_literal: true

module Studio
  # Turns a meeting transcript's text into CUES: (seconds, speaker, text), in
  # the order they appear. The knowledge layer's player seeks to a cue's
  # seconds when its line is clicked.
  #
  # Loaded on first use (`require "studio/knowledge_transcript"`), not by
  # `require "studio"`.
  #
  # Two layouts are read, line by line, and may be mixed in one text:
  #
  #   A. the stamp, a dash, then the speaker; the text indented below
  #        0:02 - Jordan Example (Example Co)
  #          Good morning, everyone.
  #
  #   B. the speaker, a bullet, then the stamp; the text on the lines below
  #        Jordan Example • 0:02
  #        Good morning, everyone.
  #
  # A stamp is M:SS or H:MM:SS. Lines before the first cue (a title, a "VIEW
  # RECORDING" line, a rule) belong to no cue and are dropped. Text that is not
  # a transcript has no cue lines and answers no cues. Nothing here raises on
  # any String, whatever its bytes or encoding; a non-String answers no cues.
  #
  # A layout A cue line starts in the FIRST COLUMN. That is what keeps an
  # indented line of speech such as "  10:30 - we agreed to meet" text.
  #
  # THE BOUNDS, each a constant below. There is one loop, over the lines of at
  # most MAX_TEXT_BYTES of text, and every step in it is linear in the line:
  #   MAX_TEXT_BYTES      2 MB of text read; the rest is ignored
  #   MAX_CUES            5,000 cues; reading stops at the next one
  #   MAX_CUE_LINE_BYTES  512 bytes: a longer line is never a cue line, so no
  #                       pattern is ever run against a long line
  #   MAX_STAMP_BYTES     10 bytes: the longest stamp, "999:59:59" and one spare
  #   MAX_SPEAKER_CHARS   120 characters; a longer "speaker" is a line of text
  #   MAX_CUE_TEXT_BYTES  8 KB of text kept for one cue; the rest is dropped
  #
  # The one pattern, STAMP, is anchored at both ends, has no nested or
  # unbounded quantifier, and only ever sees a token of MAX_STAMP_BYTES or
  # fewer. Everything else is `strip`, `index`, `rindex` and `start_with?`.
  module KnowledgeTranscript
    MAX_TEXT_BYTES = 2 * 1024 * 1024
    MAX_CUES = 5_000
    MAX_CUE_LINE_BYTES = 512
    MAX_STAMP_BYTES = 10
    MAX_SPEAKER_CHARS = 120
    MAX_CUE_TEXT_BYTES = 8 * 1024

    STAMP = /\A(?:(\d{1,3}):)?(\d{1,3}):(\d{2})\z/
    # Layout A: what may stand between the stamp and the speaker.
    DASHES = ["- ", "– ", "— "].freeze
    # Layout B: what stands between the speaker and the stamp.
    BULLET = "•"

    Cue = Struct.new(:seconds, :speaker, :text)

    # `cues` is frozen. `truncated` is true when a bound cut the reading short
    # (text past MAX_TEXT_BYTES, cues past MAX_CUES, or a cue's text past
    # MAX_CUE_TEXT_BYTES), so a page can say the transcript is incomplete.
    Result = Struct.new(:cues, :truncated) do
      def truncated? = truncated
    end

    class << self
      # The cues in `text`, as an Array of Cue. Empty when there are none.
      def parse(text)
        read(text).cues
      end

      # The same reading, with whether a bound cut it short.
      def read(text)
        return Result.new([].freeze, false) unless text.is_a?(String)

        truncated = text.bytesize > MAX_TEXT_BYTES
        cues = []
        current = nil

        # Bounded: at most MAX_TEXT_BYTES of text, so at most that many lines.
        utf8(truncated ? text.byteslice(0, MAX_TEXT_BYTES) : text).each_line do |line|
          opening = cue_line(line)
          if opening
            if cues.size >= MAX_CUES
              truncated = true
              break
            end
            current = Cue.new(opening[0], opening[1], +"")
            cues << current
          elsif current
            truncated = true unless append(current.text, line)
          end
        end

        cues.each { |cue| cue.text.freeze }
        Result.new(cues.freeze, truncated)
      end

      # Seconds for "M:SS" or "H:MM:SS", or nil when `token` is not a stamp.
      def seconds_of(token)
        return nil if token.bytesize > MAX_STAMP_BYTES

        match = STAMP.match(token)
        return nil unless match

        hours, minutes, seconds = match[1], match[2].to_i, match[3].to_i
        return nil if seconds > 59
        return minutes * 60 + seconds if hours.nil?
        return nil if minutes > 59

        hours.to_i * 3600 + minutes * 60 + seconds
      end

      private

      # Valid UTF-8 whatever came in. Bytes with no encoding claim (binary,
      # ASCII) are read as UTF-8; another encoding is converted; whatever is
      # invalid either way becomes U+FFFD.
      def utf8(text)
        claimed = text.encoding
        if [Encoding::UTF_8, Encoding::BINARY, Encoding::US_ASCII].include?(claimed)
          return text.dup.force_encoding(Encoding::UTF_8).scrub("�")
        end

        text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�")
      rescue EncodingError
        text.dup.force_encoding(Encoding::UTF_8).scrub("�")
      end

      # [seconds, speaker] when `line` opens a cue, else nil.
      def cue_line(line)
        return nil if line.bytesize > MAX_CUE_LINE_BYTES

        layout_a(line) || layout_b(line)
      end

      # "0:02 - Jordan Example (Example Co)", starting in the first column.
      def layout_a(line)
        gap = line.index(" ")
        return nil if gap.nil? || gap.zero? || gap > MAX_STAMP_BYTES

        seconds = seconds_of(line[0, gap])
        return nil if seconds.nil?

        rest = line[gap..].lstrip
        return nil unless rest.start_with?(*DASHES)

        speaker = speaker_of(rest[2..])
        speaker && [seconds, speaker]
      end

      # "Jordan Example • 0:02": the LAST bullet, so a bullet in a name is kept.
      def layout_b(line)
        at = line.rindex(BULLET)
        return nil if at.nil?

        seconds = seconds_of(line[(at + 1)..].strip)
        return nil if seconds.nil?

        speaker = speaker_of(line[0, at])
        speaker && [seconds, speaker]
      end

      def speaker_of(text)
        speaker = text.strip
        speaker.empty? || speaker.size > MAX_SPEAKER_CHARS ? nil : speaker
      end

      # Adds one line of speech to a cue's text. Answers false when the cue's
      # text was already full or this line had to be cut to fit.
      def append(text, line)
        piece = line.strip
        return true if piece.empty?

        room = MAX_CUE_TEXT_BYTES - text.bytesize - (text.empty? ? 0 : 1)
        return false if room <= 0

        fits = piece.bytesize <= room
        piece = piece.byteslice(0, room).scrub("") unless fits
        text << "\n" unless text.empty?
        text << piece
        fits
      end
    end
  end
end
