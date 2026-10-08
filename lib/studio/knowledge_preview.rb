# frozen_string_literal: true

module Studio
  # What /admin/knowledge/:id shows of a document without a download: a
  # workbook or CSV as tables, a PDF or image inline, text as text.
  #
  # NOT required by lib/studio.rb. Studio::KnowledgeDoc requires it on first
  # use, and the spreadsheet reader (nokogiri, zlib) and `csv` load later
  # still, on the first file of that kind, so an app that never draws the
  # knowledge routes pays nothing for it.
  #
  # Everything here is read-only and answers with a Result, never an
  # exception: a file this cannot show, for any reason, is a Result of kind
  # :fallback carrying one plain sentence, and the page offers the download
  # link beside it.
  #
  # THE CAPS, all in one place:
  #
  #   SPREADSHEET_MAX_BYTES  an .xlsx larger than this is not opened at all.
  #   INFLATE_CAP            no single part of a workbook is inflated past this.
  #   MAX_ROWS, MAX_COLUMNS  what one sheet (or CSV) shows; the rest is named
  #                          in a notice, never silently dropped.
  #   MAX_SHEETS             tabs rendered; further sheets are counted.
  #   DELIMITED_HEAD_BYTES   a CSV is read only this far, so one of any size
  #                          previews its first rows.
  #   TEXT_HEAD_BYTES        likewise for text.
  #   INLINE_MAX_BYTES       a PDF or image past this is not embedded.
  module KnowledgePreview
    class Error < StandardError; end
    # The file is not what its name says, or is damaged. The message completes
    # "This file could not be previewed: ...".
    class Unreadable < Error; end
    class TooLarge < Error; end

    MEGABYTE = 1_048_576
    SPREADSHEET_MAX_BYTES = 20 * MEGABYTE
    INFLATE_CAP           = 64 * MEGABYTE
    MAX_ROWS              = 500
    MAX_COLUMNS           = 50
    MAX_SHEETS            = 20
    DELIMITED_HEAD_BYTES  = 1 * MEGABYTE
    TEXT_HEAD_BYTES       = 256 * 1024
    INLINE_MAX_BYTES      = 100 * MEGABYTE

    XLSX_MIME = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

    KIND_BY_EXTENSION = {
      ".xlsx" => :spreadsheet, ".xlsm" => :spreadsheet,
      ".csv" => :delimited, ".tsv" => :delimited,
      ".pdf" => :pdf,
      ".png" => :image, ".jpg" => :image, ".jpeg" => :image, ".gif" => :image, ".webp" => :image,
      ".txt" => :text, ".md" => :text, ".markdown" => :text, ".log" => :text,
      ".json" => :text, ".vtt" => :text, ".srt" => :text
    }.freeze

    KIND_BY_MIME = {
      XLSX_MIME => :spreadsheet,
      "text/csv" => :delimited, "text/tab-separated-values" => :delimited,
      "application/pdf" => :pdf,
      "image/png" => :image, "image/jpeg" => :image, "image/gif" => :image, "image/webp" => :image,
      "application/json" => :text
    }.freeze

    # The content type an inline object is SERVED as. Chosen here, from the
    # kind, and never copied from the stored mime type: a file uploaded as
    # text/html under a .pdf name must reach the browser as a (broken) PDF,
    # not as a page. SVG is absent on purpose; it is a document that can
    # carry script, and it takes the download link.
    INLINE_TYPE_BY_EXTENSION = {
      ".pdf" => "application/pdf",
      ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg",
      ".gif" => "image/gif", ".webp" => "image/webp"
    }.freeze

    Cell  = Struct.new(:text, :numeric)
    # rows is a rectangle of Cell-or-nil. row_limit is the row count the
    # truncation notice names.
    Sheet = Struct.new(:name, :rows, :truncated_rows, :truncated_columns, :hidden, :row_limit,
                       keyword_init: true)

    # kind: :table, :pdf, :image, :text or :fallback.
    # error: the unexpected exception behind a fallback, for the caller to
    # log; nil when the fallback is an ordinary refusal.
    Result = Struct.new(:kind, :sheets, :omitted_sheets, :text, :truncated, :url, :reason, :error,
                        keyword_init: true) do
      def fallback? = kind == :fallback
    end

    NUMERIC_TEXT = /\A\(?[-+$€£]?\s?\d[\d,]*(\.\d+)?%?\)?\z/

    class << self
      # :spreadsheet, :delimited, :pdf, :image, :text, or nil for a file with
      # no inline preview. The extension decides when it is one this knows;
      # the stored mime type is the browser's guess at upload and is consulted
      # only for a name that says nothing.
      def kind_for(filename:, mime_type: nil)
        extension = File.extname(filename.to_s).downcase
        return KIND_BY_EXTENSION[extension] if KIND_BY_EXTENSION.key?(extension)

        mime = mime_type.to_s.split(";").first.to_s.strip.downcase
        KIND_BY_MIME[mime] || (mime.start_with?("text/") ? :text : nil)
      end

      def inline_content_type(filename:, mime_type: nil)
        by_name = INLINE_TYPE_BY_EXTENSION[File.extname(filename.to_s).downcase]
        return by_name if by_name

        mime = mime_type.to_s.split(";").first.to_s.strip.downcase
        INLINE_TYPE_BY_EXTENSION.value?(mime) ? mime : nil
      end

      # The preview for a Studio::KnowledgeDoc. Reads the bucket (or, for a
      # PDF or image, only signs a URL), so call it off the page's own render
      # path. `storage` answers download(key:, max_bytes:).
      def for(doc, storage: Studio::S3)
        return fallback("No file is attached.") unless doc.file?

        kind = kind_for(filename: doc.filename, mime_type: doc.mime_type)
        case kind
        when :spreadsheet then spreadsheet(doc, storage)
        when :delimited   then delimited(doc, storage)
        when :text        then text(doc, storage)
        when :pdf, :image then inline(doc, kind)
        else fallback(no_preview_reason(doc))
        end
      rescue TooLarge => e
        fallback("This file is too large to preview: #{e.message}.")
      rescue Unreadable => e
        fallback("This file could not be previewed: #{e.message}.")
      rescue StandardError, LoadError => e
        # Storage down, an object missing, a defect in a reader, or a library
        # the host's bundle lacks. The page must still render; the caller logs
        # what happened.
        fallback("The preview could not be built.", error: e)
      end

      # --- readers, usable without a document ---------------------------------

      def read_spreadsheet(bytes)
        require_relative "knowledge_preview/xlsx"
        Xlsx.read(bytes, max_rows: MAX_ROWS, max_columns: MAX_COLUMNS, max_sheets: MAX_SHEETS,
                         inflate_cap: INFLATE_CAP)
      rescue Error
        raise
      rescue StandardError => e
        # A hostile or half-written workbook can trip the reader anywhere;
        # every such trip is the file's fault until shown otherwise.
        raise Unreadable, "its contents are damaged (#{e.class})"
      end

      # `partial` says the bytes are only the head of a longer file, so the
      # last line may be cut and is dropped.
      def read_delimited(bytes, separator: ",", partial: false)
        require "csv"
        text = decode(bytes, partial: partial)
        raise Unreadable, "it is empty" if text.strip.empty?

        text = text[0..text.rindex("\n")] if partial && text.include?("\n")
        rows = []
        truncated_rows = partial
        truncated_columns = false
        begin
          CSV.new(text, col_sep: separator, liberal_parsing: true).each do |row|
            if rows.size >= MAX_ROWS
              truncated_rows = true
              break
            end
            truncated_columns = true if row.size > MAX_COLUMNS
            rows << row.first(MAX_COLUMNS)
          end
        rescue CSV::MalformedCSVError
          # Rows read before the bad line still show; with none, it is not CSV.
          raise Unreadable, "it is not valid CSV" if rows.empty?

          truncated_rows = true
        end

        width = rows.map(&:size).max.to_i
        cells = rows.map do |row|
          Array.new(width) do |index|
            value = row[index].to_s
            value.empty? ? nil : Cell.new(value, value.match?(NUMERIC_TEXT))
          end
        end
        Sheet.new(name: nil, rows: cells, truncated_rows: truncated_rows,
                  truncated_columns: truncated_columns, hidden: false, row_limit: cells.size)
      end

      # Bytes to UTF-8 text. UTF-8 first; a UTF-16 byte-order mark is honoured;
      # anything else is read as Windows-1252, which is what a CSV exported by
      # desktop accounting software usually is. NUL bytes mean it is not text.
      def decode(bytes, partial: false)
        raw = bytes.to_s.b
        if raw.start_with?("\xFF\xFE".b, "\xFE\xFF".b)
          encoding = raw.start_with?("\xFF\xFE".b) ? Encoding::UTF_16LE : Encoding::UTF_16BE
          body = raw.byteslice(2..)
          body = body.byteslice(0, body.bytesize - 1) if body.bytesize.odd?
          return body.force_encoding(encoding).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        end
        raise Unreadable, "it does not look like text" if raw.include?("\x00".b)

        raw = raw.byteslice(3..) if raw.start_with?("\xEF\xBB\xBF".b)
        utf8 = raw.dup.force_encoding(Encoding::UTF_8)
        return utf8 if utf8.valid_encoding?

        if partial
          # A head read can end inside a multi-byte character.
          1.upto(3) do |trim|
            shorter = raw.byteslice(0, [raw.bytesize - trim, 0].max).force_encoding(Encoding::UTF_8)
            return shorter if shorter.valid_encoding?
          end
        end
        raw.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      end

      private

      def fallback(reason, error: nil)
        Result.new(kind: :fallback, reason: reason, error: error)
      end

      def no_preview_reason(doc)
        extension = File.extname(doc.filename.to_s).downcase
        extension.empty? ? "There is no inline preview for this kind of file." : "There is no inline preview for #{extension} files."
      end

      def megabytes(bytes)
        "#{(bytes.to_f / MEGABYTE).round(1).to_s.delete_suffix('.0')} MB"
      end

      def spreadsheet(doc, storage)
        refuse_over!(doc, SPREADSHEET_MAX_BYTES)
        # One byte past the cap: the recorded byte_size can be absent or
        # stale, and this is the read that cannot be.
        bytes = storage.download(key: doc.s3_key, max_bytes: SPREADSHEET_MAX_BYTES + 1)
        raise TooLarge, "spreadsheet previews stop at #{megabytes(SPREADSHEET_MAX_BYTES)}" if bytes.bytesize > SPREADSHEET_MAX_BYTES

        workbook = read_spreadsheet(bytes)
        Result.new(kind: :table, sheets: workbook.sheets, omitted_sheets: workbook.omitted_sheets)
      end

      def delimited(doc, storage)
        bytes = storage.download(key: doc.s3_key, max_bytes: DELIMITED_HEAD_BYTES + 1)
        partial = bytes.bytesize > DELIMITED_HEAD_BYTES
        tabbed = File.extname(doc.filename.to_s).casecmp?(".tsv") ||
                 doc.mime_type.to_s.start_with?("text/tab-separated-values")
        sheet = read_delimited(bytes.byteslice(0, DELIMITED_HEAD_BYTES), separator: tabbed ? "\t" : ",", partial: partial)
        Result.new(kind: :table, sheets: [sheet], omitted_sheets: 0)
      end

      def text(doc, storage)
        bytes = storage.download(key: doc.s3_key, max_bytes: TEXT_HEAD_BYTES + 1)
        partial = bytes.bytesize > TEXT_HEAD_BYTES
        Result.new(kind: :text, text: decode(bytes.byteslice(0, TEXT_HEAD_BYTES), partial: partial), truncated: partial)
      end

      def inline(doc, kind)
        refuse_over!(doc, INLINE_MAX_BYTES)
        content_type = inline_content_type(filename: doc.filename, mime_type: doc.mime_type)
        Result.new(kind: kind, url: doc.signed_url(inline_as: content_type))
      end

      def refuse_over!(doc, cap)
        size = doc.byte_size.to_i
        return unless size > cap

        raise TooLarge, "it is #{megabytes(size)} and previews of this kind stop at #{megabytes(cap)}"
      end
    end
  end
end
