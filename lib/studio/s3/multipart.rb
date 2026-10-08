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
    #            and the first short read ends it
    #   bytes    `max_bytes:`, counted as parts are read, so a file that grows
    #            under the upload stops there
    #   time     UPLOAD_DEADLINE (2 hours), read before each part. One request
    #            is bounded by the SDK client's own timeouts and retries
    #            (http_open_timeout 15 s, http_read_timeout 60 s, 3 retries;
    #            the suite pins those defaults), not by this deadline.
    #
    # WHAT A FAILURE LEAVES IN THE BUCKET:
    #   before completion   nothing: the multipart upload is aborted on ANY
    #                       way out, a signal (SIGTERM, Ctrl-C) included
    #   after completion    nothing: an object whose size cannot be confirmed
    #                       is deleted before the error is raised
    #   SIGKILL, power      the parts sent so far, invisible to listings, until
    #                       the bucket's abort-incomplete-multipart lifecycle
    #                       rule removes them (R2's default rule: 7 days). No
    #                       process can clean up after its own SIGKILL.
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
      # Seconds for the whole upload, read before each part. A 4 GB file is
      # 256 parts; two hours allows about 28 s a part.
      UPLOAD_DEADLINE = 7_200

      # What an upload answers.
      Uploaded = Struct.new(:key, :byte_size, :parts, keyword_init: true)

      class << self
        # Streams the file at `path` to `key` (a LOGICAL key, like every
        # Studio::S3 call) and answers an Uploaded. Raises Studio::S3::Error on
        # an empty file, a file over `max_bytes`, an upload past `deadline`
        # seconds, or an object whose stored size does not match what was
        # sent. See WHAT A FAILURE LEAVES IN THE BUCKET above.
        def upload_file(key:, path:, content_type:, max_bytes:, part_size: PART_SIZE, deadline: UPLOAD_DEADLINE,
                        client: self.client)
          unless max_bytes.is_a?(Integer) && max_bytes.positive?
            raise ArgumentError, "max_bytes must be a positive Integer, got #{max_bytes.inspect}"
          end
          unless part_size.is_a?(Integer) && part_size >= MIN_PART_SIZE
            raise ArgumentError, "part_size must be an Integer of at least #{MIN_PART_SIZE} bytes, got #{part_size.inspect}"
          end

          bucket = Studio::S3.bucket
          target = { bucket: bucket, key: Studio::S3.full_key(key) }
          stop_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline

          File.open(path.to_s, "rb") do |file|
            size = file.size
            raise Error, "refusing to upload an empty file: #{path}" if size.zero?
            raise Error, "#{path} is #{size} bytes, over the #{max_bytes}-byte cap" if size > max_bytes

            upload_id = client.create_multipart_upload(**target, content_type: content_type).upload_id
            completed = false
            begin
              parts, sent = send_parts(client, target, upload_id, file, part_size, max_bytes, stop_at)
              raise Error, "#{path} changed during the upload: #{size} bytes at open, #{sent} sent" unless sent == size

              client.complete_multipart_upload(**target, upload_id: upload_id, multipart_upload: { parts: parts })
              completed = true
            ensure
              # `ensure`, not `rescue StandardError`: a SIGTERM or Ctrl-C is
              # not a StandardError, and parts left behind are privileged
              # bytes no listing shows.
              abort_quietly(client, target, upload_id) unless completed
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

        # Reads and sends one part at a time. Bounded four ways: the loop runs
        # at most MAX_PARTS times, each read is at most part_size bytes, the
        # running total may not pass max_bytes, and the first short read ends it.
        def send_parts(client, target, upload_id, file, part_size, max_bytes, stop_at)
          require "digest/md5"
          parts = []
          sent = 0
          1.upto(MAX_PARTS) do |number|
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) > stop_at
              raise Error, "the upload passed its deadline after #{parts.size} part(s)"
            end

            chunk = file.read(part_size)
            return [parts, sent] if chunk.nil? || chunk.empty?

            sent += chunk.bytesize
            raise Error, "upload passed the #{max_bytes}-byte cap while reading" if sent > max_bytes

            part = client.upload_part(**target, upload_id: upload_id, part_number: number, body: chunk,
                                      content_md5: Digest::MD5.base64digest(chunk))
            parts << { etag: part.etag, part_number: number }
            # A short read is the end of the file, and the last part. Reading
            # on would chase a file that is still being appended to, and every
            # part but the last must be part_size (R2 refuses otherwise).
            return [parts, sent] if chunk.bytesize < part_size
          end
          raise Error, "file needs more than #{MAX_PARTS} parts of #{part_size} bytes" unless file.eof?

          [parts, sent]
        end

        # The object is asked for after the upload, so a store that answered
        # 200 to the completion and kept something else fails here, loudly.
        # The upload is COMPLETE by now, so every way out of here that is not
        # success removes the object first: a size that differs, a head_object
        # that raises, or a signal. Otherwise a whole recording would sit in
        # the bucket with no row pointing at it.
        def verify_stored_size!(client, target, sent)
          confirmed = false
          stored = client.head_object(**target).content_length
          confirmed = stored == sent
          return if confirmed

          raise Error, "#{target[:key]} stored #{stored.inspect} bytes of #{sent} sent; the object was removed"
        ensure
          remove_quietly(client, target) unless confirmed
        end

        # A new object nothing references: a hard delete, behind the same
        # production-bucket guard as every delete. A failure here must not
        # hide the error that caused it.
        def remove_quietly(client, target)
          Studio::S3.guard_production_bucket!(target[:bucket])
          client.delete_object(**target)
        rescue StandardError
          nil
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
