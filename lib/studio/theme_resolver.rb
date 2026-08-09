module Studio
  class ThemeResolver
    ROLES = %i[primary dark light success warning danger accent].freeze

    attr_reader :colors

    # colors: hash of role => hex string (e.g. { primary: "#8E82FE", dark: "#1A1535", ... })
    def initialize(colors = {})
      @colors = colors.symbolize_keys
    end

    def to_css
      dark_vars  = dark_mode_vars.map { |k, v| "  #{k}: #{v};" }.join("\n")
      light_vars = light_mode_vars.map { |k, v| "  #{k}: #{v};" }.join("\n")
      palette_vars = primary_palette_vars.map { |k, v| "  #{k}: #{v};" }.join("\n")

      <<~CSS
        :root, .dark {
        #{dark_vars}
        #{palette_vars}
        }

        html:not(.dark) {
        #{light_vars}
        #{palette_vars}
        }
      CSS
    end

    def dark_mode_vars
      dark_base   = colors[:dark] || "#1A1535"
      primary     = colors[:primary] || "#8E82FE"
      border_rgb  = ColorScale.lighten(dark_base, 0.30)

      {
        "--color-page"           => dark_base,
        "--color-surface"        => ColorScale.lighten(dark_base, 0.15),
        "--color-surface-alt"    => ColorScale.darken(dark_base, 0.14),
        "--color-inset"          => ColorScale.darken(dark_base, 0.43),
        "--color-text"           => "#ffffff",
        "--color-text-body"      => "#e2e8f0",
        # Derived, not hardcoded: fixed slate grays fail WCAG on themes whose
        # dark base lifts the surface (a hardcoded #64748b measured 2.14:1 on
        # a navy theme's surface). Lightening the base itself keeps the ink
        # theme-tinted and >= 3:1 (muted) / >= 4.5:1 (secondary) on --color-surface
        # for every dark base in the fleet — property-tested in theme_resolver_test.
        "--color-text-secondary" => ColorScale.lighten(dark_base, 0.70),
        "--color-text-muted"     => ColorScale.lighten(dark_base, 0.55),
        "--color-border"         => ColorScale.with_opacity(border_rgb, 0.2),
        "--color-border-strong"  => ColorScale.with_opacity(border_rgb, 0.4),
        "--color-shadow"         => "transparent",
        "--color-cta"            => primary,
        "--color-cta-hover"      => ColorScale.darken(primary, 0.30),
        "--color-success"        => colors[:success] || "#4BAF50",
        "--color-warning"        => colors[:warning] || "#FF7C47",
        "--color-danger"         => colors[:danger] || "#EF4444",
        "--color-accent"         => colors[:accent] || "#F72585"
      }
    end

    # Generate --color-primary-{50..900} + RGB variants for Tailwind opacity support
    def primary_palette_vars
      primary = colors[:primary] || "#8E82FE"
      scale = ColorScale.generate(primary)
      vars = {}

      scale.each do |shade, hex|
        vars["--color-primary-#{shade}"] = hex
        r, g, b = ColorScale.hex_to_rgb(hex)
        vars["--color-primary-#{shade}-rgb"] = "#{r} #{g} #{b}"
      end

      # DEFAULT aliases
      r, g, b = ColorScale.hex_to_rgb(primary)
      vars["--color-primary"] = primary
      vars["--color-primary-rgb"] = "#{r} #{g} #{b}"

      vars
    end

    def light_mode_vars
      light_base = colors[:light] || "#f8fafc"
      primary    = colors[:primary] || "#8E82FE"

      {
        "--color-page"           => light_base,
        "--color-surface"        => "#ffffff",
        "--color-surface-alt"    => ColorScale.darken(light_base, 0.03),
        "--color-inset"          => ColorScale.darken(light_base, 0.08),
        "--color-text"           => "#0f172a",
        "--color-text-body"      => "#334155",
        "--color-text-secondary" => "#64748b",
        "--color-text-muted"     => "#94a3b8",
        "--color-border"         => ColorScale.darken(light_base, 0.08),
        "--color-border-strong"  => ColorScale.darken(light_base, 0.15),
        "--color-shadow"         => "rgba(0,0,0,0.05)",
        "--color-cta"            => primary,
        "--color-cta-hover"      => ColorScale.darken(primary, 0.30),
        "--color-success"        => colors[:success] || "#4BAF50",
        "--color-warning"        => colors[:warning] || "#FF7C47",
        "--color-danger"         => colors[:danger] || "#EF4444",
        "--color-accent"         => colors[:accent] || "#F72585"
      }
    end
  end
end
