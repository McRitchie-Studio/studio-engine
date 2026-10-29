# frozen_string_literal: true

module Studio
  # THE TYPE SCALE — the one set of text sizes every Studio app draws from
  # (task engine-type-scale-roles). Alex McRitchie ruled it the standard for
  # every app on 2026-10-28; the hub's /logos/<brand> Type Scale card shows the
  # same multiples per brand.
  #
  # Each role is a multiple of one base: title 6x, heading 3x, subhead 1.5x,
  # body 1x, fine print 0.75x. engine.css draws the roles as the utilities
  # `type-title`, `type-heading`, `type-subhead`, `type-body` and `type-fine`
  # (not `text-heading` / `text-body`: those are colour utilities).
  #
  # An app has TWO bases:
  #   Studio.type_base        (16) public and marketing pages: 96/48/24/16/12
  #   Studio.type_dense_base  (14) admin and ops pages, under a `type-dense`
  #                                container: 84/42/21/14/10.5
  # The ratios never change; a page picks its base by where it sits.
  #
  # This module emits the per-app variables the utilities read, in the theme
  # tag (StudioThemeHelper#studio_theme_css_tag):
  #
  #   Studio::TypeScale.css
  #   # => ":root {\n  --type-base: 16px;\n  --type-dense-base: 14px; ..."
  module TypeScale
    # [utility, multiple, weight] — weight :display or :text picks the app's
    # Studio.type_display_weight or Studio.type_text_weight.
    ROLES = [
      ["type-title", 6, :display],
      ["type-heading", 3, :display],
      ["type-subhead", 1.5, :text],
      ["type-body", 1, :text],
      ["type-fine", 0.75, :text]
    ].freeze

    WEIGHTS = (100..900).step(100).to_a.freeze

    def self.css
      <<~CSS
        :root {
          --type-base: #{px(Studio.type_base, 'type_base')};
          --type-dense-base: #{px(Studio.type_dense_base, 'type_dense_base')};
          --type-display-weight: #{weight(Studio.type_display_weight, 'type_display_weight')};
          --type-text-weight: #{weight(Studio.type_text_weight, 'type_text_weight')};
        }
      CSS
    end

    # The sizes a base gives, in pixels, largest first.
    def self.sizes(base) = ROLES.to_h { |utility, multiple, _| [utility, base * multiple] }

    def self.px(value, setting)
      raise ArgumentError, "Studio.#{setting} must be a positive number of pixels, got #{value.inspect}" unless value.is_a?(Numeric) && value.positive?

      "#{value.to_s.delete_suffix('.0')}px"
    end

    def self.weight(value, setting)
      raise ArgumentError, "Studio.#{setting} must be one of #{WEIGHTS.join(', ')}, got #{value.inspect}" unless WEIGHTS.include?(value)

      value.to_s
    end
  end
end
