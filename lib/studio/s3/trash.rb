# frozen_string_literal: true

require "time"
require "erb"
require "uri"
require_relative "../s3" unless defined?(Studio::S3::Error)

module Studio
  module S3
    # THE GRACE PERIOD ON A DELETE. R2 has no object versioning, so a delete is
    # forever the moment it lands: a replaced profile picture, a purged
    # attachment, a banner swapped in /admin/emails. Trash turns that delete into
    # a MOVE inside the same bucket:
    #
    #   avatars/abc.png  ->  trash/2026-10-01/1759302000123/avatars/abc.png
    #
    # and the bucket's lifecycle rule (set on the bucket, not here) expires
    # everything under trash/ after three days. Until then the object can be put
    # back with `rake studio:trash:restore[TRASH_KEY]`.
    #
    # THE ORDER IS THE SAFETY. Copy first, delete second, and a copy that fails
    # RAISES before the delete is ever sent. A failure anywhere leaves the
    # original where it was: a leaked object costs storage, a lost one costs a
    # user's photo.
    #
    # Everything here works on REAL object keys (any Studio.s3_key_prefix
    # already applied) and an explicit client + bucket, so Studio::S3 and the
    # Active Storage service (ActiveStorage::Service::StudioTrashS3Service) share
    # one implementation. trash/ always sits at the bucket ROOT, even for an app
    # that lives under a key prefix in a shared bucket, so ONE lifecycle rule and
    # ONE Cloudflare block cover every app in the bucket.
    module Trash
      PREFIX = "trash/"

      # A single CopyObject copies at most 5 GiB (S3 and R2 alike). Larger
      # objects need a multipart copy, which this does not do: it refuses
      # instead, and leaves the object in place. Nothing in the fleet is near
      # it (moms-app's audio is ~650 MB).
      MAX_COPY_BYTES = 5 * 1024**3

      # The metadata trash! writes. restore! strips exactly these back off, so a
      # restored object carries the metadata it was uploaded with and no more.
      TRASH_METADATA_KEYS = %w[
        original-key deleted-at deleted-env
        blob-content-type blob-byte-size blob-checksum blob-filename
      ].freeze

      # Header fields a REPLACE copy would otherwise drop.
      CARRIED_HEADERS = %i[content_type cache_control content_disposition content_encoding content_language].freeze

      class TooLarge < Studio::S3::Error; end
      class ProductionBucketRefused < Studio::S3::Error; end
      class NotTrash < Studio::S3::Error; end
      class RestoreConflict < Studio::S3::Error; end

      TRASH_KEY = %r{\Atrash/(\d{4}-\d{2}-\d{2})/(\d+)/(.+)\z}m

      class << self
        # Move bucket/key under trash/ and return the trash key. Returns nil,
        # sending no copy and no delete, when the object is already gone: an
        # S3 delete of a missing key succeeds, and so does this.
        def trash!(client:, bucket:, key:, env:, now: Time.now.utc)
          head = head(client, bucket, key)
          return nil unless head

          size = head.content_length.to_i
          if size > MAX_COPY_BYTES
            raise TooLarge, "#{bucket}/#{key} is #{size} bytes; a single CopyObject moves at most " \
                            "#{MAX_COPY_BYTES} (5 GiB), so it was NOT trashed and NOT deleted. " \
                            "Delete it with Studio::S3.purge! if you mean it, or copy it aside by hand first."
          end

          trash_key = key_for(key, now: now)
          client.copy_object(
            bucket: bucket,
            copy_source: copy_source(bucket, key),
            key: trash_key,
            metadata_directive: "REPLACE",
            metadata: trash_metadata(head, key: key, env: env, now: now),
            **carried_headers(head)
          )
          # Reached only when the copy returned. A raise above never deletes.
          client.delete_object(bucket: bucket, key: key)
          trash_key
        end

        # trash/<UTC date>/<epoch ms>/<original key>. The date makes a day's
        # deletes easy to browse; the milliseconds keep two deletes of the same
        # key (a profile picture replaced twice in a day) from colliding.
        def key_for(key, now: Time.now.utc)
          now = now.utc
          "#{PREFIX}#{now.strftime('%Y-%m-%d')}/#{(now.to_r * 1000).floor}/#{key}"
        end

        # The original key a trash key was moved from. It is read from the trash
        # key's own path, not from metadata, so it answers even for an object
        # whose metadata a hand copy dropped.
        def original_key(trash_key)
          match = TRASH_KEY.match(trash_key.to_s)
          raise NotTrash, "#{trash_key.inspect} is not a trash key (trash/<date>/<ms>/<key>)" unless match

          match[3]
        end

        def trash_key?(key)
          key.to_s.start_with?(PREFIX)
        end

        # Every trash key whose original key is `key` (any key when nil),
        # oldest first. Pages through the whole trash/ prefix: it is three
        # days deep, so it stays small.
        def list(client:, bucket:, key: nil)
          keys = []
          token = nil
          loop do
            params = { bucket: bucket, prefix: PREFIX }
            params[:continuation_token] = token if token
            resp = client.list_objects_v2(**params)
            resp.contents.each do |object|
              next unless TRASH_KEY.match?(object.key)
              next if key && original_key(object.key) != key

              keys << object
            end
            break unless resp.is_truncated

            token = resp.next_continuation_token
          end
          keys.sort_by(&:key)
        end

        # Copy a trashed object back to its original key and return that key.
        # The trash copy is left alone (the lifecycle rule expires it), so a
        # restore can be repeated. Refuses to overwrite a live object unless
        # overwrite: true, because the original key may already hold a newer
        # upload. Restores the BYTES only: an Active Storage blob row is gone
        # by the time its object is trashed; see blob_attributes.
        def restore!(client:, bucket:, trash_key:, overwrite: false)
          original = original_key(trash_key)
          head = head(client, bucket, trash_key)
          raise NotTrash, "#{bucket}/#{trash_key} does not exist (expired, or never trashed)" unless head
          if !overwrite && head(client, bucket, original)
            raise RestoreConflict, "#{bucket}/#{original} already exists; pass overwrite (FORCE=1) to replace it"
          end

          client.copy_object(
            bucket: bucket,
            copy_source: copy_source(bucket, trash_key),
            key: original,
            metadata_directive: "REPLACE",
            metadata: (head.metadata || {}).reject { |name, _| TRASH_METADATA_KEYS.include?(name) },
            **carried_headers(head)
          )
          original
        end

        # What an Active Storage blob row needs to be rebuilt around a restored
        # key, as far as the trash copy can say. filename is nil unless the
        # upload carried a Content-Disposition (Active Storage only sends one
        # for attachment-disposition blobs); the caller supplies it otherwise.
        def blob_attributes(client:, bucket:, trash_key:)
          head = head(client, bucket, trash_key)
          raise NotTrash, "#{bucket}/#{trash_key} does not exist" unless head

          meta = head.metadata || {}
          {
            key: original_key(trash_key),
            filename: decode(meta["blob-filename"]),
            content_type: meta["blob-content-type"] || head.content_type,
            byte_size: (meta["blob-byte-size"] || head.content_length).to_i,
            checksum: meta["blob-checksum"]
          }
        end

        # CopySource is "<bucket>/<url-encoded key>"; each path segment is
        # escaped and the slashes kept, the form S3 and R2 both accept.
        def copy_source(bucket, key)
          require "aws-sdk-s3"
          "#{bucket}/#{Seahorse::Util.uri_path_escape(key)}"
        end

        private

        def head(client, bucket, key)
          client.head_object(bucket: bucket, key: key)
        rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
          nil
        end

        def carried_headers(head)
          CARRIED_HEADERS.each_with_object({}) do |name, out|
            value = head.public_send(name)
            out[name] = value unless value.nil? || value.to_s.empty?
          end
        end

        # The original object's own metadata first, then the trash record, so a
        # stale "original-key" from an earlier round trip can never win.
        def trash_metadata(head, key:, env:, now:)
          meta = (head.metadata || {}).to_h.dup
          meta["original-key"] = encode(key)
          meta["deleted-at"] = now.utc.iso8601
          meta["deleted-env"] = env.to_s
          meta["blob-content-type"] = head.content_type.to_s unless head.content_type.to_s.empty?
          meta["blob-byte-size"] = head.content_length.to_i.to_s
          checksum = checksum_from_etag(head.etag)
          meta["blob-checksum"] = checksum if checksum
          filename = filename_from_disposition(head.content_disposition)
          meta["blob-filename"] = encode(filename) if filename
          meta
        end

        # A single-part upload's ETag is the hex MD5 of its bytes, and Active
        # Storage's blob checksum is that MD5 in base64. A multipart ETag
        # ("<hex>-<parts>") is not an MD5 of the object, so it yields nothing.
        def checksum_from_etag(etag)
          hex = etag.to_s.delete('"')
          return nil unless hex.match?(/\A\h{32}\z/)

          [[hex].pack("H*")].pack("m0")
        end

        def filename_from_disposition(disposition)
          value = disposition.to_s
          if (match = value.match(/filename\*=UTF-8''([^;]+)/i))
            return URI.decode_uri_component(match[1])
          end
          match = value.match(/filename="([^"]*)"/i) || value.match(/filename=([^;]+)/i)
          match && !match[1].strip.empty? ? match[1].strip : nil
        end

        # S3 metadata travels as HTTP headers, so a value must be ASCII. A key
        # or filename that is not is stored percent-encoded behind "url:".
        def encode(value)
          value = value.to_s
          value.ascii_only? ? value : "url:#{ERB::Util.url_encode(value)}"
        end

        def decode(value)
          return nil if value.nil?
          return URI.decode_uri_component(value.delete_prefix("url:")) if value.start_with?("url:")

          value
        end
      end
    end
  end
end
