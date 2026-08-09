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
        # Derived by a bounded contrast search, not hardcoded: fixed slate
        # grays fail WCAG on themes whose dark base lifts the surface (a
        # hardcoded #64748b measured 2.14:1 on a navy surface), and any FIXED
        # blend amount is tuned to particular hexes — the operator can pick an
        # arbitrary base in the theme editor. contrast_ink walks the blend up
        # until the ink clears its target on every emitted dark surface
        # (clamped at pure white for pathological bases). Note the blend
        # DESATURATES toward gray; only strongly-tinted bases keep a cast.
        "--color-text-secondary" => contrast_ink(dark_base, direction: :lighten, start: 0.70, target: 4.5,
                                                 against: dark_surfaces(dark_base)),
        "--color-text-muted"     => contrast_ink(dark_base, direction: :lighten, start: 0.55, target: 3.0,
                                                 against: dark_surfaces(dark_base)),
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

    # Every dark-mode background a text var can sit on (page, surface,
    # surface-alt, inset) — the ink must clear its target on ALL of them.
    def dark_surfaces(dark_base)
      [ dark_base,
        ColorScale.lighten(dark_base, 0.15),
        ColorScale.darken(dark_base, 0.14),
        ColorScale.darken(dark_base, 0.43) ]
    end

    def light_surfaces(light_base)
      [ light_base,
        "#ffffff",
        ColorScale.darken(light_base, 0.03),
        ColorScale.darken(light_base, 0.08) ]
    end

    # Bounded, clamped search: raise the blend amount from `start` until the
    # ink clears `target` contrast against every background in `against`.
    # Clamps at 1.0 (pure white/black), so a pathological base degrades to the
    # best achievable ink instead of looping.
    def contrast_ink(base, direction:, start:, target:, against:)
      amount = start
      loop do
        ink = direction == :lighten ? ColorScale.lighten(base, amount) : ColorScale.darken(base, amount)
        return ink if against.all? { |bg| ColorScale.contrast_ratio(ink, bg) >= target } || amount >= 1.0

        amount = [amount + 0.02, 1.0].min
      end
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
        # Same bounded search as dark mode: the old fixed grays measured as
        # low as 2.05:1 (muted on --color-inset) — below the very defect this
        # derivation exists to prevent. Ink darkens away from the light base.
        "--color-text-secondary" => contrast_ink(light_base, direction: :darken, start: 0.55, target: 4.5,
                                                 against: light_surfaces(light_base)),
        "--color-text-muted"     => contrast_ink(light_base, direction: :darken, start: 0.40, target: 3.0,
                                                 against: light_surfaces(light_base)),
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
