# frozen_string_literal: true

require "test_helper"
require "bigdecimal"
require "action_view"
require "action_controller"
require "nokogiri"
require "active_support/core_ext/object/try"

# [view] The voice capture partials (docs/VOICE_CAPTURE.md) render by name
# through ActionView, and say what the browser modules read: the controller
# identifiers, the storage key, the copy as JSON, the help dialog's steps, and
# the recorder's mode. Behaviour lives in test/javascript/{microphone,
# level_meter,voice_recorder}.test.mjs and e2e/voice_capture.spec.js; this
# proves the partials a consumer renders exist and carry the contract.
class VoiceCaptureRenderTest < Minitest::Test
  def view
    v = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    # A request that answers a host, so a partial printing it would be caught.
    v.define_singleton_method(:request) { Struct.new(:host).new("studio.test") }
    v
  end

  def render(partial, **locals)
    Nokogiri::HTML5.fragment(view.render(partial: partial, locals: locals))
  end

  def test_the_chip_names_its_controller_key_and_copy
    doc = render("studio/voice/microphone_chip")
    root = doc.at_css("[data-studio-controller='microphone-chip']")

    refute_nil root
    assert_equal "prompt", root["data-microphone-state"]
    assert_equal "studio.microphone", root["data-microphone-storage-key"]
    copy = JSON.parse(root["data-microphone-copy"])
    assert_equal Studio::VoiceCapture::MICROPHONE_COPY, copy
    assert_equal "Microphone: tap Record to allow", doc.at_css("[data-microphone-label]").text
    assert_equal "studio-microphone-picker", doc.at_css("[data-microphone-chip]")["aria-controls"]
    refute_nil doc.at_css("#studio-microphone-picker[data-microphone-panel][hidden]")
  end

  def test_the_help_dialog_is_a_native_dialog_with_chrome_steps_and_the_generic_line
    doc = render("studio/voice/microphone_chip", id: "chat-mic")
    dialog = doc.at_css("dialog[data-microphone-dialog]")

    refute_nil dialog
    assert_equal "chat-mic-help-title", dialog["aria-labelledby"]
    assert_equal 4, dialog.css("[data-microphone-help-steps] li").size
    assert_includes dialog.at_css("[data-microphone-help-other]").text, "Allow the microphone"
    refute_includes dialog.to_html, "studio.test", "the drawing never prints the request's host"
    refute_nil dialog.at_css("svg.studio-mic-mock rect.mock-address"), "the address is a drawn bar"
    assert_equal "dialog", dialog.at_css("form")["method"]
  end

  def test_a_host_overrides_the_words_and_the_key
    doc = render("studio/voice/microphone_chip", storage_key: "voicebox.microphone",
                                                 copy: { "prompt" => { "chip" => "Mic: tap Talk" }, "in_use" => "Using" })
    root = doc.at_css("[data-studio-controller='microphone-chip']")
    copy = JSON.parse(root["data-microphone-copy"])

    assert_equal "voicebox.microphone", root["data-microphone-storage-key"]
    assert_equal "Mic: tap Talk", copy.dig("prompt", "chip")
    assert_equal Studio::VoiceCapture::MICROPHONE_COPY.dig("prompt", "note"), copy.dig("prompt", "note"), "the rest of the section stands"
    assert_equal "Using", copy["in_use"]
    assert_equal "Mic: tap Talk", doc.at_css("[data-microphone-label]").text
  end

  def test_the_recorder_names_its_controller_mode_and_limit
    doc = render("studio/voice/recorder", id: "chat-recorder", mode: "hold", max_ms: 30_000,
                                         copy: { "idle" => { "button" => "Hold to talk" } })
    root = doc.at_css("[data-studio-controller='voice-recorder']")

    assert_equal "chat-recorder", root["id"]
    assert_equal "hold", root["data-voice-recorder-mode"]
    assert_equal "30000", root["data-voice-recorder-max-ms"]
    assert_equal "Hold to talk", JSON.parse(root["data-voice-recorder-copy"]).dig("idle", "button")
    refute JSON.parse(root["data-voice-recorder-copy"]).key?("unavailable"), "the failure line is the page's, not the module's"
    assert_equal "Hold to talk", doc.at_css("[data-voice-recorder-label]").text
    refute_nil doc.at_css("button[data-voice-recorder-button][aria-pressed='false']")
  end

  def test_the_recorder_defaults_to_toggle_and_refuses_an_unknown_mode
    root = render("studio/voice/recorder", mode: "shout").at_css("[data-studio-controller='voice-recorder']")

    assert_equal "toggle", root["data-voice-recorder-mode"]
    assert_equal "60000", root["data-voice-recorder-max-ms"]
    assert_nil root["id"]
  end

  # Every colour in the scoped CSS is a theme token (a literal only as a var()
  # fallback), and every control is at least 44px tall.
  def test_the_styles_use_theme_tokens_and_44px_targets
    styles = view.render(partial: "studio/voice/styles")[/<style>(.*?)<\/style>/m, 1]

    refute_nil styles
    assert_includes styles, "var(--color-primary-500-rgb"
    assert_includes styles, "var(--color-cta-fill, var(--color-cta"
    %w[.studio-mic-chip .studio-mic-option .studio-mic-help-link .studio-recorder-button .studio-mic-help-close].each do |selector|
      rule = styles[/#{Regexp.escape(selector)}\s*\{[^}]*\}/]
      assert_match(/min-height:\s*44px/, rule.to_s, "#{selector} is a 44px tap target")
    end
    %w[.studio-mic-option .studio-mic-help-link].each do |selector|
      ring = styles[/#{Regexp.escape(selector)}:focus-visible[^{]*\{[^}]*\}/]
      assert_match(/outline:\s*3px solid rgb\(var\(--color-primary-500-rgb/, ring.to_s, "#{selector} has the 3px token focus ring")
    end
    bare = styles.scan(/(?<!, )#[0-9a-f]{3,6}\b/i)
    assert_empty bare, "a hex colour outside a var() fallback: #{bare.inspect}"
  end

  def test_the_copy_merge_is_one_level_deep_and_leaves_the_constant_alone
    merged = Studio::VoiceCapture.microphone_copy(help: { close: "Done" })

    assert_equal "Done", merged.dig("help", "close")
    assert_equal "Help with microphones", merged.dig("help", "link")
    assert_equal "Close", Studio::VoiceCapture::MICROPHONE_COPY.dig("help", "close")
    assert_same Studio::VoiceCapture::MICROPHONE_COPY, Studio::VoiceCapture.microphone_copy(nil)
    assert_equal "studio.microphone", Studio::VoiceCapture::STORAGE_KEY
  end

  # The Ruby key and the browser's default are one value.
  def test_the_storage_key_matches_the_browser_module
    source = File.read("app/javascript/studio/microphone.js")

    assert_includes source, %(export const STORAGE_KEY = "#{Studio::VoiceCapture::STORAGE_KEY}")
  end
end
