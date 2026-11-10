# frozen_string_literal: true

module Studio
  # Every state Studio::EmptyStateComponent can show: the message alone, with
  # detail, with an icon and an action, and bare (inside a frame of its own).
  # No @param tags: the gallery takes no input.
  class EmptyStateComponentPreview < ViewComponent::Preview
    # The message alone: what the components/empty_state partial renders.
    def message
      render Studio::EmptyStateComponent.new(message: "No errors logged yet.")
    end

    # A message and one line of detail.
    def with_detail
      render Studio::EmptyStateComponent.new(message: "No errors logged yet.",
                                             detail: "Errors appear here when ErrorLog.capture! records one.")
    end

    # An icon, the message, the detail and the one action.
    def with_icon_and_action
      render_with_template
    end

    # Without the card, for a place that has its own frame.
    def bare
      render Studio::EmptyStateComponent.new(message: "Nothing matches that filter.", framed: false)
    end
  end
end
