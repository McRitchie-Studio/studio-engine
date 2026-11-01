# frozen_string_literal: true

# The words on the engine's voice capture layer: the microphone chip and its
# help dialog (studio/voice/_microphone_chip, _microphone_help), and the record
# button (studio/voice/_recorder). Ported from Voicebox's MicrophoneHelper and
# RecordingsHelper; the contract is docs/VOICE_CAPTURE.md.
#
# The chip names the microphone the page records from, so a switched-off
# headset Chrome picked on its own is plain to see, and lets the person pick
# another. A host passes `copy:` to either partial to change any line; its
# keys merge over these, one level deep per section.
module Studio
  module VoiceCapture
    # Where the chip remembers the pick (localStorage), unless a partial is given
    # storage_key:. Mirrors STORAGE_KEY in app/javascript/studio/microphone.js.
    STORAGE_KEY = "studio.microphone"

    MICROPHONE_COPY = {
      # Before the person allows the microphone the browser gives no names.
      "prompt" => { "chip" => "Microphone: tap Record to allow",
                    "note" => "Tap Record once and allow the microphone. Then you can pick one here." },
      # The microphone icon says what the name is, so the name gets the whole
      # width at 390px; a screen reader hears "aria" in full.
      "ready" => { "chip" => "%{microphone}", "aria" => "Microphone: %{microphone}. Tap to pick another.",
                   "note" => "Pick the microphone to record with. Your next take uses it." },
      "denied" => { "chip" => "Microphone not allowed",
                    "note" => "This site isn't allowed to use the microphone. Tap the icon beside the web address, " \
                              "set Microphone to Allow, then reload this page." },
      "unsupported" => { "chip" => "No microphone here",
                         "note" => "This browser can't list microphones. Try Safari or Chrome." },
      "fell_back" => "That microphone isn't connected, so I'm using %{microphone}.",
      "empty" => "No microphones found. Plug one in and it shows up here.",
      "in_use" => "In use",
      # The help dialog. Switching happens on the page, by device id, so the
      # dialog never sends anyone to Chrome to switch: Chrome's settings are
      # where the microphone is ALLOWED, and where a person checks it when a
      # take stays silent.
      "help" => {
        "link" => "Help with microphones",
        "title_chrome" => "How to change your microphone in Chrome",
        "title_other" => "How to change your microphone",
        "steps_chrome" => [
          "Click the icon left of the address.",
          "Turn Microphone on.",
          "Make sure your microphone is allowed.",
          "Reload the page."
        ],
        "other" => "Allow the microphone when your browser asks, or in its settings for this site, " \
                   "then pick your microphone here and reload.",
        "unnamed" => "the microphone",
        "switched" => "Switched to %{microphone} ✓",
        "switched_tip_chrome" => "If Chrome asks or it stays silent, here's how to check Chrome's microphone.",
        "switched_tip_other" => "If your browser asks or it stays silent, here's how to check its microphone.",
        "silent" => "I couldn't hear anything from %{microphone}.",
        "silent_tip" => "Pick another microphone in the list, or check that the browser may use it:",
        "denied" => "This site isn't allowed to use the microphone yet.",
        "denied_tip" => "Allow it, then reload:",
        "close" => "Close"
      }
    }.freeze

    # The record button's words per state. Mirrors COPY in
    # app/javascript/studio/voice_recorder.js, which fills any state a page
    # leaves out; the partial renders the idle words so the button reads right
    # before the controller connects.
    RECORDER_COPY = {
      "idle" => { "button" => "Record", "status" => "" },
      "recording" => { "button" => "Stop", "status" => "Listening..." },
      "unavailable" => "Recording didn't load on this page. Reload to try again."
    }.freeze

    module_function

    # The copy with a host's overrides merged in: a Hash section merges key by
    # key, anything else replaces.
    def microphone_copy(overrides = nil)
      merge(MICROPHONE_COPY, overrides)
    end

    def recorder_copy(overrides = nil)
      merge(RECORDER_COPY, overrides)
    end

    def merge(base, overrides)
      return base if overrides.nil? || overrides.empty?

      overrides.to_h.each_with_object(base.dup) do |(key, value), merged|
        key = key.to_s
        merged[key] = merged[key].is_a?(Hash) && value.is_a?(Hash) ? merged[key].merge(value.transform_keys(&:to_s)) : value
      end
    end
  end
end
