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
  SECTION   = "app/views/style/_modals.html.erb"
  SPECIMENS = "app/views/style/modals"

  def setup
    @src = File.read(SECTION)
  end

  # ERB comments never reach the page, so they are stripped before any scan.
  #
  # THIS IS LOAD-BEARING, not tidiness. The section and its specimens DISCUSS
  # modal ids in prose — including ids this guide deliberately no longer
  # registers, because saying why one left is how the next reader learns not to
  # put it back. Scanning a comment reports a sentence as a call, so the guard
  # would fail on the very note explaining the deletion it exists to enforce.
  def strip_erb_comments(source)
    source.gsub(/<%#.*?%>/m, "")
  end

  # Ids the page REGISTERS content for — the <template x-if> branches.
  def registered
    strip_erb_comments(@src).scan(/dsModals\.current\(\)\.id === '([a-z0-9-]+)'/).flatten.uniq
  end

  # Ids the page OPENS from a card's trigger.
  #
  # THREE FORMS, and every one of them was added because a literal-only scan
  # called a reachable card unreachable. That is this method's whole subject:
  # "reachable" is a property of the PAGE, and the page names ids three ways.
  #
  #   1. LITERAL — most cards: `$store.dsModals.open('birthday', …)`.
  #   2. INTERPOLATED — the Templates section writes ONE card in a loop,
  #      `"$store.dsModals.open('#{id}')"`, so a literal-only scan reported all
  #      five template ids as registered-but-unreachable. They were reachable;
  #      the regex could not see them. The ids feeding that loop are collected
  #      from its array literal instead.
  #   3. VIA A DECLARED CONSTANT (added 2026-09-09) — the stack-behaviour drivers
  #      open one vehicle from a dozen places, so they declare it once
  #      (`var VEHICLE = 'ds-stack-demo';`) and call `store().open(VEHICLE, …)`.
  #      Same trap as form 2 with a different indirection: the id is in the file,
  #      it is just not at the call site. Read the declaration.
  #
  # WHAT THIS DELIBERATELY DOES NOT DO is treat a swap() target as reachable.
  # A swap is one card handing off to another MID-FLOW, so it proves the second
  # card can be reached ONLY IF the first one can — and #test_every_swap_target_
  # has_a_registration already holds that end. Folding swaps in here would let a
  # pair of cards that swap to each other, with no trigger into either, satisfy
  # both tests at once.
  def opened
    body         = strip_erb_comments(@src)
    literal      = body.scan(/dsModals\.open\('([a-z0-9-]+)'/).flatten
    interpolated = if body.include?(%q{dsModals.open('#{id}')})
                     body.scan(/^\s*\["([a-z0-9-]+)",/).flatten
                   else
                     []
                   end
    via_const = body.scan(/var\s+([A-Z_]+)\s*=\s*'([a-z0-9-]+)';/).filter_map { |name, id|
      id if body.match?(/\.open\(\s*#{Regexp.escape(name)}\b/)
    }
    (literal + interpolated + via_const).uniq
  end

  # Ids a specimen hands off to MID-FLOW, with swap() rather than open().
  #
  # THE HOLE THIS CLOSES, and it was open until 2026-09-09. A swap is one card
  # opening another, and it fails exactly as an unregistered trigger does — an
  # empty panel — but it is written INSIDE a specimen partial rather than in the
  # section, so neither check above could ever see it. When the goodbye mirror
  # was retired, style/modals/_unsubscribe_confirm went on swapping to
  # 'unsubscribe-goodbye': every test in this suite stayed green, every card
  # still rendered, and pressing Unsubscribe opened nothing. Read the specimens.
  # TWO SPELLINGS OF THE SAME CALL, and reading only one left this guard blind
  # for the whole window it was supposed to be closing. MEASURED 2026-09-09 by
  # dangling a real swap target and watching this file stay green:
  #
  #   $store.dsModals.swap('ds-success')            <- seen by the old regex
  #   Alpine.store('dsModals').swap('ds-stack-demo')  <- NOT seen
  #
  # The second is what a specimen writes from inside a heredoc'd x-data, where
  # `$store` is not in scope — so the form this missed is the form used by the
  # partials that hand off MID-FLOW, which is precisely the case this guard
  # exists for. `dsModals\.swap` cannot match `dsModals').swap`; the store name
  # and the method are separated by the close of Alpine.store's own call.
  #
  # Anchored on the store NAME either way rather than a bare /\.swap\(/, so an
  # unrelated swap on some other object cannot enter the set.
  SWAP_CALL = /dsModals(?:'\s*\))?\.swap\(\s*'([a-z0-9-]+)'/

  def swapped
    sources = [SECTION] + Dir["#{SPECIMENS}/*.html.erb"].sort
    sources.flat_map { |file|
      strip_erb_comments(File.read(file)).scan(SWAP_CALL).flatten
    }.uniq
  end

  def test_every_opened_id_has_a_registration
    orphans = opened - registered

    assert_empty orphans,
                 "these ids are opened by a card but registered by no template — each would " \
                 "open an EMPTY panel: #{orphans.join(', ')}"
  end

  def test_every_swap_target_has_a_registration
    # Asserted ONE WAY on purpose. A swap target must be registered, but it need
    # not have a card of its own: a mid-flow beat legitimately arrives only from
    # the card before it. The reverse check below stays scoped to open(), so
    # folding swaps into it would let a swap-only id satisfy "reachable from a
    # card" and quietly weaken the guard next door.
    orphans = swapped - registered

    assert_empty orphans,
                 "these ids are handed off to by a specimen's swap() but registered by no " \
                 "template — the handoff opens an EMPTY panel: #{orphans.join(', ')}"
  end

  def test_the_specimen_scan_is_not_empty
    # The control for the test above. A swap() guard that reads an empty file
    # list passes forever, and the two ways it silently goes empty — a renamed
    # directory, a run from the wrong working directory — both look exactly like
    # "no dangling handoffs".
    refute_empty Dir["#{SPECIMENS}/*.html.erb"],
                 "no specimen partials found under #{SPECIMENS} — the swap guard above " \
                 "would pass vacuously"
    refute_empty swapped,
                 "no specimen swaps anywhere on this guide — either the handoff idiom " \
                 "changed or the scan is reading the wrong thing"
  end

  def test_every_registration_is_reachable_from_a_card
    unreachable = registered - opened

    assert_empty unreachable,
                 "these ids are registered but no card opens them — a modal nobody can reach " \
                 "from the guide: #{unreachable.join(', ')}"
  end

  def test_the_retired_mirrors_are_gone_from_both_sites
    # The mirrors that moved to turf's own host section. Named explicitly because
    # their absence is the POINT of this change, and the pairing checks above
    # would stay green if a pair of them were reinstated together.
    #
    # THREE BATCHES, in ONE list rather than a list per batch: the reason each id
    # left is identical, and a per-batch list is the list that gets forgotten by
    # the batch which adds no test. Batch 1 landed 2026-09-08, batches 2 and 3 on
    # 2026-09-09. BATCH 3 IS THE LAST — after it the guide holds no mirror of a
    # consumer's card at all, so an id appended below from here on is a NEW
    # mistake rather than one more of the same.
    %w[wallet-setup wallet-changed ds-cdp-ramp ds-buy-entry-token cosign-rejected
       quest-success ds-newsletter-success unsubscribe-goodbye wallet-deposit
       network-guard
       auth entry-tokens onchain-tx ds-onramp-hub ds-wallet-topup].each do |id|
      refute_includes registered, id, "#{id} is a turf card; the guide should not mirror it"
      refute_includes opened, id, "#{id} is a turf card; the guide should not card it"
      refute File.exist?("app/views/style/modals/_#{id.tr('-', '_').sub(/\Ads_/, 'ds_')}.html.erb"),
             "#{id}'s specimen file survived the deletion"
    end
  end
end
