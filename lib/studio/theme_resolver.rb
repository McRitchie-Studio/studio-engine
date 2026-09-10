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
      success     = colors[:success] || "#4BAF50"
      warning     = colors[:warning] || "#FF7C47"
      danger      = colors[:danger] || "#EF4444"
      surfaces    = dark_surfaces(dark_base)

      secondary_ink = contrast_ink(dark_base, direction: :lighten, start: 0.70, target: 4.5, against: surfaces)
      muted_ink     = ladder_clamp(
        contrast_ink(dark_base, direction: :lighten, start: 0.55, target: 4.5, against: surfaces),
        secondary_ink, direction: :lighten
      )

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
        "--color-text-secondary" => secondary_ink,
        # MUTED IS NORMAL-SIZE TEXT, so its target is AA 4.5:1 — not 3.0.
        # 3.0 is WCAG's LARGE-text allowance (>=18.66px, or 14px bold) and this
        # ink does not land on large text: the engine's own `.label-upper`
        # utility is `text-xs text-muted` (12px), and consumers render it at
        # 11px. Measured on the default theme before this change: muted was
        # #9896A4 at 3.84:1 on --color-surface (dark) and #818283 at 3.46:1 on
        # --color-surface-alt (light) — both below AA, in BOTH themes.
        "--color-text-muted"     => muted_ink,
        "--color-border"         => ColorScale.with_opacity(border_rgb, 0.2),
        "--color-border-strong"  => ColorScale.with_opacity(border_rgb, 0.4),
        "--color-shadow"         => "transparent",
        "--color-cta"            => primary,
        "--color-cta-hover"      => ColorScale.darken(primary, 0.30),
        "--color-success"        => success,
        "--color-warning"        => warning,
        "--color-danger"         => danger,
        # THE DANGER *INK*, which is not the danger *colour*. --color-danger is a
        # brand fill (button backgrounds, borders) and is free to be vivid;
        # --color-danger-ink is the same red used as TEXT, where it must clear
        # WCAG AA 4.5:1 on every surface it can land on.
        #
        # No STATIC red clears AA on BOTH themes — measured: text-red-300 is
        # 1.92:1 light / 5.81 dark, text-red-400 2.77 / 4.03, #EF4444 3.76 / 2.96,
        # text-red-600 4.77 / 2.34. So it is DERIVED per theme by the same bounded
        # search that already produces --color-text-secondary and --color-text-muted.
        #
        # start: 0.0 is deliberate — the search tries the operator's actual danger
        # colour FIRST and blends only as far as AA demands, so a theme whose red
        # already passes keeps its exact brand hex.
        #
        # The warning and success inks are the same contract for the other two
        # status roles: their default colours fail AA as text on the light
        # surfaces too. They are found by #status_ink, which also counts the
        # role's own tint as a surface, because they are read inside tinted
        # badges. Danger text is not: it belongs on a theme surface, never on a
        # danger tint (see #status_ink for why that is a rule, not an accident).
        "--color-danger-ink"     => contrast_ink(danger, direction: :lighten, start: 0.0, target: 4.5,
                                                 against: surfaces),
        "--color-warning-ink"    => status_ink(warning, surfaces, direction: :lighten),
        "--color-success-ink"    => status_ink(success, surfaces, direction: :lighten),
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

    # Keep the ink ladder monotonic: muted is the QUIETEST text ink and must
    # never come out louder than secondary.
    #
    # This became reachable the moment muted's target rose to 4.5 and the two
    # inks started sharing one threshold. They are found by the same stepped
    # search from DIFFERENT starts (muted 0.40/0.55, secondary 0.55/0.70), so
    # their grids are offset and the one that starts lower can overshoot PAST
    # the one that starts higher. Measured on the default light base #f8fafc:
    # the true minimum blend clearing 4.5 is 0.59, secondary lands exactly
    # there, and muted — stepping 0.40, 0.42, ... — skips 0.59 and lands on
    # 0.60, i.e. DARKER than secondary. The ladder inverted while every
    # contrast assertion stayed green, because nothing compared the two.
    #
    # Ordering is a design decision, so make it structurally rather than let a
    # 0.02 grid decide it. `direction` says which way "louder" runs: lightened
    # ink on a dark base is louder as luminance RISES; darkened ink on a light
    # base is louder as luminance FALLS.
    def ladder_clamp(muted, secondary, direction:)
      muted_l     = ColorScale.relative_luminance(muted)
      secondary_l = ColorScale.relative_luminance(secondary)
      louder = direction == :lighten ? muted_l > secondary_l : muted_l < secondary_l

      louder ? secondary : muted
    end

    # How strong a status role's tint is where its ink is read on it: the
    # `bg-<role>/10 text-<role>-ink` badge and flash-panel pattern.
    STATUS_TINT = 0.10

    # The warning and success inks land on the page surfaces AND on their own
    # role's tint over each of them (the `bg-warning/10 text-warning-ink`
    # badge). The tint is darker than a light surface and lighter than a dark
    # one, so an ink tuned to the bare surfaces alone came out below AA inside
    # its own badge (default theme: warning 3.91:1 dark, success 4.00:1 dark).
    # Counting the tints as surfaces closes that.
    #
    # --color-danger-ink does NOT go through here, and danger text must not sit
    # on a danger tint: tuned to bare surfaces it measures 4.10:1 (light) and
    # 4.18:1 (dark) on its own 10% tint. Consumers already build on that rule (turf-monster's error
    # contrast guard keeps a control that fails the day danger-ink clears a red
    # tint), so retuning danger-ink is a sequenced change, not a drive-by one.
    # test/views/engine_class_vocabulary_test.rb refuses danger-ink on a danger
    # tint in any engine view.
    def status_ink(role, surfaces, direction:)
      tints = surfaces.map { |bg| ColorScale.blend(role, bg, STATUS_TINT) }
      contrast_ink(role, direction: direction, start: 0.0, target: 4.5, against: surfaces + tints)
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
      success    = colors[:success] || "#4BAF50"
      warning    = colors[:warning] || "#FF7C47"
      danger     = colors[:danger] || "#EF4444"
      surfaces   = light_surfaces(light_base)

      secondary_ink = contrast_ink(light_base, direction: :darken, start: 0.55, target: 4.5, against: surfaces)
      muted_ink     = ladder_clamp(
        contrast_ink(light_base, direction: :darken, start: 0.40, target: 4.5, against: surfaces),
        secondary_ink, direction: :darken
      )

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
        "--color-text-secondary" => secondary_ink,
        # See the dark-mode note: muted is normal-size text and owes AA 4.5:1.
        "--color-text-muted"     => muted_ink,
        "--color-border"         => ColorScale.darken(light_base, 0.08),
        "--color-border-strong"  => ColorScale.darken(light_base, 0.15),
        "--color-shadow"         => "rgba(0,0,0,0.05)",
        "--color-cta"            => primary,
        "--color-cta-hover"      => ColorScale.darken(primary, 0.30),
        "--color-success"        => success,
        "--color-warning"        => warning,
        "--color-danger"         => danger,
        # THE DANGER *INK*, which is not the danger *colour*. --color-danger is a
        # brand fill (button backgrounds, borders) and is free to be vivid;
        # --color-danger-ink is the same red used as TEXT, where it must clear
        # WCAG AA 4.5:1 on every surface it can land on.
        #
        # No STATIC red clears AA on BOTH themes — measured: text-red-300 is
        # 1.92:1 light / 5.81 dark, text-red-400 2.77 / 4.03, #EF4444 3.76 / 2.96,
        # text-red-600 4.77 / 2.34. So it is DERIVED per theme by the same bounded
        # search that already produces --color-text-secondary and --color-text-muted.
        #
        # start: 0.0 is deliberate — the search tries the operator's actual danger
        # colour FIRST and blends only as far as AA demands, so a theme whose red
        # already passes keeps its exact brand hex.
        #
        # The warning and success inks are the same contract for the other two
        # status roles (see the dark-mode note).
        "--color-danger-ink"     => contrast_ink(danger, direction: :darken, start: 0.0, target: 4.5,
                                                 against: surfaces),
        "--color-warning-ink"    => status_ink(warning, surfaces, direction: :darken),
        "--color-success-ink"    => status_ink(success, surfaces, direction: :darken),
        "--color-accent"         => colors[:accent] || "#F72585"
      }
    end
  end
end
