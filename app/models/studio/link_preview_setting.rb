# frozen_string_literal: true

module Studio
  # The operator's link-preview DEFAULT for this app: the image, title and
  # description an unfurl shows for any page that does not name its own.
  # Edited at /admin/link_preview (Studio::LinkPreviewSettingsController).
  #
  # One row per app (Studio.app_name), exactly like Studio::GeoSetting. Lifted
  # from turf-monster's SiteSetting (default_og_image/title/description and the
  # og_defaults cache), which ran it in production first.
  #
  # NIL-SAFE THROUGHOUT, because the table is installed by a migration the host
  # runs: an app that has not run it must still render every page, so every read
  # answers "no default" instead of raising.
  class LinkPreviewSetting < ApplicationRecord
    include Sluggable

    self.table_name = "studio_link_preview_settings"

    # Read on EVERY page render (the head's tags), edited a few times a year. So
    # the answer is cached, and busted on any write — see .defaults.
    CACHE_KEY_PREFIX = "studio/link_preview/defaults/v1"
    CACHE_TTL = 1.hour

    TITLE_MAX = 200
    DESCRIPTION_MAX = 500

    # The image. `service:` is a LITERAL fixed when this class loads, which is why
    # Studio.link_preview_image_service must be set in the initializer. Guarded
    # so a host without Active Storage still loads the class (and simply has no
    # uploadable default).
    if respond_to?(:has_one_attached)
      if Studio.link_preview_image_service
        has_one_attached :image, service: Studio.link_preview_image_service
      else
        has_one_attached :image
      end
    end

    validates :app_name, presence: true, uniqueness: true
    validates :title, length: { maximum: TITLE_MAX }
    validates :description, length: { maximum: DESCRIPTION_MAX }

    before_validation { self.app_name = Studio.app_name if app_name.blank? }

    # A title/description write commits the row; an image attach does NOT touch
    # it, so the controller busts explicitly after one (see bust_cache!).
    after_commit { self.class.bust_cache! }

    class << self
      # This app's row, or an unsaved one. Never nil.
      def current
        return new(app_name: Studio.app_name) unless table_ready?

        find_by(app_name: Studio.app_name) || new(app_name: Studio.app_name)
      end

      # This app's row, created on first write. The unique index makes a
      # cold-start race raise RecordNotUnique for the loser; it re-reads.
      def current!
        find_or_create_by!(app_name: Studio.app_name)
      rescue ActiveRecord::RecordNotUnique
        find_by!(app_name: Studio.app_name)
      end

      # What the head needs, cached: the operator's title and description, and
      # the image as a PERMANENT URL (a public service's own URL) or a
      # host-relative PROXY path the helper joins to the request's base URL.
      # Neither is a signed, expiring URL — an unfurler caches the og:image URL
      # and re-fetches it days later.
      #
      # An app without the table is not cached as "nothing": the first request
      # after the migration must see the table.
      def defaults
        return empty_defaults unless table_ready?

        Rails.cache.fetch(cache_key_for_app, expires_in: CACHE_TTL) { compute_defaults }
      end

      def bust_cache!
        Rails.cache.delete(cache_key_for_app)
      rescue StandardError
        nil
      end

      def cache_key_for_app
        "#{CACHE_KEY_PREFIX}/#{Studio.app_name.to_s.parameterize}"
      end

      def table_ready?
        table_exists?
      rescue ActiveRecord::ActiveRecordError, NameError
        false
      end

      # Whether an attachment's service answers a permanent public URL. A
      # MirrorService never sets public? itself but delegates `url` to its
      # primary, so ask the primary (turf-monster's R2 move depends on this).
      def public_service?(service)
        (service.respond_to?(:primary) ? service.primary : service).public?
      rescue StandardError
        false
      end

      # A permanent URL, or a host-relative proxy path, for any attachment or
      # blob. Shared by the operator default and a page override that hands in
      # an attachment (a user's avatar), so both follow one rule.
      def image_location(attachable)
        return nil if attachable.nil?
        return nil if attachable.respond_to?(:attached?) && !attachable.attached?

        blob = attachable.respond_to?(:blob) ? attachable.blob : attachable
        return nil if blob.nil?

        if public_service?(blob.service)
          { url: blob.url }
        else
          { path: Rails.application.routes.url_helpers.rails_storage_proxy_path(blob, only_path: true) }
        end
      end

      private

      def empty_defaults
        { title: nil, description: nil, image_url: nil, image_path: nil }
      end

      def compute_defaults
        row = find_by(app_name: Studio.app_name)
        return empty_defaults if row.nil?

        location = row.respond_to?(:image) ? image_location(row.image) : nil
        {
          title: row.title.presence,
          description: row.description.presence,
          image_url: location&.dig(:url),
          image_path: location&.dig(:path)
        }
      end
    end

    def image_attached?
      respond_to?(:image) && image.attached?
    end

    def name_slug
      "link-preview-#{app_name.to_s.parameterize}"
    end
  end
end
