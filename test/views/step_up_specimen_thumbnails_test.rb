# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"

# [component] The two "Sign Wallet" THUMBNAILS in the style guide's web3
# section, and the one thing a specimen owes: it must draw what the card draws.
#
# WHAT WENT WRONG. solana-studio 0.6.1 replaced the step-up card's padlock with
# the remembered wallet's own brand mark (a neutral billfold where no brand is
# remembered). The two hand-drawn thumbnails in style/_modals.html.erb went on
# crowning themselves with a padlock, so the style guide advertised a glyph the
# design system had stopped drawing — and a thumbnail is the first thing a
# designer reads. Per the modal-lifecycle module a specimen is kept in step with
# its card, which makes that a defect and not untidiness.
#
# WHY THE ASSERTIONS ARE SLICED, and this is the whole difficulty of the file.
# Two neighbouring facts make a page-wide assertion useless in BOTH directions:
#
#   · A page-wide "no padlock" check CANNOT PASS. The drag-board specimen's own
#     prose says "&#128274; pinned starters stay put" — a legitimate padlock this
#     test has no business touching.
#   · A page-wide "the brand mark is drawn" check CANNOT FAIL. The rendered guide
#     already carried 17 `se-wallet-` hits before this fix, several of them
#     static `<use href="#se-wallet-phantom">`, from the picker and the card's own
#     CTA button. An assertion for the mark was satisfied by those siblings no
#     matter what the thumbnail drew, which is how the original polish shipped
#     with six of nine mutants surviving.
#
# So every assertion below runs against a RAW SLICE of one thumbnail, taken by
# its data-test hook. Raw, not parsed: an HTML parser folds `&#128274;` into the
# codepoint, and the padlock has to be pinned in BOTH forms because ERB may emit
# either and a one-form assertion is half a test.
class StepUpSpecimenThumbnailsTest < ActiveSupport::TestCase
  PADLOCK_CODEPOINT = "\u{1F510}"
  PADLOCK_ENTITY    = "&#128274;"

  ENGINE_VIEWS = "app/views"
  GEM_VIEWS = File.join(Gem::Specification.find_by_name("solana-studio").gem_dir, "app/views").freeze

  # --- the thumbnails, which this repo hand-draws and therefore owns --------

  def test_neither_sign_wallet_thumbnail_crowns_a_padlock
    html = rendered_guide

    %w[step-up-thumb-brand step-up-thumb-no-brand].each do |hook|
      slice = thumbnail_slice(html, hook)

      refute_includes slice, PADLOCK_CODEPOINT,
                      "#{hook} still draws a padlock the step-up card stopped drawing in " \
                      "solana-studio 0.6.1. The card heads itself with the remembered wallet's " \
                      "brand mark, or a neutral billfold when no brand is remembered."
      refute_includes slice, PADLOCK_ENTITY,
                      "#{hook} draws a padlock as an HTML ENTITY. Same defect as the codepoint " \
                      "form; ERB may emit either, so both are pinned."
    end
  end

  def test_the_brand_thumbnail_heads_itself_with_the_wallets_own_mark
    slice = thumbnail_slice(rendered_guide, "step-up-thumb-brand")

    # The sketch idiom for a brand mark, as the Connect-wallet thumbnail above it
    # uses: a tile painted with the theme's primary token. A REAL sprite cannot
    # be used — every se-wallet symbol on this page is defined inside a
    # template x-if, whose content stays inert until Alpine clones it, so a use
    # outside one resolves to nothing and paints an empty box.
    assert_match(/<span class="block w-7 h-7 mx-auto rounded-lg" style="background: var\(--color-primary\)">/,
                 slice,
                 "the remembered-brand thumbnail must head itself with a centered brand tile at " \
                 "the header size, mirroring the card's own brand mark.")
  end

  def test_the_no_brand_thumbnail_heads_itself_with_the_neutral_billfold
    slice = thumbnail_slice(rendered_guide, "step-up-thumb-no-brand")

    # The card's own fallback, drawn rather than tinted, so the two thumbnails
    # differ in the header the way the two cards do: one names a wallet, the
    # other cannot.
    assert_includes slice, "bg-inset",
                    "the no-brand thumbnail's header sits in the card's inset-filled square."
    assert_match(/<rect x="3" y="6\.5" width="18" height="11" rx="2\.5"/, slice,
                 "the no-brand thumbnail must draw the billfold outline the card falls back to.")
    assert_match(/<circle cx="16\.6" cy="12" r="1\.3"/, slice,
                 "the billfold's clasp — without it the outline is an empty rectangle.")
  end

  # --- the OPENED specimen, which this repo owns through its LOCK -----------

  def test_the_opened_specimen_draws_no_padlock_either
    # NOT an assertion about the gem's private markup — this file deliberately
    # makes none, because that would redden engine CI every time solana-studio
    # legitimately restyled its own card. It is the DRIFT contract, and the only
    # version-independent way to state it.
    #
    # The opened specimen renders the real shared partial through whatever
    # Gemfile.lock resolves, so it is only as current as the lock. On 2026-09-07
    # the lock sat on 0.6.0 while turf-monster shipped 0.6.1: the guide's opened
    # card still drew the padlock, and fixing the thumbnails alone would have put
    # a brand mark on the sketch and a padlock in the card it opens — moving the
    # contradiction onto one screen rather than removing it.
    #
    # A version is deliberately NOT pinned here. The engine's constraint on
    # solana-studio is a FLOOR by decision (see Gemfile), so this states the
    # property instead and leaves the number alone.
    slice = opened_specimen_slice(rendered_guide)

    refute_includes slice, PADLOCK_CODEPOINT,
                    "the OPENED step-up specimen still draws a padlock, which means this engine's " \
                    "lock trails the release that removed it. Fix it in the engine, in one " \
                    "command, then commit the lock: bundle update solana-studio"
    refute_includes slice, PADLOCK_ENTITY,
                    "the OPENED step-up specimen draws a padlock as an HTML entity; see the " \
                    "codepoint assertion above for the remedy."
  end

  private

  def rendered_guide
    @rendered_guide ||= begin
      view = ActionView::Base.with_empty_template_cache.with_view_paths([ENGINE_VIEWS, GEM_VIEWS])
      view.extend(Studio::Engine.helpers)

      original = Studio.features
      begin
        Studio.features = %i[web3]
        view.render(template: "style/index")
      ensure
        Studio.features = original
      end
    end
  end

  # The raw markup of ONE thumbnail: from the opening tag carrying the hook to
  # its matching close. Depth-counted rather than "the next </div>", so a future
  # nested div inside a sketch cannot silently truncate the slice and hand every
  # refute_includes a free pass.
  def thumbnail_slice(html, hook)
    marker = %(data-test="#{hook}")
    at = html.index(marker)
    refute_nil at, "no thumbnail carries #{marker}; the slice this test asserts on does not exist."

    element_slice(html, html.rindex("<div", at), "div")
  end

  # The opened specimen: the template the modal host clones for the step-up id.
  def opened_specimen_slice(html)
    at = html.index("'web3-step-up'")
    refute_nil at, "the guide registers no web3-step-up specimen to open."

    element_slice(html, html.rindex("<template", at), "template")
  end

  def element_slice(html, start, tag)
    refute_nil start, "could not find the enclosing <#{tag}> for the slice."

    open_tag  = "<#{tag}"
    close_tag = "</#{tag}>"
    depth = 0
    cursor = start

    while cursor < html.length
      nxt_open  = html.index(open_tag, cursor)
      nxt_close = html.index(close_tag, cursor)
      break if nxt_close.nil?

      if nxt_open && nxt_open < nxt_close
        depth += 1
        cursor = nxt_open + open_tag.length
      else
        depth -= 1
        return html[start..(nxt_close + close_tag.length - 1)] if depth.zero?

        cursor = nxt_close + close_tag.length
      end
    end

    flunk "unbalanced <#{tag}> while slicing the specimen; the assertion below would be vacuous."
  end
end
