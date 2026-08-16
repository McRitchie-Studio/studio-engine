# frozen_string_literal: true

module Studio
  # The bubble table behind the hold-to-confirm button's fizz layers.
  #
  # The CodePen this adapts scattered its particles with Sass `random()` at
  # compile time. There is no Sass here, and a runtime `rand` would re-scatter
  # the bubbles on every render — which fights Turbo's page cache (a restored
  # page would not match the one it replaced) and leaves the markup untestable.
  # So the scatter is SEEDED: stable for a given button across renders, and
  # different between two buttons on one page.
  #
  # ZONES. The button is cut into a 3x2 grid — three zones along the top edge,
  # three along the bottom, numbered left to right, top row first. A bubble only
  # ever wears the colours of the zone it sits in, so a six-item palette reads as
  # six things standing around the button rather than one shaken bag of confetti.
  # The outer columns also own the spray off the left and right sides, each
  # within its own half.
  #
  # COLOURS. Each zone carries three slots — 1..18 across the six zones — and the
  # two layers split them: the resting layer wears the FIRST of its zone's three,
  # and the layer that fades in on hover alternates the second and third. A
  # caller binds them as `--fizz-c-1..18` on the stack (turf-monster's board maps
  # the six picked teams' light / dark / alt colours onto them, in pick order);
  # anything unbound falls back to the bubble's own hue, so the effect is never
  # colourless.
  module FizzHelper
    # Candy hues a bubble falls back to. Deliberately narrow — the source
    # material spanned the whole wheel and read as confetti.
    HUES = [ 262, 276, 292, 318, 336, 190, 168, 46 ].freeze

    ZONE_COLUMNS = 3
    ZONE_ROWS = 2
    ZONES = ZONE_COLUMNS * ZONE_ROWS
    COLORS_PER_ZONE = 3
    SLOTS = ZONES * COLORS_PER_ZONE

    # Which of its zone's three slots a layer's bubbles take.
    LAYER_OFFSETS = {
      base: [ 0 ].freeze,     # the first colour
      hover: [ 1, 2 ].freeze  # the second and third, alternating
    }.freeze

    # One layer's bubbles. Each is a hash the partial writes out as inline
    # custom properties: x/y place it (%), dx/dy are the drift it travels before
    # fading (dy negative = rises off the top edge), size is px, delay and
    # duration are seconds, hue is its fallback colour, zone and slot are its
    # place in the palette.
    def fizz_bits(seed, layer: :base, per_zone: 5)
      offsets = LAYER_OFFSETS.fetch(layer)
      prng = Random.new(seed.to_s.each_byte.sum * 7919 + per_zone)

      ZONES.times.flat_map do |zone|
        Array.new(per_zone) do |i|
          fizz_zone_bit(prng, zone: zone, index: i).merge(
            zone: zone + 1,
            slot: (zone * COLORS_PER_ZONE) + offsets[i % offsets.size] + 1
          )
        end
      end
    end

    # One bubble's colour: its slot's bound colour, else its own hue.
    def fizz_color(bit)
      "var(--fizz-c-#{bit[:slot]}, hsl(#{bit[:hue]} 92% 70%))"
    end

    # The inline style one bubble carries. Kept here rather than in the partial
    # so the property names and the CSS that reads them stay in one place.
    def fizz_bit_style(bit)
      "left:#{bit[:x]}%;top:#{bit[:y]}%;" \
        "--fs:#{bit[:size]}px;--fx:#{bit[:dx]}px;--fy:#{bit[:dy]}px;" \
        "--fd:#{bit[:delay]}s;--ft:#{bit[:duration]}s;--fc:#{fizz_color(bit)}"
    end

    private

    # Where in its own zone a bubble sits. The outer columns each throw one
    # bubble off the side of the button, kept in their own half so the top-left
    # zone never sprays into the bottom-left one.
    def fizz_zone_bit(prng, zone:, index:)
      row = zone / ZONE_COLUMNS # 0 = the top edge, 1 = the bottom
      col = zone % ZONE_COLUMNS

      return fizz_side_bit(prng, :left, row) if index.zero? && col.zero?
      return fizz_side_bit(prng, :right, row) if index.zero? && col == ZONE_COLUMNS - 1

      x = fizz_zone_x(prng, col)
      row.zero? ? fizz_top_bit(prng, x) : fizz_bottom_bit(prng, x)
    end

    def fizz_zone_x(prng, col)
      span = 100.0 / ZONE_COLUMNS
      inset = span * 0.06 # breathing room, so neighbouring zones do not touch
      (col * span + inset + prng.rand(span - (inset * 2))).round(1)
    end

    def fizz_top_bit(prng, x)
      fizz_bit(prng, x: x, y: 2 + prng.rand(12),
                     dx: prng.rand(-8..8), dy: -(12 + prng.rand(24)))
    end

    def fizz_bottom_bit(prng, x)
      fizz_bit(prng, x: x, y: 86 + prng.rand(12),
                     dx: prng.rand(-8..8), dy: 12 + prng.rand(24))
    end

    def fizz_side_bit(prng, side, row)
      reach = 10 + prng.rand(18)
      fizz_bit(prng,
               x: side == :left ? prng.rand(5) : 95 + prng.rand(5),
               y: row.zero? ? 14 + prng.rand(30) : 56 + prng.rand(30),
               dx: side == :left ? -reach : reach,
               dy: row.zero? ? -(2 + prng.rand(10)) : 2 + prng.rand(10))
    end

    def fizz_bit(prng, x:, y:, dx:, dy:)
      { x: x, y: y, dx: dx, dy: dy,
        size: 2 + prng.rand(5),
        delay: (prng.rand(180) / 100.0).round(2),
        duration: (1.4 + prng.rand(120) / 100.0).round(2),
        hue: HUES[prng.rand(HUES.size)] }
    end
  end
end
