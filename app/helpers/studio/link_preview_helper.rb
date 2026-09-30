# frozen_string_literal: true

module Studio
  # View-side link preview: the ONE override a page uses, and the tags the head
  # renders. The policy (which rung wins) is Studio::LinkPreview.resolve; this
  # module only gathers the rungs, and it is where the request's base URL and
  # the asset paths are known.
  #
  # Method names are prefixed (`link_preview`, `studio_link_preview*`) for the
  # reason Studio::GeoHelper gives: every helper module is included into every
  # view, so an unprefixed name would collide with a host's own helper.
  module LinkPreviewHelper
    OVERRIDE_KEYS = %i[image title description].freeze

    # THE PAGE OVERRIDE. Call it from any view (the layout renders later, so it
    # sees the call):
    #
    #   <% link_preview image: @contest.banner, title: @contest.name,
    #                   description: @contest.tagline %>
    #
    # `image:` takes a URL, a root-relative path, or an Active Storage
    # attachment/blob (a user's avatar). An image that is nil, blank, or an
    # attachment with nothing attached falls back to the operator's default, so
    # a page can pass `image: user.avatar` without asking whether there is one.
    # Only the keys passed are set; a second call overrides just its own keys.
    # Returns nil, so `<%= link_preview ... %>` prints nothing either.
    def link_preview(**overrides)
      unknown = overrides.keys - OVERRIDE_KEYS
      raise ArgumentError, "link_preview takes #{OVERRIDE_KEYS.join(", ")}; got #{unknown.join(", ")}" if unknown.any?

      (@studio_link_preview_overrides ||= {}).merge!(overrides)
      nil
    end

    # The resolved preview for this page:
    # { title:, description:, image:, image_source:, site_name:, url: }.
    # `image` is absolute (or nil). Never raises: a preview must not 500 a page.
    def studio_link_preview
      overrides = @studio_link_preview_overrides || {}
      defaults = studio_link_preview_defaults
      base_url = studio_link_preview_base_url

      preview = Studio::LinkPreview.resolve(
        site_name: Studio.app_name,
        titles: [overrides[:title], content_for(:title), defaults[:title], Studio.link_preview_default_title],
        descriptions: [overrides[:description], content_for(:meta_description),
                       defaults[:description], Studio.link_preview_default_description],
        # content_for(:og_image) is turf-monster's existing page-level key,
        # honoured so its pages keep their override on adoption.
        page_images: [studio_link_preview_image_location(overrides[:image]), content_for(:og_image)],
        default_image: defaults[:image_url] || defaults[:image_path],
        static_image: studio_link_preview_static_image
      )

      preview.merge(
        image: Studio::LinkPreview.absolute_url(preview[:image], base_url: base_url) || preview[:image],
        site_name: Studio.app_name.to_s,
        url: studio_link_preview_page_url
      )
    end

    # The og:/twitter: tags for this page. layouts/studio/_head renders this
    # when Studio.link_preview_tags? says so; an app that set
    # `link_preview_tags = false` can render it wherever it likes.
    def studio_link_preview_tags
      render "layouts/studio/link_preview_tags", preview: studio_link_preview
    rescue StandardError => e
      Rails.logger&.warn("[studio.link_preview] tags skipped: #{e.class}: #{e.message}")
      "".html_safe
    end

    private

    def studio_link_preview_defaults
      Studio::LinkPreviewSetting.defaults
    rescue StandardError => e
      Rails.logger&.warn("[studio.link_preview] defaults unavailable: #{e.class}: #{e.message}")
      {}
    end

    def studio_link_preview_image_location(image)
      return nil if image.nil?
      return image.to_s if image.is_a?(String) || image.is_a?(Symbol)

      location = Studio::LinkPreviewSetting.image_location(image)
      location && (location[:url] || location[:path])
    rescue StandardError
      nil
    end

    # The app's own static card (public/og.png by default), used only when the
    # file is really there — a missing one would be a broken image in every
    # unfurl. Absolute URLs are trusted as given.
    def studio_link_preview_static_image
      path = Studio.link_preview_fallback_image.to_s
      return nil if path.empty?
      return path unless path.start_with?("/") && !path.start_with?("//")

      Studio::LinkPreviewHelper.static_file?(path) ? path : nil
    end

    def studio_link_preview_base_url
      respond_to?(:request) && request ? request.base_url : nil
    end

    def studio_link_preview_page_url
      respond_to?(:request) && request ? request.original_url : nil
    end

    # Whether a root-relative path exists under public/. Memoized per path for
    # the life of the process: public/ is fixed at deploy.
    def self.static_file?(path)
      @static_files ||= Concurrent::Map.new
      @static_files.compute_if_absent(path) do
        File.file?(Rails.public_path.join(path.delete_prefix("/")))
      end
    end

    def self.reset_static_files!
      @static_files = nil
    end
  end
end
