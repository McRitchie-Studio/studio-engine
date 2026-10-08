# frozen_string_literal: true

require_relative "../s3"

module Studio
  module S3
    # Uploads a LOCAL FILE of any size without holding it in memory: an S3
    # multipart upload, one part read and sent at a time. Studio::S3.upload
    # takes a String and suits a document; a recording is hundreds of megabytes.
    #
    # Loaded on first use (`require "studio/s3/multipart"`), not by
    # `require "studio"`.
    #
    # THE BOUNDS, all enforced in `upload_file`:
    #   memory   one part (PART_SIZE, 16 MB) at a time, sent sequentially
    #   parts    MAX_PARTS (10,000, the S3 limit); the loop is `1.upto(MAX_PARTS)`
    #   bytes    `max_bytes:`, counted as parts are read, so a file that grows
    #            under the upload stops there
    #
    # CHECKSUMS AND R2. aws-sdk-s3 from 1.178 adds a CRC32 to uploads by default
    # (`request_checksum_calculation: when_supported`), and R2 has refused some
    # of the combinations that produces (the Active Storage rule in the hub's
    # object-storage module). This uploader therefore uses its OWN client, built
    # from Studio::S3.client_options plus `when_required` for both checksum
    # settings, and sends a Content-MD5 with every part, which S3 and R2 both
    # verify. The shared Studio::S3.client is untouched.
    #
    # UNPROVEN: every test of this file runs against a stubbed client. The
    # request shape (no x-amz-checksum headers, Content-MD5 on each part) is
    # asserted; that a live R2 bucket accepts it is not.
    module Multipart
      # 16 MB. R2 requires every part but the last to be the same size, and S3
      # requires at least 5 MB; 16 MB puts a 1 GB recording in 64 parts.
      PART_SIZE = 16 * 1024 * 1024
      MIN_PART_SIZE = 5 * 1024 * 1024
      # The S3 limit on parts in one upload.
      MAX_PARTS = 10_000

      # What an upload answers.
      Uploaded = Struct.new(:key, :byte_size, :parts, keyword_init: true)

      class << self
        # Streams the file at `path` to `key` (a LOGICAL key, like every
        # Studio::S3 call) and answers an Uploaded. Raises Studio::S3::Error on
        # an empty file, a file over `max_bytes`, or an object whose stored size
        # does not match what was sent. On any failure the multipart upload is
        # aborted, so no parts are left billing in the bucket.
        def upload_file(key:, path:, content_type:, max_bytes:, part_size: PART_SIZE, client: self.client)
          unless max_bytes.is_a?(Integer) && max_bytes.positive?
            raise ArgumentError, "max_bytes must be a positive Integer, got #{max_bytes.inspect}"
          end
          unless part_size.is_a?(Integer) && part_size >= MIN_PART_SIZE
            raise ArgumentError, "part_size must be an Integer of at least #{MIN_PART_SIZE} bytes, got #{part_size.inspect}"
          end

          bucket = Studio::S3.bucket
          target = { bucket: bucket, key: Studio::S3.full_key(key) }

          File.open(path.to_s, "rb") do |file|
            size = file.size
            raise Error, "refusing to upload an empty file: #{path}" if size.zero?
            raise Error, "#{path} is #{size} bytes, over the #{max_bytes}-byte cap" if size > max_bytes

            upload_id = client.create_multipart_upload(**target, content_type: content_type).upload_id
            begin
              parts, sent = send_parts(client, target, upload_id, file, part_size, max_bytes)
              raise Error, "#{path} changed during the upload: #{size} bytes at open, #{sent} sent" unless sent == size

              client.complete_multipart_upload(**target, upload_id: upload_id, multipart_upload: { parts: parts })
            rescue StandardError
              abort_quietly(client, target, upload_id)
              raise
            end

            verify_stored_size!(client, target, sent)
            Uploaded.new(key: key, byte_size: sent, parts: parts.size)
          end
        end

        # A client for multipart uploads: Studio::S3's own options, with both
        # checksum settings at when_required (see CHECKSUMS AND R2 above).
        def client
          @client ||= begin
            require "aws-sdk-s3"
            Aws::S3::Client.new(**client_options)
          end
        end

        def client_options
          Studio::S3.client_options.merge(
            request_checksum_calculation: "when_required",
            response_checksum_validation: "when_required"
          )
        end

        def reset!
          @client = nil
        end

        private

        # Reads and sends one part at a time. Bounded three ways: the loop runs
        # at most MAX_PARTS times, each read is at most part_size bytes, and the
        # running total may not pass max_bytes.
        def send_parts(client, target, upload_id, file, part_size, max_bytes)
          require "digest/md5"
          parts = []
          sent = 0
          1.upto(MAX_PARTS) do |number|
            chunk = file.read(part_size)
            return [parts, sent] if chunk.nil? || chunk.empty?

            sent += chunk.bytesize
            raise Error, "upload passed the #{max_bytes}-byte cap while reading" if sent > max_bytes

            part = client.upload_part(**target, upload_id: upload_id, part_number: number, body: chunk,
                                      content_md5: Digest::MD5.base64digest(chunk))
            parts << { etag: part.etag, part_number: number }
          end
          raise Error, "file needs more than #{MAX_PARTS} parts of #{part_size} bytes" unless file.eof?

          [parts, sent]
        end

        # The object is asked for after the upload, so a store that answered
        # 200 to the completion and kept something else fails here, loudly.
        def verify_stored_size!(client, target, sent)
          stored = client.head_object(**target).content_length
          return if stored == sent

          Studio::S3.guard_production_bucket!(target[:bucket])
          client.delete_object(**target)
          raise Error, "#{target[:key]} stored #{stored.inspect} bytes of #{sent} sent; the object was removed"
        end

        # An abort that fails must not hide the error that caused it.
        def abort_quietly(client, target, upload_id)
          client.abort_multipart_upload(**target, upload_id: upload_id)
        rescue StandardError
          nil
        end
      end
    end
  end
end
