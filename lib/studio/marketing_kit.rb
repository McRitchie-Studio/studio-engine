# frozen_string_literal: true

# THE MARKETING KIT (docs/SITE_FOOTER.md, "The marketing kit"): the public page
# at /marketing-kit, with the app's logos, colours and typefaces for anyone to
# use. Studio.marketing_kit declares it, as a Hash or a callable taking the view:
#
#   config.marketing_kit = {
#     tagline:   "Everything, by example",
#     logos:     [ { title: "Icon", light: { png: "/brand/icon-light.png", svg: "/brand/icon-light.svg" },
#                                   dark:  { png: "/brand/icon-dark.png",  svg: "/brand/icon-dark.svg" } } ],
#     palette:   [ { name: "Ink", hex: "#1A1535" } ],
#     typefaces: [ { role: "Headings", family: "Montserrat", weight: 800, name: "Montserrat ExtraBold" } ]
#   }
#
# Every key is optional. A missing `logos` derives from Studio.theme_logos and a
# missing `palette` from Studio.theme_config, so a new app has a working page
# with no setup. The engine knows no typeface or tagline, so those parts are
# simply absent until declared.
#
# A FILE THAT IS NOT THERE IS NOT AN ERROR. Each file is looked for before it is
# linked: a tone with no file has no tile and no link, and a logo with no file
# has no card. So the page shows no broken image, and it does not raise.
#
# `light` means the artwork made for a light background; `dark`, for a dark one.
module Studio
  module MarketingKit
    PATH = "/marketing-kit"
    LABEL = "Marketing Kit"
    CONTROLLER = "studio/marketing_kit"
    ROUTE_NAME = :studio_marketing_kit

    LIGHT_GROUND = "#FFFFFF"
    FALLBACK_DARK_GROUND = "#111827"

    HEX = /\A#(?:\h{3}|\h{4}|\h{6}|\h{8})\z/
    # What may sit inside a style attribute: a family list, and a CSS weight.
    FONT_FAMILY = /\A[\w\s"',.-]+\z/
    FONT_WEIGHT = /\A(?:[1-9]00|normal|bold|lighter|bolder)\z/

    DOWNLOAD_LABELS = { light: "Download Light", dark: "Download Dark" }.freeze
    FORMATS = %i[png svg].freeze

    module_function

    def validate!(declared)
      return if declared.nil? || declared == false || declared.is_a?(Hash) || declared.respond_to?(:call)

      raise ArgumentError,
            "Studio.marketing_kit must be nil (derive it), a Hash, or a callable receiving the view " \
            "(got #{declared.class}). See docs/SITE_FOOTER.md."
    end

    # The kit the page prints.
    #
    #   logos:       Studio.theme_logos, for a kit that declares no `logos`
    #   theme:       Studio.theme_config, for a kit that declares no `palette`
    #   name:        the site's name, for a kit that declares none
    #   dark_ground: the dark tile's background
    #   locate:      a callable answering a file's URL, or nil when it is not there
    def resolve(declared, view, logos: [], theme: {}, name: nil, dark_ground: nil,
                locate: ->(file) { locate(file, view) })
      raw = declared.respond_to?(:call) ? declared.call(view) : declared
      validate!(raw)
      facts = raw ? SiteFooter.symbolize(raw) : {}
      ground = hex(dark_ground) || FALLBACK_DARK_GROUND

      {
        name: SiteFooter.text(facts[:name]) || SiteFooter.text(name),
        tagline: SiteFooter.text(facts[:tagline]),
        logos: logo_cards(facts.key?(:logos) ? facts[:logos] : derived_logos(logos), locate, ground),
        palette: swatches(facts.key?(:palette) ? facts[:palette] : derived_palette(theme)),
        typefaces: typefaces(facts[:typefaces])
      }
    end

    # ---- logos ---------------------------------------------------------------

    # One card per logo that has a file, each with one tile per tone that has one.
    # Two theme entries for one file (a Navbar Logo that is also the Auth Logo)
    # are one card.
    def logo_cards(declared, locate, dark_ground)
      Array(declared).filter_map do |row|
        next unless row.respond_to?(:to_h) && !row.is_a?(Array)

        logo = SiteFooter.symbolize(row)
        tones = { light: LIGHT_GROUND, dark: dark_ground }.filter_map do |tone, ground|
          tile(logo[:title], tone, ground, logo[tone], locate)
        end
        { title: SiteFooter.text(logo[:title]), tones: tones } unless tones.empty?
      end.uniq { |card| card[:tones].map { |tone| tone[:href] } }
    end

    # A download is the PNG when there is one, else the SVG. The tile shows the
    # SVG when there is one, since it stays sharp at any size.
    def tile(title, tone, ground, files, locate)
      found = formats(files).transform_values { |file| locate.call(file) }.compact
      href = found[:png] || found[:svg]
      return nil if href.nil?

      { tone: tone, ground: ground, label: DOWNLOAD_LABELS.fetch(tone), href: href,
        src: tile_src(found[:svg] || found[:png]),
        alt: [SiteFooter.text(title), "for a #{tone} background"].compact.join(", ") }
    end

    # { png:, svg: }, or one path whose extension says which it is.
    def formats(files)
      return SiteFooter.symbolize(files).slice(*FORMATS) if files.is_a?(Hash)
      return {} unless files.is_a?(String)

      format = File.extname(files.split(/[?#]/).first.to_s).delete_prefix(".").downcase.to_sym
      FORMATS.include?(format) ? { format => files } : {}
    end

    # ?kit keeps a tile's tone. A host may repaint its own logo by the image's
    # exact src on a dark page (the hub's `.dark img[src="/brand/icon-light.svg"]`),
    # which would turn the light tile's artwork into the dark one. The download
    # keeps the plain URL.
    def tile_src(url)
      return url if url.match?(%r{\Ahttps?://}i)

      "#{url}#{url.include?('?') ? '&' : '?'}kit"
    end

    # The logos Studio.theme_logos implies. It names one file per logo and says
    # nothing about tone, so the rest is looked for beside it: the same stem as
    # the other format, and a -light/-dark (or _light/_dark) sibling. A stem with
    # no such hint is the light artwork.
    def derived_logos(theme_logos)
      entries = Array(theme_logos).map { |entry| entry.is_a?(Hash) ? SiteFooter.symbolize(entry) : { file: entry } }
      entries.filter_map do |entry|
        file = SiteFooter.text(entry[:file])
        next if file.nil?

        title = SiteFooter.text(entry[:title]) || humanize(file)
        next if title.match?(/favicon/i)

        { title: title }.merge(tone_candidates(file))
      end
    end

    def tone_candidates(file)
      stem = file.delete_suffix(File.extname(file))
      base, separator, hint = stem.match(/\A(.+)([-_])(light|dark)\z/)&.captures

      return { light: both_formats(stem), dark: both_formats("#{stem}-dark") } if hint.nil?

      other = hint == "light" ? "dark" : "light"
      { hint.to_sym => both_formats(stem), other.to_sym => both_formats("#{base}#{separator}#{other}") }
    end

    def both_formats(stem) = { png: "#{stem}.png", svg: "#{stem}.svg" }

    def humanize(file)
      File.basename(file, File.extname(file)).tr("-_", " ").split.map(&:capitalize).join(" ")
    end

    # ---- colours and type ----------------------------------------------------

    def derived_palette(theme)
      theme.to_h.map { |name, value| { name: name.to_s.capitalize, hex: value } }
    end

    # Only a real hex is printed: it goes into a style attribute and the clipboard.
    def swatches(declared)
      Array(declared).filter_map do |row|
        next unless row.respond_to?(:to_h) && !row.is_a?(Array)

        swatch = SiteFooter.symbolize(row)
        value = hex(swatch[:hex])
        { name: SiteFooter.text(swatch[:name]), hex: value } unless value.nil?
      end
    end

    def hex(value)
      string = value.to_s.strip
      string.match?(HEX) ? string : nil
    end

    # A face with no family cannot be shown. A family or weight CSS would not
    # read leaves the specimen in the page's own type, with its label intact.
    def typefaces(declared)
      Array(declared).filter_map do |row|
        next unless row.respond_to?(:to_h) && !row.is_a?(Array)

        face = SiteFooter.symbolize(row)
        family = SiteFooter.text(face[:family])
        next if family.nil?

        { role: SiteFooter.text(face[:role]), family: (family if family.match?(FONT_FAMILY)),
          weight: face[:weight].to_s[FONT_WEIGHT], name: SiteFooter.text(face[:name]) || family }
      end
    end

    # ---- finding a file ------------------------------------------------------

    # The URL of a file, or nil when it is not there. An http(s) URL is taken at
    # its word, since looking would cost the page a network call. A path is
    # looked for in public/; a bare name, then in the asset pipeline.
    def locate(file, view = nil)
      value = SiteFooter.text(file)
      return nil if value.nil?
      return value if value.match?(%r{\Ahttps?://[^\s]+\z}i)
      return nil unless local?(value)

      path = "/#{value.delete_prefix('/')}"
      return path if public_file?(path)

      value.start_with?("/") ? nil : pipeline_path(value, view)
    rescue StandardError
      nil
    end

    # No scheme, no host, no control character and no climbing out of public/.
    def local?(value)
      return false if value.match?(/[\x00-\x1f\x7f\s]/) || value.start_with?("//")
      return false if value.match?(/\A[a-z][a-z0-9+.-]*:/i)

      !value.split(/[?#]/).first.to_s.split("/").include?("..")
    end

    def public_file?(path)
      return false unless defined?(::Rails) && ::Rails.respond_to?(:public_path) && ::Rails.public_path

      File.file?(File.join(::Rails.public_path.to_s, path.split(/[?#]/).first))
    end

    def pipeline_path(name, view)
      return nil unless view.respond_to?(:asset_path) && in_pipeline?(name)

      view.asset_path(name)
    end

    # Propshaft answers through its load path; Sprockets through its environment
    # or, precompiled, its manifest. asset_path alone cannot say: a host may have
    # it fall back to a plain path for a file that is not there.
    def in_pipeline?(name)
      return false unless defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application

      app = ::Rails.application
      assets = app.respond_to?(:assets) ? app.assets : nil
      return !assets.load_path.find(name).nil? if assets.respond_to?(:load_path)
      return !assets.find_asset(name).nil? if assets.respond_to?(:find_asset)

      manifest = app.respond_to?(:assets_manifest) ? app.assets_manifest : nil
      manifest.respond_to?(:assets) && manifest.assets.key?(name)
    end

    # ---- the route -----------------------------------------------------------

    # True when the route set holds a GET of /marketing-kit that is not the
    # engine's: the host's own page, which wins. Asked for every footer on a page
    # that has no engine route, and by the engine route's constraint, so the
    # answer is kept per route set until that set changes size.
    def host_route?(routes)
      table = routes.routes
      known = host_route_memo[routes]
      return known.last if known && known.first == table.size

      answer = table.any? { |route| host_page_route?(route) }
      host_route_memo[routes] = [table.size, answer]
      answer
    end

    def host_route_memo
      @host_route_memo ||= {}.compare_by_identity
    end

    def host_page_route?(route)
      return false if route.defaults[:controller] == CONTROLLER
      return false unless route.path.spec.to_s.delete_suffix("(.:format)") == PATH

      verbs = route.verb.to_s
      verbs.empty? || verbs.split("|").include?("GET")
    end

    # The engine's route gives way to a host route drawn AFTER Studio.routes.
    # (One drawn before it wins by order, and then the engine draws nothing.)
    class YieldToHostRoute
      def initialize(routes) = @routes = routes
      def matches?(_request) = !MarketingKit.host_route?(@routes)
    end

    # Where the footer links: the page's path, or nil when this app has no page.
    def page_path(view, routes)
      return nil if routes.nil?

      SiteFooter.host_path(view, ROUTE_NAME, routes) || (PATH if host_route?(routes))
    rescue StandardError
      nil
    end
  end
end
