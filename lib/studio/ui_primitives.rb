# frozen_string_literal: true

module Studio
  module UiPrimitives
    EMOJI_SWAP_CSS = <<~CSS
      /* .studio-emoji-box is a plain emoji in the swap's box, so a row with a plain
         emoji and a row with a swap are one height and their labels line up. */
      .studio-emoji-box,
      .studio-emoji-swap,
      .nav-emoji-swap {
        position: relative;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        vertical-align: middle;
        /* In em so a larger glyph fits: at text-lg on a 16px scale a fixed 1.25rem
           box clipped 4px off a 24px emoji. The floor keeps the navbar size. */
        width: max(1.5rem, 1.25em);
        height: max(1.25rem, 1.25em);
        overflow: hidden;
      }

      .studio-emoji-swap > span,
      .nav-emoji-swap > span {
        position: absolute;
        inset: 0;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        transition: transform 240ms cubic-bezier(0.34, 1.2, 0.5, 1), opacity 180ms ease;
      }

      .studio-emoji-swap-base,
      .nav-emoji-base {
        transform: translateX(0);
        opacity: 1;
      }

      .studio-emoji-swap-hover,
      .nav-emoji-hover {
        transform: translateX(-110%);
        opacity: 0;
      }

      .group:hover .studio-emoji-swap-base,
      .group:focus-visible .studio-emoji-swap-base,
      .group:focus-within .studio-emoji-swap-base,
      .group:hover .nav-emoji-base,
      .group:focus-visible .nav-emoji-base,
      .group:focus-within .nav-emoji-base {
        transform: translateX(110%);
        opacity: 0;
      }

      .group:hover .studio-emoji-swap-hover,
      .group:focus-visible .studio-emoji-swap-hover,
      .group:focus-within .studio-emoji-swap-hover,
      .group:hover .nav-emoji-hover,
      .group:focus-visible .nav-emoji-hover,
      .group:focus-within .nav-emoji-hover {
        transform: translateX(0);
        opacity: 1;
      }

      @media (prefers-reduced-motion: reduce) {
        .studio-emoji-swap > span,
        .nav-emoji-swap > span {
          transition: opacity 120ms ease;
        }

        .studio-emoji-swap-base,
        .studio-emoji-swap-hover,
        .nav-emoji-base,
        .nav-emoji-hover,
        .group:hover .studio-emoji-swap-base,
        .group:focus-visible .studio-emoji-swap-base,
        .group:focus-within .studio-emoji-swap-base,
        .group:hover .studio-emoji-swap-hover,
        .group:focus-visible .studio-emoji-swap-hover,
        .group:focus-within .studio-emoji-swap-hover,
        .group:hover .nav-emoji-base,
        .group:focus-visible .nav-emoji-base,
        .group:focus-within .nav-emoji-base,
        .group:hover .nav-emoji-hover,
        .group:focus-visible .nav-emoji-hover,
        .group:focus-within .nav-emoji-hover {
          transform: none;
        }
      }
    CSS

    def self.css
      EMOJI_SWAP_CSS
    end
  end
end
