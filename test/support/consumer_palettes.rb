# frozen_string_literal: true

# The theme colours each consuming app configures in its
# config/initializers/studio.rb, with the engine's own defaults as the first
# case. The chip-ink unit test and the /lab/chips browser page both read this
# one list. A role an app leaves unset falls back to the engine default.
module ConsumerPalettes
  ALL = {
    "engine-default" => {},
    "turf-monster" => { primary: "#2E7D32", success: "#2E7D32", accent: "#8E82FE" },
    "cyvasse" => { primary: "#C08A2E", success: "#367E3A" },
    "mcritchie-industries" => { primary: "#C8661F", dark: "#141516", light: "#FFFFFF",
                                accent: "#59606A", warning: "#F5C518" },
    "moms-app" => { primary: "#E86AA6" }
  }.freeze
end
