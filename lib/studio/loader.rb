# frozen_string_literal: true

# Studio.loader: the branded loader every app draws from its OWN icon and theme
# colours (docs/LOADER.md). Pure Ruby apart from the art reader, so the unit
# suite covers the config without the dummy app.
#
# The config is a style name, or a Hash when the style needs more:
#
#   config.loader = :breathe                                  # the default
#   config.loader = { style: :orbit, icon: "/brand/icon-dark.svg" }
#   config.loader = { style: :sparkle, art: "/brand/loader-sparkle.svg" }
#
# GENERIC styles draw the icon as an image and nothing else, so they work on any
# app with no per-app art: breathe, liquid, orbit, steel.
#
# SIGNATURE styles animate PARTS of the icon, which no image can expose, so the
# app names an ART file: an SVG in the icon's own viewBox holding only the
# animated layers, each marked with data-loader:
#
#   weld_bead   one  <path data-loader="outline" d="..."/>  the line the bead runs
#   sparkle     each <path data-loader="spark" d="..."/>     in the sweep order
#
# The icon is drawn underneath as an image; the art is inlined over it. An art
# file that is missing, outside public/, or has no marked layer falls back to
# breathe, so a typo can never blank the loader.
module Studio
  module Loader
    class InvalidConfig < ArgumentError; end

    SETTING = "Studio.loader"
    GENERIC_STYLES = %i[breathe liquid orbit steel].freeze
    ART_STYLES = { weld_bead: "outline", sparkle: "spark" }.freeze
    STYLES = (GENERIC_STYLES + ART_STYLES.keys).freeze
    DEFAULT_STYLE = :breathe
    KEYS = %i[style icon art].freeze

    # The icon the loader draws when the app names none: the navbar brand's
    # logo, else the theme's "Navbar Logo" (Studio.logo_for), which every app
    # already declares.
    def self.default_icon
      brand = Studio.respond_to?(:navbar_brand) ? Studio.navbar_brand : nil
      (brand && brand[:logo]) || Studio.logo_for("Navbar Logo")
    end

    module_function

    # The config as { style:, icon:, art: } (icon and art nil when not given).
    def normalize(config)
      config = { style: config } if config.is_a?(Symbol) || config.is_a?(String)
      config = { style: DEFAULT_STYLE } if config.nil?
      raise InvalidConfig, "#{SETTING} must be a style Symbol or a Hash (got #{config.class})" unless config.is_a?(Hash)

      config = config.to_h { |key, value| [key.to_sym, value] }
      unknown = config.keys - KEYS
      raise InvalidConfig, "#{SETTING} has unknown key :#{unknown.first} (takes #{KEYS.join(', ')})" if unknown.any?

      style = style!(config[:style] || DEFAULT_STYLE)
      icon = path!(config[:icon], "#{SETTING}[:icon]")
      art = path!(config[:art], "#{SETTING}[:art]")
      if ART_STYLES.key?(style) && art.nil?
        raise InvalidConfig, "#{SETTING} style :#{style} animates parts of the icon, so it needs an art: file " \
                             "(an SVG of <path data-loader=\"#{ART_STYLES[style]}\"> layers; docs/LOADER.md)"
      end

      { style: style, icon: icon, art: art }.freeze
    end

    def style!(value)
      style = value.to_s.strip.tr("-", "_").to_sym
      return style if STYLES.include?(style)

      raise InvalidConfig, "#{SETTING} style must be one of #{STYLES.map(&:inspect).join(', ')} (got #{value.inspect})"
    end

    def path!(value, label)
      return nil if value.nil?
      return value.strip if value.is_a?(String) && !value.strip.empty?

      raise InvalidConfig, "#{label} must be a non-blank path (got #{value.inspect})"
    end

    def art_style?(style) = ART_STYLES.key?(style)

    # ---- The art file ------------------------------------------------------
    #
    # Read from the host's public/ (the path is the URL path the app would serve
    # it at), parsed once per file version. Returns
    #   { view_box: "0 0 w h", width: Float, layers: [Nokogiri::XML::Element] }
    # with only the layers marked for `style`, or nil when there are none.
    @art_cache = {}
    @art_mutex = Mutex.new

    class << self
      attr_reader :art_cache
    end

    def art(path, style, root: public_root)
      mark = ART_STYLES[style]
      file = public_file(path, root)
      return nil unless mark && file

      key = [file, File.mtime(file).to_f, mark]
      Loader.instance_variable_get(:@art_mutex).synchronize do
        Loader.art_cache[key] ||= parse_art(File.read(file), mark)
      end
    rescue SystemCallError
      nil
    end

    def parse_art(source, mark)
      require "nokogiri"
      doc = Nokogiri::XML(source)
      svg = doc.root
      return nil unless svg&.name == "svg"

      layers = doc.xpath("//*[@data-loader='#{mark}']").select { |node| node.name == "path" && node["d"].to_s.strip != "" }
      return nil if layers.empty?

      view_box = svg["viewBox"].to_s.strip
      numbers = view_box.split(/[\s,]+/).map { |n| Float(n, exception: false) }
      return nil unless numbers.size == 4 && numbers.all? && numbers[2].positive? && numbers[3].positive?

      {
        view_box: numbers.map { |n| format_number(n) }.join(" "),
        width: numbers[2],
        layers: layers.map { |node| { d: node["d"].strip, transform: inherited_transform(node) } }.freeze
      }.freeze
    end

    # The transforms of the layer and every group above it, outermost first, so a
    # layer copied out of a <g transform> keeps its place.
    def inherited_transform(node)
      chain = []
      while node.respond_to?(:name) && node.name != "svg" && node.name != "document"
        chain.unshift(node["transform"]) if node["transform"].to_s.strip != ""
        node = node.parent
      end
      chain.empty? ? nil : chain.join(" ")
    end

    def format_number(n) = (n % 1).zero? ? n.to_i.to_s : n.to_s

    def public_root
      defined?(::Rails) && ::Rails.respond_to?(:public_path) && ::Rails.public_path ? ::Rails.public_path.to_s : nil
    end

    # The file behind a public URL path, refusing anything that escapes public/.
    def public_file(path, root)
      return nil if root.nil? || path.nil? || path.match?(%r{\A[a-z]+:}i)

      clean = path.split(/[?#]/).first.to_s.delete_prefix("/")
      full = File.expand_path(clean, root)
      return nil unless full.start_with?(File.expand_path(root) + File::SEPARATOR)

      File.file?(full) ? full : nil
    end
  end
end
