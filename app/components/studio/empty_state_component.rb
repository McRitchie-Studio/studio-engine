# frozen_string_literal: true

module Studio
  # What a list, a table or a page says when it has nothing to show: an optional
  # icon, the message, an optional line of detail, and at most one action.
  #
  #   render Studio::EmptyStateComponent.new(message: "No errors logged yet.")
  #   render(Studio::EmptyStateComponent.new(detail: "Invite someone to start.")) do |empty|
  #     empty.with_icon { inbox_svg }
  #     empty.with_action(label: "Invite", href: new_invite_path)
  #     "No members yet."
  #   end
  #
  # The action is a Studio::ButtonComponent (with_action takes its keywords), so an
  # empty state cannot grow a hand-made button. One action only: an empty state
  # points at the one next step.
  #
  # Its public surface, which a release changes only with a Breaking line in the
  # changelog (docs/FRONT_END_STANDARD.md, "A primitive's public surface"):
  #   inputs   message: (or the block's content), detail:, framed:, and the
  #            icon and action slots (with_icon, with_action)
  #   classes  .empty-state when framed (the default)
  #   data-*   data-empty-state on the root
  #
  # framed: false drops the .empty-state card for a place that already has a
  # frame: the empty row of Studio::TableComponent.
  #
  # Type is the scale (README "Type scale"): the message at type-body, the detail
  # at type-fine.
  class EmptyStateComponent < ViewComponent::Base
    strip_trailing_whitespace

    FRAMED = "empty-state"
    BARE = "px-4 py-10 text-center"
    MESSAGE = "type-body text-secondary"
    DETAIL = "type-fine text-muted mt-1"
    ICON = "mb-3 inline-flex text-muted"
    ACTION = "mt-4"

    renders_one :icon
    renders_one :action, Studio::ButtonComponent

    attr_reader :detail

    def initialize(message: nil, detail: nil, framed: true)
      super()
      @message = message
      @detail = detail
      @framed = framed ? true : false
    end

    def before_render
      raise ArgumentError, "Studio::EmptyStateComponent needs a message: or a block" if message.blank?
    end

    def message
      content.presence || @message
    end

    def root_classes
      @framed ? FRAMED : BARE
    end
  end
end
