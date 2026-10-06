# frozen_string_literal: true

module Studio
  # A short label in a pill: a count, a repo name, a stage, a status.
  #
  #   render Studio::BadgeComponent.new(text: "3")
  #   render Studio::BadgeComponent.new(text: "passed", tone: :success)
  #   render Studio::BadgeComponent.new(text: "news", scheme: "stage-fresh")
  #
  # Its public surface, which a release changes only with a Breaking line in the
  # changelog (docs/FRONT_END_STANDARD.md, "A primitive's public surface"):
  #   inputs   text:, tone: or scheme:, data_board_count:
  #   classes  .badge plus the tone's or scheme's colour classes
  #   data-*   data-board-count, the studio/board count target (its updateCounts
  #            sets the badge's text)
  #
  # tone: is one of the five status roles every app shares (TONES). Its classes
  # are the hub's status_tone chip, minus the `border` width .badge already sets,
  # so a hub view passes `tone: status_tone_role(status)` and gets the colour the
  # rest of the page uses for that status. Tokens only, so it reads in both themes.
  #
  # scheme: is the palette the components/badge partial took (SCHEMES), including
  # the stage-* pipeline ladder, and renders exactly what that partial rendered.
  # An unknown scheme renders FALLBACK, as the partial did.
  #
  # Pass tone: or scheme:, not both. Neither renders the neutral scheme.
  #
  # Every class string is written out whole: Tailwind finds utilities by scanning
  # source text, and engine.css adds app/components to every host's scan.
  class BadgeComponent < ViewComponent::Base
    strip_trailing_whitespace

    TONES = {
      success: "bg-success/10 text-success-ink border-success/40",
      warning: "bg-warning/10 text-warning-ink border-warning/40",
      danger: "bg-danger/10 text-danger-ink border-danger/40",
      primary: "bg-primary/10 text-heading border-primary/40",
      muted: "bg-surface-alt text-muted border-subtle"
    }.freeze

    SCHEMES = {
      "success" => "bg-mint/10 text-mint border-mint/30",
      "danger" => "bg-red-600/10 text-red-400 border-red-600/30",
      "warning" => "bg-yellow-500/10 text-yellow-400 border-yellow-500/30",
      "info" => "bg-blue-500/10 text-blue-500 border-blue-500/30",
      "violet" => "bg-violet/10 text-violet border-violet/30",
      "primary" => "bg-primary/10 text-primary border-primary/30",
      "orange" => "bg-orange-500/10 text-orange-500 border-orange-500/30",
      "emerald" => "bg-emerald-500/10 text-emerald-500 border-emerald-500/30",
      "gray" => "bg-gray-500/10 text-gray-400 border-gray-500/30",
      # The pipeline ladder News and Content share, first stage to archived.
      "stage-fresh" => "bg-blue-500/10 text-blue-500 border-blue-500/30",
      "stage-shaping" => "bg-yellow-500/10 text-yellow-400 border-yellow-500/30",
      "stage-structured" => "bg-mint/10 text-mint border-mint/30",
      "stage-refined" => "bg-emerald-500/10 text-emerald-500 border-emerald-500/30",
      "stage-cohered" => "bg-violet/10 text-violet border-violet/30",
      "stage-shipped" => "bg-emerald-500/10 text-emerald-500 border-emerald-500/30",
      "stage-closed" => "bg-gray-500/10 text-gray-400 border-gray-500/30",
      "neutral" => "bg-surface-alt text-secondary border-subtle"
    }.freeze

    FALLBACK = "bg-surface-alt text-body border-subtle"

    attr_reader :text, :data_board_count

    def initialize(text:, tone: nil, scheme: nil, data_board_count: nil)
      super()
      raise ArgumentError, "Studio::BadgeComponent takes tone: or scheme:, not both" if tone && scheme
      if tone && !TONES.key?(tone.to_s.to_sym)
        raise ArgumentError, "unknown tone #{tone.inspect}; expected one of #{TONES.keys.join(', ')}"
      end

      @text = text
      @tone = tone&.to_s&.to_sym
      @scheme = scheme
      @data_board_count = data_board_count
    end

    def colour_classes
      return TONES.fetch(@tone) if @tone

      SCHEMES.fetch((@scheme || "neutral").to_s, FALLBACK)
    end
  end
end
