module Studio
  class KnowledgeDoc
    # A document's RECORDING: the audio or video of the meeting whose transcript
    # the document is. The transcript stays the document (s3_key); the recording
    # is one more object in the same private bucket, pointed at by four columns
    # (recording_key, recording_mime_type, recording_byte_size,
    # recording_source_url) that the AddRecordingToStudioKnowledgeDocs migration
    # adds.
    #
    # A CONSUMER THAT HAS NOT INSTALLED THAT MIGRATION KEEPS WORKING. Every
    # reader here asks `has_attribute?` first, so on the old schema `recording?`
    # is false and `recording_link` is nil; only the two attach methods raise
    # (MissingRecordingColumns, naming the fix) and they raise before any byte
    # moves.
    #
    # What counts as a recording, the size cap and the URL fetch live in
    # Studio::KnowledgeRecording; the upload is Studio::S3::Multipart. Both load
    # on first use.
    module Recording
      extend ActiveSupport::Concern

      # The app has the documents table but not the recording columns.
      class MissingRecordingColumns < StandardError; end

      # How long a playback URL is good for: six hours. A presigned URL is
      # checked on EVERY request the player makes, and a player makes a new
      # ranged request each time the viewer seeks, so the URL has to outlive
      # the whole sitting, not just the page load: the 15-minute document link
      # would stop a recording at its first seek past minute fifteen. Six hours
      # is twice the longest meeting the layer is expected to hold, which covers
      # one viewing with pauses. It is far under SigV4's seven-day ceiling
      # (MAX_RECORDING_URL_TTL), and the URL is only ever handed to a signed-in
      # admin's page.
      RECORDING_URL_TTL = 6 * 60 * 60
      MAX_RECORDING_URL_TTL = 7 * 24 * 60 * 60

      RECORDING_COLUMNS = %w[recording_key recording_mime_type recording_byte_size recording_source_url].freeze

      included do
        validate :recording_source_url_is_a_web_link
      end

      class_methods do
        # Whether this app's table carries the recording columns.
        def recording_columns?
          table_exists? && (RECORDING_COLUMNS - column_names).empty?
        end
      end

      # A recording is stored for this document. False, never an error, on a
      # table without the columns.
      def recording?
        has_attribute?(:recording_key) && self[:recording_key].present?
      end

      # :video or :audio, by the stored content type; nil without a recording.
      def recording_kind
        return nil unless recording?

        self[:recording_mime_type].to_s.start_with?("audio/") ? :audio : :video
      end

      # The external page the recording came from, when it is a link a page can
      # safely render (http or https); nil otherwise, and nil without the column.
      def recording_link
        return nil unless has_attribute?(:recording_source_url)

        require "studio/knowledge_recording"
        Studio::KnowledgeRecording.web_link(self[:recording_source_url])
      end

      # A presigned GET for the player. See RECORDING_URL_TTL for the default.
      def recording_url(expires_in: RECORDING_URL_TTL)
        raise Studio::S3::Error, "no recording attached to #{title.inspect}" unless recording?

        seconds = expires_in.to_i
        unless seconds.between?(1, MAX_RECORDING_URL_TTL)
          raise ArgumentError, "expires_in must be between 1 and #{MAX_RECORDING_URL_TTL} seconds, got #{expires_in.inspect}"
        end

        Studio::S3.signed_url(key: self[:recording_key], expires_in: seconds)
      end

      # Stores the file at `path` as this document's recording and SAVES the
      # row. The file is streamed in parts, never read whole.
      #
      #   filename:    the name whose extension is judged and kept in the key
      #                (default: the path's own)
      #   source_url:  the external page the recording came from; nil leaves
      #                the stored link as it is
      #
      # Order, and what each failure leaves behind:
      #   1. columns, link, file type and size, and the row's own validity are
      #      checked. Nothing has been written.
      #   2. the new object is uploaded under a new key. A failure aborts the
      #      multipart upload; the row is untouched.
      #   3. the row is saved. A failure trashes the new object and re-raises.
      #   4. the recording this one replaced goes to trash (Studio::S3.delete,
      #      recoverable for three days). A failure here raises with the row
      #      already pointing at the new recording; the old object is the only
      #      thing left behind.
      def attach_recording!(path, filename: nil, source_url: nil, strict_extension: true)
        ensure_recording_columns!
        require "studio/knowledge_recording"
        require "studio/s3/multipart"

        link = checked_recording_link(source_url)
        identified = Studio::KnowledgeRecording.identify!(path, filename: filename || File.basename(path.to_s),
                                                                strict_extension: strict_extension)
        validate!

        key = new_recording_key(filename || File.basename(path.to_s), identified.extension)
        uploaded = Studio::S3::Multipart.upload_file(key: key, path: path, content_type: identified.content_type,
                                                     max_bytes: Studio::KnowledgeRecording::MAX_BYTES)
        replaced = self[:recording_key]
        begin
          attributes = { recording_key: key, recording_mime_type: identified.content_type,
                         recording_byte_size: uploaded.byte_size }
          attributes[:recording_source_url] = link if link
          update!(attributes)
        rescue StandardError
          trash_unreferenced_recording(key)
          raise
        end

        Studio::S3.delete(key: replaced) if replaced.present? && replaced != key
        self
      end

      # Fetches `url` to a temporary file and attaches it. The fetch is https
      # only and goes through the engine's SSRF guard on every hop; see
      # Studio::KnowledgeRecording.fetch. The download URL is NOT stored (it
      # usually carries a credential); pass `source_url:` for the page to link.
      def attach_recording_from_url!(url, source_url: nil, resolver: nil)
        ensure_recording_columns!
        require "studio/knowledge_recording"
        checked_recording_link(source_url)

        options = resolver ? { resolver: resolver } : {}
        Studio::KnowledgeRecording.fetch(url, **options) do |path, name|
          attach_recording!(path, filename: name, source_url: source_url, strict_extension: false)
        end
      end

      private

      def ensure_recording_columns!
        return if self.class.recording_columns?

        raise MissingRecordingColumns,
              "Attaching a recording needs the recording columns on studio_knowledge_docs, and " \
              "#{Studio.app_name} does not have them. Run `bin/rails studio_engine:install:migrations && " \
              "bin/rails db:migrate`."
      end

      def checked_recording_link(source_url)
        return nil if source_url.nil? || source_url.to_s.strip.empty?

        Studio::KnowledgeRecording.web_link(source_url) ||
          raise(ArgumentError, "source_url must be an http(s) link of at most " \
                               "#{Studio::KnowledgeRecording::MAX_URL_BYTES} bytes")
      end

      # Beside the document's own key, with the same collision-proofing
      # attach! uses (a second-granular timestamp plus a random suffix).
      def new_recording_key(name, extension)
        file = self.class.sanitize_filename(Studio::KnowledgeRecording.filename_for(name, extension))
        [
          "knowledge", entity, path.presence,
          "#{Time.current.strftime('%Y%m%d%H%M%S')}-#{SecureRandom.hex(4)}-recording-#{file}"
        ].compact.join("/")
      end

      # The row never took the new object, so nothing points at it. Trashing
      # it must not hide the error that got us here.
      def trash_unreferenced_recording(key)
        Studio::S3.delete(key: key)
      rescue StandardError => error
        Rails.logger&.error("[Studio::KnowledgeDoc] could not trash unreferenced recording #{key}: #{error.class}")
      end

      def recording_source_url_is_a_web_link
        return unless has_attribute?(:recording_source_url)

        value = self[:recording_source_url]
        return if value.blank?

        require "studio/knowledge_recording"
        return if Studio::KnowledgeRecording.web_link(value)

        errors.add(:recording_source_url, "must be an http(s) link")
      end
    end
  end
end
