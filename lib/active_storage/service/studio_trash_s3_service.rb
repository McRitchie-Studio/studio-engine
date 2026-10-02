# frozen_string_literal: true

require "active_storage/service/s3_service"
require_relative "../../studio/s3"

module ActiveStorage
  # Active Storage's S3 service with a three-day grace period on delete. An app
  # opts in from config/storage.yml by naming it instead of S3:
  #
  #   r2_production:
  #     service: StudioTrashS3
  #     bucket: turf-monster-production
  #     endpoint: <%= ENV["R2_ENDPOINT"] %>
  #     ...
  #
  # Active Storage resolves `service: StudioTrashS3` by requiring
  # "active_storage/service/studio_trash_s3_service", which is why this file
  # lives at lib/active_storage/service/ on the gem's load path. Nothing
  # autoloads it; Zeitwerk never sees lib/.
  #
  # delete(key) — what Blob#purge and a replaced attachment end in — MOVES the
  # object under trash/ (Studio::S3::Trash) instead of deleting it. By the time
  # it runs the blob row is already destroyed, so what the trash copy records
  # about the blob (content type, byte size, checksum, filename when the upload
  # carried one) is read back off the object itself.
  #
  # delete_prefixed(prefix) stays a HARD delete. Active Storage calls it for
  # "variants/<key>/": derived images, regenerated on demand from the original,
  # which is the object that matters and the one trashed.
  #
  # Both refuse a "*-production" bucket from a non-production process.
  class Service::StudioTrashS3Service < Service::S3Service
    def delete(key)
      instrument :delete, key: key do
        Studio::S3.guard_production_bucket!(bucket.name)
        Studio::S3::Trash.trash!(client: client.client, bucket: bucket.name, key: key,
                                 env: Studio::S3.deletion_environment)
      rescue StandardError => error
        # Logged, then RE-RAISED. Blob#purge has already destroyed the row, so a
        # raise here leaks the object rather than losing it: the failure that
        # costs storage, never the one that costs a user's file.
        log_trash_failure(key, error)
        raise
      end
    end

    def delete_prefixed(prefix)
      Studio::S3.guard_production_bucket!(bucket.name)
      super
    end

    private

    def log_trash_failure(key, error)
      message = "[StudioTrashS3] trash of #{bucket.name}/#{key} failed, object left in place: " \
                "#{error.class}: #{error.message}"
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.error(message)
      else
        warn message
      end
    end
  end
end
