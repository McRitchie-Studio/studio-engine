# frozen_string_literal: true

module Studio
  # Every state Studio::ButtonComponent can show: the four tones, the three
  # sizes, a link, an icon, disabled and loading. No @param tags: the gallery
  # takes no input.
  class ButtonComponentPreview < ViewComponent::Preview
    # The four tones, at the default size.
    def tones
      render_with_template(locals: { tones: Studio::ButtonComponent::TONES.keys })
    end

    # The three sizes, in each tone.
    def sizes
      render_with_template(locals: { tones: Studio::ButtonComponent::TONES.keys, sizes: Studio::ButtonComponent::SIZES.keys })
    end

    # Disabled, as a button and as a link, in each tone.
    def disabled
      render_with_template(locals: { tones: Studio::ButtonComponent::TONES.keys })
    end

    # Loading: aria-busy and disabled, the pending loader shown, with and
    # without busy words.
    def loading
      render_with_template(locals: { tones: Studio::ButtonComponent::TONES.keys })
    end

    # An icon before the label, and a link that looks like a button.
    def icon_and_link
      render_with_template
    end
  end
end
