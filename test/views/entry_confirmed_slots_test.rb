# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"

# [unit] The two locals that make blocks/_entry_confirmed adoptable.
#
# WHY EITHER EXISTS. turf-monster composes this card's exact pieces already —
# card_header, solana_tx_link, cta_redirect, and a fork of the engine's own
# _seeds_bar — and still could not render THIS partial, for two reasons that had
# nothing to do with what the card looks like:
#
#   · its props source was hardcoded to $store.<store>.current(), and turf's card
#     is driven by $store.solanaModal, a DIRECT-FIELD store with no .current().
#     Against it, `c` is undefined and every props.* default resolves to {} — the
#     card renders complete and shows none of its numbers. Nothing throws.
#   · there was nowhere to put the kickoff countdown, and _success_card's yield
#     was already spent on the leveling enrichment.
class EntryConfirmedSlotsTest < ActiveSupport::TestCase
  # --- props_expr ------------------------------------------------------------

  def test_the_default_props_source_is_the_engine_host
    html = render_card

    assert_includes html, "$store.modals.current()",
      "the default must keep reading the engine host, so no consumer moves"
  end

  def test_the_default_follows_the_modal_store
    assert_includes render_card(modal_store: "dsModals"), "$store.dsModals.current()"
  end

  def test_a_direct_field_store_can_be_passed_whole
    # The turf case. The expression becomes the getter's whole body, so a store
    # object with .txSignature on it directly satisfies every props.* default.
    html = render_card(props_expr: "$store.solanaModal")

    assert_includes html, "get props() { return $store.solanaModal; }"
    assert_not_includes html, "current()",
      "a direct-field store has no .current(); leaving the call in resolves to {}"
  end

  # --- the above-seeds slot --------------------------------------------------

  def test_no_slot_renders_when_none_is_named
    refute_includes render_card, "kickoff-probe"
  end

  def test_the_named_partial_renders_inside_the_card
    html = render_card(above_seeds: "studio/modals/blocks/progress_pill",
                       above_seeds_locals: { current: 2, total: 3 })

    # Marker is the pill's own CONTAINER class, not "rounded-full bg-primary" —
    # that also matches the card header's :lg check pill (bg-primary/15), so the
    # first version of this counted the header and read 3 where it wanted 2.
    assert_equal 1, html.scan("max-w-[200px]").size,
      "the named partial must render, with its locals threaded through"
    assert_equal 2, html.scan("h-1.5 flex-1 rounded-full bg-primary\"").size,
      "two of three steps filled, from the locals passed through"
  end

  # --- slot position ---------------------------------------------------------

  def test_the_card_puts_its_slot_ABOVE_the_cta_by_default
    # A celebration's button is where the card ENDS. Anything under it is
    # furniture behind the exit — which is why turf has always run its kickoff
    # timer and seeds above the button, and why adopting this block had to keep
    # that order rather than quietly move it.
    html = render_card(above_seeds: "studio/modals/blocks/progress_pill",
                       above_seeds_locals: { current: 1, total: 3 },
                       cta_label: "Contest Lobby")

    slot_at = html.index("max-w-[200px]")
    cta_at  = html.index("Contest Lobby")
    assert slot_at, "the slot did not render"
    assert cta_at,  "the CTA did not render"
    assert_operator slot_at, :<, cta_at, "the slot must read above the button"
  end

  def test_the_position_is_overridable
    html = render_card(above_seeds: "studio/modals/blocks/progress_pill",
                       above_seeds_locals: { current: 1, total: 3 },
                       cta_label: "Contest Lobby",
                       slot_position: :below_cta)

    assert_operator html.index("Contest Lobby"), :<, html.index("max-w-[200px]")
  end

  # ---- the secondary action ------------------------------------------------
  #
  # sc_locals was a FIXED hash, so a consumer adopting this card in place of its
  # own fork lost any secondary action it had SILENTLY — no error, the button
  # simply stopped existing. That is what blocked turf-monster's entry-confirmed
  # defork: its card ends in a "Dismiss" link, and its call site sits inside a
  # <template x-if>, which takes ONE root, so the button cannot be kept outside
  # the block either.

  def test_a_secondary_action_reaches_the_card
    html = render_card(secondary_label: "Dismiss", secondary_event: "tm-modal-close")

    assert_includes html, "Dismiss", "the secondary label never reached the rendered card"
    assert_includes html, "tm-modal-close", "the secondary event never reached the rendered card"
  end

  # BOTH OR NEITHER, matching how _success_card and _error_card already gate the
  # pair. A label with no event is a button that does nothing, which is worse
  # than no button — it looks like an affordance and silently is not one.
  def test_a_label_without_an_event_renders_no_button
    html = render_card(secondary_label: "Dismiss")

    refute_includes html, "Dismiss", "a secondary label with no event rendered a dead button"
  end

  def test_an_event_without_a_label_renders_no_button
    html = render_card(secondary_event: "tm-modal-close")

    refute_includes html, "tm-modal-close", "a secondary event with no label rendered a nameless button"
  end

  # The default must not change for the callers that never asked for one.
  def test_no_secondary_action_renders_by_default
    html = render_card

    refute_includes html, "Dismiss"
  end

  private

  # A host renders these through ApplicationController, which has every engine
  # helper mixed in. A bare view has none — and this card reaches Studio.feature?
  # for its leveling gate — so extend the whole set rather than the one module
  # today's markup happens to call.
  def render_card(**locals)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.extend(Studio::Engine.helpers)
    view.render(partial: "studio/modals/blocks/entry_confirmed", locals: locals)
  end
end
