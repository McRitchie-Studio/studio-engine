# frozen_string_literal: true

module Studio
  # Every state Studio::BadgeComponent can show: the five status tones, every
  # legacy scheme including the stage ladder, the neutral default, and the board
  # count hook. No @param tags: the gallery takes no input.
  class BadgeComponentPreview < ViewComponent::Preview
    # The five status roles, as a hub view passes them from status_tone_role.
    def tones
      render_with_template(locals: { tones: Studio::BadgeComponent::TONES.keys })
    end

    # The palette the components/badge partial takes, stage ladder included.
    def schemes
      render_with_template(locals: { schemes: Studio::BadgeComponent::SCHEMES.keys })
    end

    # No tone and no scheme: the neutral scheme.
    def default
      render Studio::BadgeComponent.new(text: "neutral")
    end

    # A board column's count, which studio/board updates through
    # data-board-count.
    def board_count
      render Studio::BadgeComponent.new(text: "12", scheme: "stage-fresh", data_board_count: "fresh")
    end
  end
end
