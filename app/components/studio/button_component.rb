# frozen_string_literal: true

module Studio
  # The one button every app renders: a <button>, or an <a> when it has an href.
  #
  #   render Studio::ButtonComponent.new(label: "Save")
  #   render Studio::ButtonComponent.new(label: "Delete", tone: :danger, size: :sm)
  #   render Studio::ButtonComponent.new(label: "Docs", tone: :quiet, href: "/docs")
  #   render Studio::ButtonComponent.new(label: "Export", tone: :outline)
  #   render Studio::ButtonComponent.new(label: "Save", type: "submit", loading: true, busy_label: "Saving…")
  #   render(Studio::ButtonComponent.new(label: "New")) { |b| b.with_icon { plus_svg } }
  #
  # It draws the engine's shipped button language and adds none of its own: each
  # tone is a btn-* utility in engine.css and each size is btn-sm, bare btn or
  # btn-lg. An app that retunes --btn-secondary-* or --btn-neutral-* retunes the
  # component with it.
  #
  #   tone        primary    btn-primary    the page's one main action
  #               secondary  btn-secondary  the success role, or the app's retune
  #               quiet      btn-neutral    a second action: Cancel, Back, Next
  #               danger     btn-danger     a destructive action
  #               outline    btn-outline    a bordered, unfilled action on the
  #                                         primary colour; it fills on hover
  #   size        sm  btn-sm · md  btn-md · lg  btn-lg
  #
  # md's label sits on the type scale at body size (btn-md, 1x --type-base); a
  # bare .btn keeps text-sm, so a host's hand-built buttons do not move.
  #
  # Its public surface, which a release changes only with a Breaking line in the
  # changelog (docs/FRONT_END_STANDARD.md, "A primitive's public surface"):
  #   inputs   label: (or the block's content), tone:, size:, href:, type:,
  #            disabled:, loading:, busy_label:, id:, title:, data:, aria:,
  #            and the icon slot (with_icon)
  #   classes  .btn plus the tone's and the size's btn-* classes
  #   aria-*   aria-busy="true" while loading; aria-disabled="true" on a
  #            disabled link
  #
  # LOADING is the engine's aria-busy contract (engine-motion.css, "Pending";
  # Studio::LoaderHelper#studio_loader_pending), not a class of its own. A
  # loading button is aria-busy and disabled, so it is not clickable and keeps
  # its full colour (engine.css, the .btn[aria-busy] rule). A submit button
  # always carries the pending loader, hidden, so a Turbo form that marks itself
  # aria-busy shows it with no script here. The icon is the idle content and
  # gives way to the loader; busy_label: words replace the label while busy.
  # A link cannot be busy, so loading: with href: is refused. A busy FORM hides
  # the icon on every button inside it, not just the submit (engine-motion.css,
  # :where(form, button)[aria-busy] [data-loader-idle]); README, "UI Primitives".
  #
  # Every class string is written out whole: Tailwind finds utilities by scanning
  # source text, and engine.css adds app/components to every host's scan.
  class ButtonComponent < ViewComponent::Base
    # studio_loader_pending, the loader the aria-busy contract shows (the plain
    # spinner at 16px, in the label's colour). Included,
    # not reached through helpers, so the button works in a host whose
    # controllers never mixed the engine's helpers in.
    include Studio::LoaderHelper

    strip_trailing_whitespace

    TONES = {
      primary: "btn-primary",
      secondary: "btn-secondary",
      quiet: "btn-neutral",
      danger: "btn-danger",
      outline: "btn-outline"
    }.freeze

    SIZES = {
      sm: "btn-sm",
      md: "btn-md",
      lg: "btn-lg"
    }.freeze

    TYPES = %w[button submit reset].freeze

    # The gap between icon, loader and label; .btn is already inline-flex.
    LAYOUT = "gap-2"

    # A link has no disabled state of its own, so a disabled link draws it.
    DISABLED_LINK = "opacity-50 cursor-not-allowed"

    renders_one :icon

    attr_reader :href, :busy_label

    def initialize(label: nil, tone: :primary, size: :md, href: nil, type: "button", disabled: false,
                   loading: false, busy_label: nil, id: nil, title: nil, data: {}, aria: {})
      super()
      @tone = fetch_choice(TONES, tone, "tone")
      @size = fetch_choice(SIZES, size, "size")
      raise ArgumentError, "unknown type #{type.inspect}; expected one of #{TYPES.join(', ')}" unless TYPES.include?(type.to_s)
      raise ArgumentError, "Studio::ButtonComponent cannot be loading with an href: a link is never busy" if loading && href

      @label = label
      @href = href
      @type = type.to_s
      @disabled = disabled ? true : false
      @loading = loading ? true : false
      @busy_label = busy_label
      @id = id
      @title = title
      @data = data
      @aria = aria
    end

    def before_render
      raise ArgumentError, "Studio::ButtonComponent needs a label: or a block" if text.blank?
    end

    def link? = href.present?

    def loading? = @loading

    def disabled? = @disabled || @loading

    def text
      content.presence || @label
    end

    def css_classes
      parts = ["btn", TONES.fetch(@tone), SIZES.fetch(@size), LAYOUT]
      parts << DISABLED_LINK if link? && @disabled
      parts.compact.join(" ")
    end

    # The pending loader rides along on a loading button and on every submit
    # button, so the aria-busy contract can show it.
    def pending_loader?
      !link? && (loading? || @type == "submit")
    end

    def element_attributes
      attrs = { class: css_classes, id: @id, title: @title, data: @data.presence }
      aria = @aria.dup
      if link?
        if @disabled
          aria[:disabled] = "true"
          attrs[:role] = "link"
        else
          attrs[:href] = href
        end
      else
        attrs[:type] = @type
        attrs[:disabled] = true if disabled?
        aria[:busy] = "true" if loading?
      end
      attrs[:aria] = aria.presence
      attrs.compact
    end

    private

    def fetch_choice(table, value, name)
      key = value.to_s.to_sym
      return key if table.key?(key)

      raise ArgumentError, "unknown #{name} #{value.inspect}; expected one of #{table.keys.join(', ')}"
    end
  end
end
