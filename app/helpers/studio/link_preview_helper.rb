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
    #
    # Rungs, most specific first: the page's `link_preview`, then the page's
    # own content_for(:title) / content_for(:meta_description) /
    # content_for(:og_image) (turf-monster's existing keys, honoured so its
    # pages keep their overrides on adoption), then the site identity.
    def studio_link_preview
      overrides = @studio_link_preview_overrides || {}
      stored = studio_site_identity_stored

      preview = Studio::LinkPreview.resolve(
        site_name: Studio.app_name,
        titles: [overrides[:title], studio_link_preview_content(:title), stored[:title], Studio.site_title],
        descriptions: [overrides[:description], studio_link_preview_content(:meta_description),
                       stored[:description], Studio.site_description],
        page_images: [studio_link_preview_image_location(overrides[:image]), studio_link_preview_content(:og_image)],
        default_image: stored[:image_url] || stored[:image_path],
        static_image: Studio::SiteIdentity.static_image
      )

      preview.merge(
        image: Studio::LinkPreview.absolute_url(preview[:image], base_url: studio_request_base_url) || preview[:image],
        site_name: Studio.app_name.to_s,
        url: (request.original_url if respond_to?(:request) && request)
      )
    end

    # The app's IDENTITY COPY — { title:, description:, image_url: } — for any
    # view that wants the words, not the tags: a meta description, share text,
    # an email footer. The site-wide answer, ignoring this page's overrides.
    # Studio.site_identity is the same call outside a view.
    def studio_site_identity
      Studio.site_identity(base_url: studio_request_base_url)
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

    def studio_site_identity_stored
      Studio::SiteIdentity.stored
    rescue StandardError => e
      Rails.logger&.warn("[studio.link_preview] site identity unavailable: #{e.class}: #{e.message}")
      {}
    end

    def studio_link_preview_image_location(image)
      return nil if image.nil?
      return image.to_s if image.is_a?(String) || image.is_a?(Symbol)

      location = Studio::SiteIdentity.image_location(image)
      location && (location[:url] || location[:path])
    rescue StandardError
      nil
    end

    # content_for holds ESCAPED text in a SafeBuffer, and the resolver's strip
    # returns a plain String the tag partial escapes again ("Pass &amp;amp; Run").
    # Hand the resolver the plain text instead.
    def studio_link_preview_content(key)
      value = content_for(key)
      value && CGI.unescapeHTML(value.to_str)
    end

    def studio_request_base_url
      respond_to?(:request) && request ? request.base_url : nil
    end
  end
end
