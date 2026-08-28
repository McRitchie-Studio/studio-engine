# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"

# [unit] blocks/_success_card's DRAIN CTA must wear the house button.
#
# THE DEFECT (filed by Carl reviewing turf PR 448; Mr. McRitchie decided
# 2026-08-27 to restore the token-driven button). The two drain branches were
# the ONLY two non-.btn buttons in the engine's whole modal-block family, styled
# by hand as px-4 py-2.5 text-sm rounded-lg with an inline CTA background.
# Against .btn + .btn-lg (engine.css) that is px-8 py-3 text-base rounded-xl,
# and it dropped the shadow, the hover, and the branded focus-visible ring.
# RENDERED HEIGHT 48px -> 40px — under the 44px mobile touch-target guideline,
# on turf-monster's primary conversion CTA.
#
# It could not be fixed from the consumer: blocks/_entry_confirmed builds its
# success-card locals as a FIXED hash with cta_drain: true, and neither that nor
# a cta_class is read from local_assigns, so the only consumer-reachable escape
# from the drain branch renders no CTA at all.
#
# ASSERTED ON THE CTA ELEMENT, not the document. Both class strings appear
# elsewhere in this partial (the non-drain branches two blocks below use
# btn btn-primary), so a document-wide assertion is green either way.
class SuccessCardDrainCtaTest < ActiveSupport::TestCase
  DRAIN_CLASSES = %w[btn btn-primary btn-lg w-full relative overflow-hidden].freeze

  def test_the_drain_anchor_branch_wears_the_house_button
    el = cta_element(render_card(cta_href_key: "props.lobbyUrl"))

    assert el, "the drain anchor CTA must render"
    DRAIN_CLASSES.each { |c| assert_includes class_list(el), c, "drain anchor is missing .#{c}" }
  end

  def test_the_drain_button_branch_wears_the_house_button
    el = cta_element(render_card(cta_event: "ds-modal-close"))

    assert el, "the drain button CTA must render"
    DRAIN_CLASSES.each { |c| assert_includes class_list(el), c, "drain button is missing .#{c}" }
  end

  def test_no_drain_branch_hardcodes_the_cta_background
    # btn-primary already sets the CTA colour. An inline background beats the
    # class in the cascade, so leaving one there silently re-pins the old look
    # even with every class correct — the reason this is its own assertion.
    %i[cta_href_key cta_event].each do |flavor|
      el = cta_element(render_card(flavor => "x"))

      refute_includes el.to_s, "background: var(--color-cta)",
                      "#{flavor} drain branch still hardcodes the CTA background"
    end
  end

  def test_the_drain_overlay_survives_the_reskin
    # The point of the drain branch. A reskin that drops the animated overlay
    # would satisfy every class assertion above and lose the feature.
    html = render_card(cta_event: "ds-modal-close")

    assert_includes html, "studio-modal-drain"
    assert_includes html, "origin-left"
  end

  def test_the_non_drain_branches_also_carry_btn_lg
    # UPDATED from a scope guard that asserted "btn btn-primary w-full". That
    # guard was right when the drain branches were the only ones being resized —
    # it stopped that change leaking. It became WRONG the moment the non-drain
    # branches were sized too, and an un-updated scope guard is how a follow-up
    # gets reverted by its own test suite. The family is now one height.
    html = render_card(cta_href_key: "props.lobbyUrl", cta_drain: false)

    assert_includes html, "btn btn-primary btn-lg w-full"
    refute_includes html, "studio-modal-drain"
  end

  def test_the_non_drain_button_branch_also_carries_btn_lg
    # The OTHER half of this change, and it had NO test: reverting the
    # cta_event branch alone left every test in this repo green, because
    # render_card's base hash pins cta_drain: true, so nothing ever rendered
    # the non-drain button. Asserted on the button ELEMENT, per this file's
    # header — a document-wide match is also satisfied by a sibling branch.
    html = render_card(cta_event: "ds-modal-close", cta_drain: false)

    el = html[/<button\b[^>]*@click="\$dispatch\('ds-modal-close'\)"[^>]*>/m]

    assert el, "the non-drain button CTA must render"
    assert_includes class_list(el), "btn-lg", "non-drain button is missing .btn-lg"
    refute_includes html, "studio-modal-drain"
  end

  private

  def render_card(**locals)
    base = { title: "Entry confirmed", cta_label: "Contest Lobby",
             cta_drain: true, auto_redirect_url_key: "props.lobbyUrl" }
    ActionView::Base.with_empty_template_cache
                    .with_view_paths(["app/views"])
                    .render(partial: "studio/modals/blocks/success_card",
                            locals: base.merge(locals))
  end

  # The CTA element itself — the <a> or <button> carrying the drain overlay.
  def cta_element(html)
    html[%r{<(?:a|button)\b[^>]*?(?:class|:href|@click)[^>]*?>(?=\s*<div class="absolute inset-0)}m] ||
      html[%r{<(?:a|button)\b[^>]*>(?=\s*<div class="absolute inset-0 pointer-events-none origin-left)}m]
  end

  def class_list(el)
    el.to_s[/class="([^"]*)"/, 1].to_s.split
  end
end
