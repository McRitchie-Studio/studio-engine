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
  # The plain styles draw no icon, only theme colours (docs/LOADER.md, "The family"):
  #
  #   <%= studio_loader style: :spinner %>          a ring, 20px
  #   <%= studio_loader style: :dots %>             three pulsing dots
  #   <%= studio_loader style: :bar, percent: 40 %> a bar; without percent it sweeps
  #
  # Prefixed names for the reason Studio::GeoHelper gives: every helper module is
  # included into every view.
  module LoaderHelper
    # Bead layers, coolest first: [dash length of 100, stroke width in a 264-unit
    # icon, opacity]. The colours are CSS (--studio-loader-bead-1..6), so a theme
    # can retune them. The last three glow.
    LOADER_BEAD_LAYERS = [[46, 9, 0.5], [30, 9, 0.75], [16, 9, 0.95], [7, 9.5, 1], [2.6, 10, 1], [0.3, 17, 1]].freeze
    LOADER_BEAD_UNIT = 264.3

    def studio_loader(size: nil, style: nil, icon: nil, art: nil, label: "Loading", percent: nil,
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
             size: studio_loader_size(size.nil? ? Studio::Loader.default_size(style) : size),
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
    def studio_loader_overlay(label: "Loading", delay: Studio::Loader::OVERLAY_DELAY_MS, min_show: Studio::Loader::OVERLAY_MIN_SHOW_MS, max_wait: 15_000, size: 96, **options)
      render "studio/loader/overlay", label: label, delay: delay.to_i, min_show: min_show.to_i, max_wait: max_wait.to_i, size: size, options: options
    end

    # ---- The rest of the family: the page's shape while it waits ----------

    SKELETON_KINDS = %i[lines avatar card media].freeze
    SKELETON_LINES = { lines: 3, avatar: 2, card: 2, media: 0 }.freeze
    # Line widths, in turn, so a block of lines reads as text; the last is short.
    SKELETON_WIDTHS = [100, 94, 86, 97, 90].freeze

    # Grey shapes of the content to come (docs/LOADER.md, "Skeleton"). The
    # wrapper is aria-busy; every shape is hidden from assistive tech, and one
    # line of screen-reader text names the wait. Any html option lands on the
    # wrapper, which is a grid: give it a class for the layout of `count` items.
    #
    #   <%= studio_skeleton %>                                  three lines
    #   <%= studio_skeleton :avatar, count: 4 %>                four list rows
    #   <%= studio_skeleton :card, count: 3, class: "sm:grid-cols-3" %>
    #   <%= studio_skeleton :media %>                           one 16:9 block
    def studio_skeleton(kind = :lines, count: 1, lines: nil, label: "Loading", **html)
      kind = kind.to_s.to_sym
      unless SKELETON_KINDS.include?(kind)
        raise ArgumentError, "studio_skeleton kind must be one of #{SKELETON_KINDS.map(&:inspect).join(', ')} (got #{kind.inspect})"
      end

      render "studio/loader/skeleton",
             kind: kind,
             count: count.to_i.clamp(1, 50),
             lines: (lines.nil? ? SKELETON_LINES[kind] : lines.to_i.clamp(0, 12)),
             label: label,
             html: html
    end

    # The width of line `index` of `total`, as a CSS length.
    def studio_skeleton_width(index, total)
      return "60%" if total > 1 && index == total - 1

      "#{SKELETON_WIDTHS[index % SKELETON_WIDTHS.size]}%"
    end

    # A list that loads its next page as its end comes near (docs/LOADER.md,
    # "Infinite scroll"). The block is one page of items; the view renders the
    # same call for every page, with `page` and the next page's URL (nil on the
    # last). Each later page arrives inside a <turbo-frame> nested in the one
    # before, so the list grows in place; a visible "Load more" link loads it
    # by itself, with the keyboard or with no script.
    #
    #   <%= studio_infinite_scroll id: "posts", page: @page,
    #         next_url: (posts_path(page: @page + 1) if @more) do %>
    #     <% @posts.each do |post| %><%= render post %><% end %>
    #   <% end %>
    def studio_infinite_scroll(id:, page: 1, next_url: nil, more_label: "Load more",
                               end_label: "That is everything", announce: "%{count} more loaded", **html, &block)
      page = [page.to_i, 1].max
      render "studio/loader/infinite_scroll",
             id: id.to_s,
             page: page,
             next_url: next_url.presence,
             more_label: more_label,
             end_label: end_label,
             announce: announce,
             items: capture(&block),
             html: html
    end

    def studio_infinite_scroll_frame_id(id, page) = "#{id}-page-#{page}"

    # Pull the page down from its top to reload it: phones with touch only
    # (docs/LOADER.md, "Pull to refresh"). Wraps the block. With `frame:` it
    # reloads that <turbo-frame>; without, the page, as a replace visit.
    def studio_pull_to_refresh(frame: nil, label: "Refreshing", **html, &block)
      render "studio/loader/pull_to_refresh", frame: frame, label: label, body: capture(&block), html: html
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
