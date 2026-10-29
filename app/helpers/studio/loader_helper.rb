# frozen_string_literal: true

require "securerandom"

module Studio
  # The branded loader (docs/LOADER.md), as view helpers. Every one draws the
  # app's own icon (Studio.loader_icon) in its theme colours, in the style the
  # app declared with Studio.loader; there is no per-app markup.
  #
  #   <%= studio_loader %>                          96px, the app's style
  #   <%= studio_loader size: 20, label: "Saving" %> inline, beside text
  #   <%= studio_loader style: :liquid, percent: 40 %> a fill that follows a percent
  #   <%= studio_loader_pending %>                  inside a submit button
  #   <%= studio_loader_overlay %>                  the page-load overlay (layout, once)
  #
  # Prefixed names for the reason Studio::GeoHelper gives: every helper module is
  # included into every view.
  module LoaderHelper
    # Bead layers, coolest first: [dash length of 100, stroke width in a 264-unit
    # icon, opacity]. The colours are CSS (--studio-loader-bead-1..6), so a theme
    # can retune them. The last three glow.
    LOADER_BEAD_LAYERS = [[46, 9, 0.5], [30, 9, 0.75], [16, 9, 0.95], [7, 9.5, 1], [2.6, 10, 1], [0.3, 17, 1]].freeze
    LOADER_BEAD_UNIT = 264.3

    def studio_loader(size: 96, style: nil, icon: nil, art: nil, label: "Loading", percent: nil,
                      tone: nil, pending: false, **html)
      config = Studio.loader
      style = style ? Studio::Loader.style!(style) : config[:style]
      art_data = nil
      if Studio::Loader.art_style?(style)
        art_data = Studio::Loader.art(art || config[:art], style)
        style = Studio::Loader::DEFAULT_STYLE if art_data.nil?
      end

      render "studio/loader/loader",
             style: style,
             size: studio_loader_size(size),
             icon: icon || Studio.loader_icon,
             art: art_data,
             label: label,
             percent: percent.nil? ? nil : percent.to_f.clamp(0, 100).round(1),
             mono: (tone || (pending ? :mono : nil)).to_s == "mono",
             pending: pending,
             uid: "studio-loader-#{SecureRandom.hex(4)}",
             html: html
    end

    # The small loader a submit button carries. Hidden until the button, or the
    # form it submits, is aria-busy (Turbo marks the form; studio/loader marks
    # the button for a form Turbo does not drive). Drawn in the button's own
    # text colour, so it reads on any fill.
    def studio_loader_pending(size: 18, style: :breathe, **options)
      studio_loader(size: size, style: style, pending: true, **options)
    end

    # The full-page overlay: once, in the layout's body. studio/loader shows it
    # when a visit the user started (never a background replace) or a marked
    # form outlasts `delay` ms, and window.StudioLoader.show() / hide() drive it
    # for any other long wait. A submit Turbo does not drive clears its overlay
    # and busy button after `max_wait` ms, so a response that became a download
    # never leaves them up; a Turbo visit is never capped.
    # Any studio_loader option (style:, icon:, art:) passes through.
    def studio_loader_overlay(label: "Loading", delay: 350, max_wait: 15_000, size: 96, **options)
      render "studio/loader/overlay", label: label, delay: delay.to_i, max_wait: max_wait.to_i, size: size, options: options
    end

    def studio_loader_size(size)
      size.is_a?(Numeric) ? "#{size}px" : size.to_s
    end

    # The stroke layers a weld bead draws over the art's outline path.
    def studio_loader_bead_layers(art)
      unit = art[:width] / LOADER_BEAD_UNIT
      LOADER_BEAD_LAYERS.each_with_index.map do |(dash, width, opacity), index|
        { n: index + 1, dash: dash, width: (width * unit).round(2), opacity: opacity, glow: index >= 3 }
      end
    end
  end
end
