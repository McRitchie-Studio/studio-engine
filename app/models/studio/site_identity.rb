# frozen_string_literal: true

module Studio
  # This app's IDENTITY COPY: the title and description that say what the app is,
  # and the picture that goes with them. The operator edits all three together
  # at /admin/link_preview, beside a live preview card.
  #
  # Link previews are the first reader (every page unfurls with these unless it
  # overrides them), but not the only one: the words are the app's reusable
  # identity, so an app reads them through Studio.site_identity (or the view
  # helper studio_site_identity) wherever it needs them — a meta description,
  # share text, an email footer.
  #
  # One row per app (Studio.app_name), exactly like Studio::GeoSetting. Lifted
  # from turf-monster's SiteSetting (default_og_image/title/description and the
  # og_defaults cache), which ran it in production first.
  #
  # THE RESOLUTION, most specific first:
  #
  #   operator's saved value (this row)  ->  the drafted default in code
  #   (Studio.site_title / Studio.site_description)  ->  Studio.app_name / none
  #
  # So an agent setting an app up drafts the words into the initializer, where
  # they are reviewed in a PR, and the operator overrides them here without a
  # deploy. `seed!` carries a drafted default into the row instead.
  #
  # NIL-SAFE THROUGHOUT, because the table is installed by a migration the host
  # runs: an app that has not run it still renders every page.
  class SiteIdentity < ApplicationRecord
    include Sluggable

    self.table_name = "studio_site_identities"

    # Read on EVERY page render (the head's tags), edited a few times a year. So
    # the stored values are cached, and busted on any write — see .stored.
    CACHE_KEY_PREFIX = "studio/site_identity/v2" # v2: adds image_width/image_height
    CACHE_TTL = 1.hour

    TITLE_MAX = 200
    DESCRIPTION_MAX = 500

    # What the image upload accepts. Here rather than on the controller so the
    # page's file input can name it without reaching into a controller.
    IMAGE_TYPES = %w[image/png image/jpeg image/webp image/gif].freeze
    MAX_IMAGE_BYTES = 8 * 1024 * 1024

    # The image. `service:` is a LITERAL fixed when this class loads, which is why
    # Studio.link_preview_image_service must be set in the initializer. Guarded
    # so a host without Active Storage still loads the class (and simply has no
    # uploadable image).
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
      # This app's row, or an unsaved one — or nil when the table is not
      # installed, because a model with no table cannot even be instantiated.
      def current
        return nil unless table_ready?

        find_by(app_name: Studio.app_name) || new(app_name: Studio.app_name)
      end

      # This app's row, created on first write. The unique index makes a
      # cold-start race raise RecordNotUnique for the loser; it re-reads.
      def current!
        find_or_create_by!(app_name: Studio.app_name)
      rescue ActiveRecord::RecordNotUnique
        find_by!(app_name: Studio.app_name)
      end

      # THE RESOLVED IDENTITY — what any caller should read:
      #
      #   Studio::SiteIdentity.resolved(base_url: request.base_url)
      #   # => { title: "Turf Monster", description: "Skill-based pick'em...",
      #   #      image_url: "https://.../og.png" }
      #
      # `image_url` is the operator's uploaded image, else the static fallback,
      # else nil. It is absolute when it can be: a public service's own URL
      # always is; a proxy path or a root-relative static path is joined to
      # `base_url` when one is given, and left root-relative otherwise.
      # Studio.site_identity is the same call.
      def resolved(base_url: nil)
        stored_values = stored
        image = stored_values[:image_url] || stored_values[:image_path] || static_image
        {
          title: stored_values[:title] || Studio.site_title.presence || Studio.app_name.to_s,
          description: stored_values[:description] || Studio.site_description.presence,
          image_url: base_url ? Studio::LinkPreview.absolute_url(image, base_url: base_url) : image
        }
      end

      # Only what the OPERATOR saved (nil where they saved nothing), with the
      # image as a PERMANENT URL (a public service's own URL) or a host-relative
      # PROXY path. Neither is a signed, expiring URL: an unfurler caches the
      # og:image URL and re-fetches it days later. Cached; see CACHE_TTL.
      #
      # An app without the table is not cached as "nothing": the first request
      # after the migration must see the table.
      def stored
        return empty_stored unless table_ready?

        Rails.cache.fetch(cache_key_for_app, expires_in: CACHE_TTL) { compute_stored }
      end

      # Carry a DRAFTED default into the row, filling only what the operator has
      # not already set — safe to run from db/seeds.rb or a release task on every
      # deploy, because it never overwrites an operator's edit. Returns the row,
      # or nil when the table is not installed yet.
      #
      #   Studio::SiteIdentity.seed!(title: "Turf Monster",
      #                              description: "Skill-based pick'em contests.")
      def seed!(title: nil, description: nil)
        return nil unless table_ready?

        row = current!
        row.title = title if row.title.blank? && title.present?
        row.description = description if row.description.blank? && description.present?
        row.save! if row.changed?
        row
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
      # blob. Shared by the operator's image and a page override that hands in
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

      # The app's own static card (public/og.png by default), used only when the
      # file is really there — a missing one would be a broken image in every
      # unfurl. Absolute URLs are trusted as given. Memoized per path for the
      # life of the process: public/ is fixed at deploy.
      def static_image
        path = Studio.link_preview_fallback_image.to_s
        return nil if path.empty?
        return path unless Studio::LocalPath.local?(path)

        @static_files ||= Concurrent::Map.new
        present = @static_files.compute_if_absent(path) do
          File.file?(Rails.public_path.join(path.delete_prefix("/")))
        end
        present ? path : nil
      end

      def reset_static_image!
        @static_files = nil
        @static_dimensions = nil
      end

      # [width, height] of the static fallback, read from the file's header, or
      # nil when there is no local file (an absolute URL is never fetched) or its
      # format is not one Studio::LinkPreview.image_dimensions reads. Memoized
      # per path like static_image.
      def static_image_dimensions
        path = static_image
        return nil unless Studio::LocalPath.local?(path)

        @static_dimensions ||= Concurrent::Map.new
        dims = @static_dimensions.compute_if_absent(path) do
          Studio::LinkPreview.image_dimensions(Rails.public_path.join(path.delete_prefix("/"))) || false
        end
        dims || nil
      end

      # [width, height] from an attachment's or blob's ANALYZED metadata, or nil
      # before Active Storage's analyze job has run (or for a non-image).
      def image_dimensions(attachable)
        return nil if attachable.nil?
        return nil if attachable.respond_to?(:attached?) && !attachable.attached?

        blob = attachable.respond_to?(:blob) ? attachable.blob : attachable
        metadata = blob.respond_to?(:metadata) ? blob.metadata : nil
        return nil unless metadata.is_a?(Hash)

        width = metadata["width"] || metadata[:width]
        height = metadata["height"] || metadata[:height]
        width.is_a?(Integer) && height.is_a?(Integer) && width.positive? && height.positive? ? [width, height] : nil
      rescue StandardError
        nil
      end

      private

      def empty_stored
        { title: nil, description: nil, image_url: nil, image_path: nil, image_width: nil, image_height: nil }
      end

      def compute_stored
        row = find_by(app_name: Studio.app_name)
        return empty_stored if row.nil?

        location = row.respond_to?(:image) ? image_location(row.image) : nil
        width, height = (image_dimensions(row.image) if location)
        {
          title: row.title.presence,
          description: row.description.presence,
          image_url: location&.dig(:url),
          image_path: location&.dig(:path),
          image_width: width,
          image_height: height
        }
      end
    end

    def image_attached?
      respond_to?(:image) && image.attached?
    end

    def name_slug
      "site-identity-#{app_name.to_s.parameterize}"
    end
  end
end
