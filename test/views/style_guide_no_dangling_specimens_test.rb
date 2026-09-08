# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"

# [unit] Every specimen the guide registers must have a card, and every card a
# registration. This is the failure the graduation SOP names outright: "One
# without the other is a card that opens nothing, or a modal nobody can reach
# from the guide."
#
# It is written as a PAIRING check rather than a list of known ids on purpose.
# A list would have to be edited by the very change most likely to break the
# pairing, so it would pass by being updated. This derives both sides from the
# file and compares them, so removing half of a specimen fails without anyone
# remembering this test exists.
class StyleGuideNoDanglingSpecimensTest < Minitest::Test
  SECTION = "app/views/style/_modals.html.erb"

  def setup
    @src = File.read(SECTION)
  end

  # Ids the page REGISTERS content for — the <template x-if> branches.
  def registered
    @src.scan(/dsModals\.current\(\)\.id === '([a-z0-9-]+)'/).flatten.uniq
  end

  # Ids the page OPENS from a card's trigger.
  #
  # TWO FORMS, and missing the second is the trap this method exists to document.
  # Most cards write the id as a literal. The Templates section writes ONE card in
  # a loop and interpolates — `"$store.dsModals.open('#{id}')"` — so a literal-only
  # scan reports all five template ids as registered-but-unreachable, which is
  # exactly what the first version of this test claimed. They are reachable; the
  # regex could not see them. So the ids feeding such a loop are collected from
  # its array literal as well.
  def opened
    literal      = @src.scan(/dsModals\.open\('([a-z0-9-]+)'/).flatten
    interpolated = if @src.include?(%q{dsModals.open('#{id}')})
                     @src.scan(/^\s*\["([a-z0-9-]+)",/).flatten
                   else
                     []
                   end
    (literal + interpolated).uniq
  end

  def test_every_opened_id_has_a_registration
    orphans = opened - registered

    assert_empty orphans,
                 "these ids are opened by a card but registered by no template — each would " \
                 "open an EMPTY panel: #{orphans.join(', ')}"
  end

  def test_every_registration_is_reachable_from_a_card
    unreachable = registered - opened

    assert_empty unreachable,
                 "these ids are registered but no card opens them — a modal nobody can reach " \
                 "from the guide: #{unreachable.join(', ')}"
  end

  def test_the_retired_mirrors_are_gone_from_both_sites
    # The five that moved to turf's own host section. Named explicitly because
    # their absence is the POINT of this change, and the pairing checks above
    # would stay green if a pair of them were reinstated together.
    %w[wallet-setup wallet-changed ds-cdp-ramp ds-buy-entry-token cosign-rejected].each do |id|
      refute_includes registered, id, "#{id} is a turf card; the guide should not mirror it"
      refute_includes opened, id, "#{id} is a turf card; the guide should not card it"
      refute File.exist?("app/views/style/modals/_#{id.tr('-', '_').sub(/\Ads_/, 'ds_')}.html.erb"),
             "#{id}'s specimen file survived the deletion"
    end
  end
end
