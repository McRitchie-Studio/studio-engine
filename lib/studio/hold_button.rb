# frozen_string_literal: true

module Studio
  # The locals studio/_hold_button no longer takes. Each carried JavaScript as a
  # string for the browser to evaluate; a page answers the event instead.
  module HoldButton
    # Local => the event that answers now. The browser's half of this table is
    # REMOVED_HOOKS in app/javascript/studio/hold_button_hooks.js.
    REMOVED_LOCALS = {
      guard: "hold-button:guard",
      on_hold_start: "hold-button:start",
      validate: "hold-button:validate",
      early_action: "hold-button:early",
      early_action_guard: "hold-button:early",
      on_success: "hold-button:success"
    }.freeze

    module_function

    # Raises when a caller passes a removed local, in every environment: a
    # button rendered without the check its caller asked for must not reach a
    # page.
    def refuse_removed_locals!(locals)
      passed = REMOVED_LOCALS.select { |name, _| !locals[name].nil? }
      return if passed.empty?

      named = passed.map { |name, event| "#{name}: (answer #{event})" }.join(", ")
      raise ArgumentError, "studio/hold_button no longer evaluates JavaScript-string locals. Remove #{named}. " \
                           "The events are listed at the top of app/views/studio/_hold_button.html.erb."
    end
  end
end
