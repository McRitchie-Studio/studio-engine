# frozen_string_literal: true

require "bundler/setup"

require "minitest/autorun"
require_relative "../../../app/helpers/studio/fizz_helper"

# [unit] The bubble table behind the hold-to-confirm button's fizz.
#
# The invariants that make the effect work at all:
#   * it is DETERMINISTIC per seed — a runtime scatter would differ from the
#     page Turbo cached, and could not be asserted on anywhere;
#   * every bubble stays inside its own ZONE, so a six-item palette reads as six
#     things standing around the button rather than one bag of confetti;
#   * the two layers split each zone's three colour slots without overlapping;
#   * an unbound slot still paints — the fallback hue is the whole reason a host
#     that binds nothing still sees the effect.
class Studio::FizzHelperTest < Minitest::Test
  include Studio::FizzHelper

  def test_the_scatter_is_stable_per_seed_and_differs_between_seeds
    assert_equal fizz_bits("desktop"), fizz_bits("desktop"),
      "the same seed must produce the identical scatter on every render"
    refute_equal fizz_bits("desktop"), fizz_bits("mobile"),
      "two buttons on one page should not fizz in lockstep"
  end

  def test_every_bubble_carries_a_full_animation_table
    bits = fizz_bits("desktop")

    assert_equal Studio::FizzHelper::ZONES * 5, bits.size, "five bubbles per zone"
    bits.each do |bit|
      assert_includes 0..100, bit[:x], "x is a percentage inside the button"
      assert_includes 0..100, bit[:y], "y is a percentage inside the button"
      assert bit[:size].positive?, "a bubble needs a size"
      assert bit[:duration].positive?, "a bubble needs a cycle"
      assert bit[:delay] >= 0, "delay must not be negative"
      assert_includes Studio::FizzHelper::HUES, bit[:hue], "the fallback hue comes from the set"
    end
  end

  def test_each_zone_keeps_to_its_own_corner_of_the_button
    span = 100.0 / Studio::FizzHelper::ZONE_COLUMNS
    bits = fizz_bits("desktop")

    assert_equal (1..Studio::FizzHelper::ZONES).to_a, bits.map { |b| b[:zone] }.uniq.sort
    bits.group_by { |b| b[:zone] }.each do |zone, zone_bits|
      row = (zone - 1) / Studio::FizzHelper::ZONE_COLUMNS
      col = (zone - 1) % Studio::FizzHelper::ZONE_COLUMNS
      side_spray = zone_bits.select { |b| b[:dx].abs > 8 }

      (zone_bits - side_spray).each do |bit|
        assert_operator bit[:x], :>=, col * span, "zone #{zone} drifted left of its column"
        assert_operator bit[:x], :<=, (col + 1) * span, "zone #{zone} drifted right of its column"
      end
      zone_bits.each do |bit|
        if row.zero?
          assert_operator bit[:y], :<, 50, "zone #{zone} belongs to the top edge"
          assert_operator bit[:dy], :<, 0, "a top-row bubble rises"
        else
          assert_operator bit[:y], :>, 50, "zone #{zone} belongs to the bottom edge"
          assert_operator bit[:dy], :>, 0, "a bottom-row bubble falls"
        end
      end
    end
  end

  def test_the_layers_split_each_zones_three_slots
    base = fizz_bits("desktop", layer: :base)
    hover = fizz_bits("desktop~extra", layer: :hover)

    assert_equal [ 1, 4, 7, 10, 13, 16 ], base.map { |b| b[:slot] }.uniq.sort,
      "the resting layer wears the first colour of each zone"
    assert_equal [ 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18 ], hover.map { |b| b[:slot] }.uniq.sort,
      "the hover layer alternates the second and third"
    assert_empty base.map { |b| b[:slot] } & hover.map { |b| b[:slot] },
      "a colour belongs to one layer or the other, never both"

    (base + hover).each do |bit|
      assert_equal bit[:zone],
        ((bit[:slot] - 1) / Studio::FizzHelper::COLORS_PER_ZONE) + 1,
        "a bubble must wear the colours of the zone it sits in"
    end
  end

  def test_an_unbound_slot_still_paints
    bit = fizz_bits("desktop").first

    assert_equal "var(--fizz-c-#{bit[:slot]}, hsl(#{bit[:hue]} 92% 70%))", fizz_color(bit)
    style = fizz_bit_style(bit)
    %w[left: top: --fs: --fx: --fy: --fd: --ft: --fc:].each do |prop|
      assert_includes style, prop, "every bubble needs #{prop}"
    end
  end
end
