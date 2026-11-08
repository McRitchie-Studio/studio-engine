# frozen_string_literal: true

module Studio
  # The self-styled page header (docs/PAGE_HEADER.md, "In a plain-CSS app").
  #
  # studio/_page_header is styled by the engine's Tailwind layer (engine.css). An app
  # that does not build that layer sets `config.page_header_self_styled = true`, and
  # the row then brings its own scoped CSS and its small script, once per page, as
  # the site footer does (studio/site_footer/_assets).
  #
  # Prefixed for the reason Studio::GeoHelper gives: every helper module is included
  # into every view.
  module PageHeaderHelper
    # The styles and the script, once per page, where Studio.page_header_self_styled
    # says this view wants them. nil otherwise, so a Tailwind app's row is unchanged
    # to the byte. studio/_page_header calls it; a layout may call it too, to put
    # the assets in <head>.
    def studio_page_header_assets
      return if @_studio_page_header_assets_rendered
      return unless Studio::PageHeader.self_styled?(self)

      @_studio_page_header_assets_rendered = true
      render "studio/page_header/assets"
    end
  end
end
