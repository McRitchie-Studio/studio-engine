# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"

# [integration] The style guide's WEB3 specimens, which now come from a gem.
#
# WHAT THIS FILE REPLACES. wallet_connect_picker_test.rb and
# web3_step_up_modal_test.rb between them covered the two web3 partials in
# detail — the extra_data seam, the store/connect_fn locals, the slot, the
# mobile Phantom collapse. Those partials left this engine for solana-studio
# with the two-template split (BASE is studio-engine + mcritchie-studio, WEB3
# ADD is solana-studio + turf-monster), and their internals went with them:
# solana-studio's test/web3_modals_test.rb owns them now. Keeping assertions
# about a gem's private markup here would re-couple the two repos and redden
# this engine's CI every time the gem legitimately changed its own card.
#
# WHAT STAYS HERE IS WHAT THIS ENGINE STILL OWNS:
#   · the style guide renders the REAL gem cards, not a fork of them
#   · /admin/style survives in an app that bundles NO solana-studio
#   · the two engine blocks the gem renders BY NAME across the gem boundary
class StyleWeb3SpecimensTest < ActiveSupport::TestCase
  # The engine's views AND the gem's — a WEB3 ADD app. Passed as explicit path
  # strings rather than ActionController::Base.view_paths: the resolver objects
  # that collection hands back are shared, and reusing them across the
  # with_empty_template_cache classes these helpers build raises an undefined
  # compiled-method error rather than rendering.
  #
  # The suite's other view tests lock this to ["app/views"]. That would silently
  # exclude solana-studio and turn every assertion below into a test of the
  # ABSENT-gem path instead of the one it means to check — passing for the wrong
  # reason, which test_the_gate_reads_the_gem_and_not_a_constant now catches.
  ENGINE_VIEWS = "app/views"
  GEM_VIEWS = File.join(Gem::Specification.find_by_name("solana-studio").gem_dir, "app/views").freeze

  def full_view
    build_view([ENGINE_VIEWS, GEM_VIEWS])
  end

  # A BASE app: this engine's own views and nothing else. This is not a
  # contrivance — mcritchie-studio, acquisition-studio, mcritchie-industries and
  # moms-app all mount studio-engine and bundle no solana-studio. That is four
  # of the five consumers; turf-monster is the only one that bundles the gem.
  def base_app_view
    build_view([ENGINE_VIEWS])
  end

  def build_view(paths)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(paths)
    view.extend(Studio::Engine.helpers)
    view
  end

  # The auth modal ALONE, with the local style/_modals passes it.
  #
  # Everything else in this file goes through render_index, because it is asking
  # about the GUIDE. The two tests below ask about the credential slot's Ruby
  # gate, whose two terms — is the picker registered, does a layer ship the
  # credential — the real gem always answers together. Only a direct render can
  # separate them, and one of those splits is a state solana-studio actually
  # shipped rather than a contrivance.
  def render_auth(paths, web3_gem:)
    build_view(paths).render(partial: "style/modals/auth", locals: { web3_gem: web3_gem })
  end

  def with_features(features)
    original = Studio.features
    Studio.features = features
    yield
  ensure
    Studio.features = original
  end

  # --- the specimens are the REAL gem cards -------------------------------

  def test_the_connect_wallet_specimen_configures_the_gems_picker
    html = full_view.render(partial: "style/modals/wallet_connect")

    # Built-ins prove it is the GEM's partial, not a copy of it living here.
    assert_includes html, "showPhantomDeepLink"
    assert_includes html, "window.dsWalletConnectDemo(name, opts)"
    # Hooks prove the guide's demo configuration actually reached it.
    assert_includes x_data(html), "onConnected()"
    # Unescaped: the heredoc rides through as markup, not as HTML entities.
    refute_includes x_data(html), "&#39;"
  end

  def test_the_style_guide_registers_the_step_up_card_and_renders_the_real_partial
    with_features(%i[web3]) do
      html = render_index(full_view)

      assert_includes html, registration_for("web3-step-up")
      # The proof it is the real partial and not a copy: the shared file's own
      # markup, reached through the style guide's render.
      assert_includes html, "solanaConnectAndVerify(name, { linkMode: false })"
      assert_includes html, "$store.dsModals.swap('wallet-connect'"
    end
  end

  def test_both_sign_wallet_specimens_appear_in_the_web3_section
    with_features(%i[web3]) do
      html = render_index(full_view)

      assert_includes html, "Sign Wallet"
      assert_includes html, "Sign Wallet (no remembered brand)"
    end
  end

  def test_the_specimens_stay_openable_with_web3_off
    # The section's disabled-but-present-yet-openable contract: a capability that
    # is off greys the card and badges it, but never hides a state from review.
    with_features([]) do
      html = render_index(full_view)

      assert_includes html, "Sign Wallet"
      assert_includes html, registration_for("web3-step-up")
    end
  end

  # --- the BASE app, which has no solana-studio at all --------------------

  def test_the_style_guide_renders_for_an_app_that_bundles_no_solana_studio
    # THE FAILURE THIS PREVENTS. Before the gate, the guide rendered
    # studio/modals/wallet_connect unconditionally. Re-pointing that at the gem
    # without a gate would raise ActionView::MissingTemplate on /admin/style for
    # every BASE consumer — a page that worked yesterday, 500ing on a deploy that
    # touched none of their code.
    with_features(%i[web3]) do
      html = nil
      assert_nothing_raised { html = render_index(base_app_view) }

      # The cards are still LISTED. A reader of a BASE app's guide still learns
      # these states exist; they simply cannot be opened there — a claim this
      # file only ASSERTED from 0.66.3 on. See the two tests below it: for a day
      # the sentence was true of the intent and false of the markup, and the
      # cards rendered as role=button over an id nothing had registered.
      assert_includes html, "Sign Wallet"
      assert_includes html, "Connect wallet"
      # But nothing REGISTERED them, so nothing tries to render the absent gem.
      refute_includes html, registration_for("web3-step-up")
      refute_includes html, registration_for("wallet-connect")
    end
  end

  def test_the_gate_reads_the_gem_and_not_a_constant
    # Proves the two views above really do differ in gem resolution, so the
    # BASE-app test is exercising the gate rather than passing for some other
    # reason. Without this, a typo'd prefix would make web3_gem false ALWAYS —
    # and the BASE test would still pass while the gem test silently regressed.
    assert full_view.lookup_context.exists?("wallet_connect", ["solana_studio/modals"], true),
           "the gem's picker must resolve with every view path registered"
    refute base_app_view.lookup_context.exists?("wallet_connect", ["solana_studio/modals"], true),
           "the gem's picker must NOT resolve from the engine's views alone"
  end

  # --- [component] the TRIGGER, one layer above the registration gate -----

  # The three cards solana-studio backs. Named here because the count is a fact
  # the Gemfile comment also states, and the two should move together.
  GEM_BACKED_CARDS = ["Connect wallet", "Sign Wallet", "Sign Wallet (no remembered brand)"].freeze

  # The engine's OWN web3 specimens — registered unconditionally, so they keep
  # the section's disabled-but-openable preview contract in a BASE app. They are
  # the control: they prove the fix below gated the gem-backed cards
  # SPECIFICALLY, and did not simply turn the web3 section inert.
  #
  # STILL ONE CARD, BUT A DIFFERENT ONE — and the substitution is the point.
  # "Setup Wallet" left on 2026-09-08 and "Processing on-chain tx" on 2026-09-09,
  # both for mirroring cards turf owns and now cards against its real partials.
  # The replacement is "Entry confirmed", which renders
  # studio/modals/blocks/_entry_confirmed: a block THIS ENGINE SHIPS, so unlike
  # its two predecessors it cannot be retired by a decision made in another repo.
  #
  # A one-member control still discriminates — an inert section fails it — but it
  # has no second card to corroborate, so a future engine-owned web3 specimen
  # belongs in this list.
  ENGINE_OWNED_CARDS = ["Entry confirmed"].freeze

  def test_the_gem_backed_specimens_are_not_triggers_in_a_base_app
    # THE DEFECT THIS PREVENTS. web3_gem gated the REGISTRATION and nothing else,
    # so a BASE app's /admin/style listed these three as role=button cards over a
    # modal id nothing registered: clicking one opened an EMPTY panel. Strictly
    # better than the missing-template 500 the gate prevents, and still a control
    # that does nothing.
    #
    # BOTH capability states, because the two gates fail differently and only one
    # of them was in the original report:
    #   features []      -> `disabled` is already true, so the card is badged but
    #                       `openable: true` kept it clickable.
    #   features [:web3] -> `disabled` is FALSE, so the card rendered as a fully
    #                       NORMAL live card: no badge, no aria-disabled, and
    #                       clickable no matter what `openable` says. Worse, and
    #                       it is the state the BASE-app test above runs in.
    [[], %i[web3]].each do |features|
      with_features(features) do
        html = render_index(base_app_view)

        GEM_BACKED_CARDS.each do |label|
          card = specimen_card(html, label)

          refute_nil card, "the #{label} specimen must stay LISTED in a base app (features=#{features.inspect})"
          refute_includes card, 'role="button"',
                          "#{label} must not be a trigger where the gem is absent " \
                          "(features=#{features.inspect}) — nothing registers its modal, so it opens an empty panel"
          refute_includes card, "@click=",
                          "#{label} must carry no open handler where the gem is absent (features=#{features.inspect})"
          # Badged, not silently missing: the reader is told the state exists and
          # that this app cannot show it. This half is what the Gemfile comment
          # promises ("the web3 cards badged"), and features=[:web3] broke it.
          assert_includes card, 'aria-disabled="true"',
                          "#{label} must be marked disabled for assistive tech (features=#{features.inspect})"
          assert_includes card, "disabled on this app",
                          "#{label} must carry the badge (features=#{features.inspect})"
        end
      end
    end
  end

  def test_an_app_that_bundles_the_gem_keeps_every_web3_trigger
    # The other half of the contract, and the one a careless fix breaks: gating
    # the trigger on the gem must change NOTHING for a WEB3 ADD app. In both
    # capability states these cards stay clickable — with :web3 off that is the
    # section's deliberate greyed-but-still-openable preview, which is exactly
    # what test_the_specimens_stay_openable_with_web3_off is defending.
    [[], %i[web3]].each do |features|
      with_features(features) do
        html = render_index(full_view)

        GEM_BACKED_CARDS.each do |label|
          card = specimen_card(html, label)

          refute_nil card, "the #{label} specimen must render for a web3 app (features=#{features.inspect})"
          assert_includes card, 'role="button"',
                          "#{label} must stay openable where the gem resolves (features=#{features.inspect})"
        end
      end
    end
  end

  def test_the_engine_owned_web3_specimens_keep_the_preview_contract
    # The control for the two tests above. These specimens are registered with no
    # gem gate, so a BASE app can still open them — greyed and badged with :web3
    # off, live with it on. If a fix ever gates the whole web3 section on the gem
    # instead of the three cards that need it, this is what catches it.
    [[], %i[web3]].each do |features|
      with_features(features) do
        html = render_index(base_app_view)

        ENGINE_OWNED_CARDS.each do |label|
          card = specimen_card(html, label)

          refute_nil card, "the #{label} specimen must render in a base app (features=#{features.inspect})"
          assert_includes card, 'role="button"',
                          "#{label} is engine-owned and registered unconditionally — it must stay " \
                          "openable in a base app (features=#{features.inspect})"
        end
      end
    end
  end

  def test_a_base_app_is_told_why_the_three_cards_do_not_open
    # The operator-facing half. Making the cards inert without saying why turns a
    # documented state into an unexplained dead tile — the section's whole job is
    # that a reader still LEARNS the state exists. The notice appears only where
    # the gem is absent; a web3 app must never see it.
    with_features(%i[web3]) do
      assert_includes render_index(base_app_view), "This app bundles no solana-studio",
                      "a base app's web3 section must say why the three cards cannot be opened"
      refute_includes render_index(full_view), "This app bundles no solana-studio",
                      "an app that bundles the gem must not be told it lacks it"
    end
  end

  # --- RETIRED 2026-09-09: the AUTH modal's Solana button ------------------
  #
  # SEVEN TESTS LIVED HERE and all seven read style/modals/_auth, a MIRROR of
  # turf-monster's sign-in card. The engine ships no auth card — a sign-in modal
  # is a product decision (which methods, whose terms, whose legal copy) — so
  # turf owns one and cards it against its real partial on its own host section.
  # The mirror is gone and these went with it.
  #
  # WHAT THEY WERE GUARDING, AND WHERE IT STILL LIVES. Their subject was one
  # rule: A TRIGGER MUST CARRY AT LEAST THE GATE ITS TARGET'S REGISTRATION
  # CARRIES, or it opens an empty panel. The auth modal's Solana button was the
  # second door onto that defect (it swapped to 'wallet-connect', whose
  # registration is gated on web3_gem); the three gem-backed specimen cards were
  # the first. THOSE THREE ARE STILL HERE, in
  # #test_the_gem_backed_specimens_are_not_triggers_in_a_base_app and
  # #test_an_app_that_bundles_the_gem_keeps_every_web3_trigger, which run the
  # same two capability states against the same rule. The rule keeps two
  # witnesses; it lost the auth-methods AXIS, which only the auth card had.
  #
  # The one assertion NOT tied to the mirror was kept and stands alone below:
  # the engine must ship no Solana button markup of its own. It is a negative
  # over the WHOLE guide, so it never needed the auth card to be meaningful, and
  # it is the one that would catch a re-added engine copy of the gem's button —
  # the failure that let the wallet picker reach three drifting copies.
  #
  # Two more things they asserted, recorded because nothing else says them:
  #   * solana-studio 0.5.2 really shipped auth/_wallet_credential WITHOUT
  #     modals/_wallet_connect. A layer can ship the credential and no picker, so
  #     a gate that only asks "does the credential exist?" says yes and draws a
  #     button that swaps to an unregistered id. web3_gem is the term that
  #     refuses it. Any future consumer-side auth card needs both terms.
  #     (turf-monster's style_host_section_test carries this forward for the card
  #     that now renders.)
  #   * methodOn('wallet') reads props.methods.wallet — the specimen's own
  #     checkbox — BEFORE any server default, so a checkbox is not a gate. The
  #     fix has to be in Ruby. lib/studio.rb states the same split where it
  #     declines to gate the /auth/solana routes on :web3.

  def test_the_engine_ships_no_solana_button_of_its_own
    # PINNED BY PROVENANCE, which is why this outlived the card it was written
    # against. A brand mark is namespaced by whoever owns it: the gem's gradient
    # id is solana-studio-auth-grad, and the copy THIS ENGINE carried until
    # adopt-wallet-credential-slot was auth-solana-grad. Asserting the engine's
    # id appears nowhere on the guide is what makes a re-added engine copy fail
    # here rather than quietly becoming a second source of the same button.
    #
    # It reads the FULL view deliberately: with the gem resolved, the gem's own
    # button IS on the page, so a naive "no Solana gradient anywhere" would fail
    # on correct output. The two ids are what tell the gem's copy from a fork.
    with_auth(%i[web3], %i[magic_link google wallet]) do
      html = render_index(full_view)

      refute_includes html, "auth-solana-grad",
                      "this engine must ship no Solana button markup of its own — the gem " \
                      "contributes that partial, and a second copy here is how the wallet " \
                      "picker reached three drifting versions"
    end
  end

  # --- the cross-boundary contract, which is easy to break by accident ----

  def test_the_engine_keeps_the_blocks_the_gem_renders_by_name
    # solana-studio's partials render THESE, from this engine, by string name
    # across the gem boundary (re-derived from the resolved gem 2026-09-07 at
    # solana-studio 0.6.1, and re-checked at 0.7.0, which is what this engine
    # locks — 0.7.0 changes _web3_step_up's failure reporting, not its header,
    # so all three edges below hold unchanged at both versions):
    #
    #   solana_studio/modals/_wallet_connect    -> studio/modals/blocks/wallet_brand_sprite
    #   solana_studio/modals/_web3_step_up      -> studio/modals/blocks/wallet_brand_sprite
    #   solana_studio/modals/_network_mismatch  -> studio/modals/blocks/card_header
    #
    # THE card_header ROW MOVED, and the old note had it on the wrong partial.
    # It read `_web3_step_up -> card_header`, which 0.6.1 severed: the step-up
    # card now heads itself with a wallet BRAND MARK, and card_header has no slot
    # for one (it takes an emoji, a spinner, or one of two fixed icons). Left
    # uncorrected the note was worse than merely stale — it named the only edge
    # holding up the card_header half of this assertion as an edge that no longer
    # exists, so the next reader could reasonably conclude the block had no gem
    # consumer left and delete it. _network_mismatch is what keeps it alive.
    #
    # Nothing in THIS repo's own render graph would notice if they were renamed
    # or removed — the wallet UI that used to render them left. The failure would
    # surface as a missing-template error inside a gem card, in turf-monster,
    # after a release. Deleting these two is a cross-repo change, not a cleanup.
    %w[wallet_brand_sprite card_header].each do |block|
      assert full_view.lookup_context.exists?(block, ["studio/modals/blocks"], true),
             "studio/modals/blocks/_#{block} is rendered BY NAME from solana-studio's web3 " \
             "cards. Removing or renaming it here breaks those cards in every consuming app; " \
             "change the gem in the same release or leave it alone."
    end
  end

  private

  def render_index(view) = view.render(template: "style/index")

  # The modal HOST REGISTRATION for a card id, as the guide emits it.
  #
  # Anchored on the <template x-if> wrapper, and that precision is load-bearing.
  # The bare expression `$store.dsModals.current().id === 'web3-step-up'` also
  # appears in each specimen CARD's glow_when attribute, which renders whether or
  # not the modal was registered — so a substring assertion for it is true even
  # in a BASE app where nothing registered anything, and the absent-gem test
  # passed for the wrong reason until this was tightened.
  REGISTRATION_PREFIX = %(<template x-if="$store.dsModals.current().id === ).freeze

  def registration_for(id)
    %(#{REGISTRATION_PREFIX}'#{id}'">)
  end

  # ONE modal's REGISTERED block, windowed: from its <template x-if> wrapper to
  # the next modal's. Every registration on the page opens with the same prefix,
  # so the next occurrence of it is this block's end.
  #
  # Measured, so the claim is about the code and not the intent: the auth block
  # is 2.3% of the rendered guide, and openWalletHub / submitMagicLink are
  # auth-EXCLUSIVE strings today — a document-wide assertion on them would bite
  # too. So this window is DEFENSIVE, not load-bearing, and saying otherwise
  # would be the overclaim specimen_card was written to stop. It earns its place
  # by scope: the guide gains modals constantly, and the day another one grows a
  # wallet trigger or a second sign-in surface, the document-wide version starts
  # answering a question this test never asked. specimen_state below is where
  # windowing IS load-bearing, with the decoy named.
  def modal_registration(html, id)
    start = html.index(registration_for(id))
    return nil unless start

    nxt = html.index(REGISTRATION_PREFIX, start + REGISTRATION_PREFIX.length)
    nxt ? html[start...nxt] : html[start..]
  end

  # WALLET CTA CALL SITES in a window — anything that opens the picker.
  #
  # REBOUND, and deliberately TIGHTER than what it replaces. This used to scan
  # for `openWalletHub()` not followed by a brace: an engine-owned FUNCTION
  # NAME, plus a dance to exclude its own definition. adopt-wallet-credential-
  # slot moved the button into solana-studio, which inlines the swap instead, so
  # that name no longer exists in this engine at all and the old regex would be
  # green on a base app for the wrong reason — it cannot find a string nobody
  # writes any more, whatever the markup does.
  #
  # The old helper's own comment said it meant to catch a call site "rather than
  # pinning the one handler string the bug happened to use". Pinning
  # openWalletHub was exactly that. This asks the question the tests are named
  # for instead: does anything here OPEN THE PICKER.
  #
  # Why this bites harder, not softer:
  #   · it matches the SWAP CALL carrying its literal target id, which is the
  #     thing that actually opens the panel, not a name that merely implies it;
  #   · the leading dot requires a RECEIVER, so a bare `swap('wallet-connect')`
  #     — a definition, or prose naming the method alone — cannot satisfy it.
  #     It does NOT exclude prose generally, and an earlier draft of this comment
  #     claimed it did: a rendered comment quoting the whole call WITH its
  #     receiver ("…calls $store.dsModals.swap('wallet-connect', …)") matches
  #     this regex exactly as a real call site does. That mattered enough to
  #     correct because the claim became load-bearing — style_page_test's CTA
  #     window anchors on this same shape. What actually separates prose from a
  #     call there is not the regex: it is that the window must resolve to a
  #     well-formed OPEN TAG carrying the anchor in an attribute, which a comment
  #     cannot. MEASURED on the rendered page today: two matches, both real
  #     elements, no prose site;
  #   · it still catches the call behind ANY attribute — @click today, @keydown
  #     or a future x-on tomorrow — which was the original stated intent;
  #   · it needs no definition-exclusion lookahead, because the engine defines
  #     no wallet handler to exclude.
  # Mutation-proved both directions in the PR body.
  def wallet_cta_call_sites(html)
    html.to_s.scan(/\.swap\(\s*'wallet-connect'/)
  end

  # The wallet CTA's OWN element — its open tag, from "<" to the ">" that closes
  # it. Anchored on the swap call above, because that is what identifies this
  # element as the CTA rather than the button next to it.
  #
  # The quote-aware walk is not ceremony: the CTA's @click carries a
  # single-quoted modal id inside a double-quoted attribute, and a naive
  # index(">") would be one bad attribute away from truncating the tag and
  # silently dropping the very attribute this file is here to read.
  #
  # AND IT IS NOW GUARDED. The first version of this walk was not, and nothing
  # checked that: rindex("<") can land inside an EARLIER attribute VALUE instead
  # of on the tag's own "<", after which the walk starts mid-string with its
  # quote state INVERTED and can run off the end, close on a ">" that precedes
  # the anchor, or sail past the real ">" and hand back kilobytes of following
  # markup while calling it an element (a constructed case measured 3375 bytes
  # against a real 284). It fails safe on the markup either partial ships today,
  # but "today's markup happens to be kind" is not a guard.
  #
  # No ONE invariant catches every misaligned shape, so all FIVE below are checked
  # and every one of them RAISES. Nil means one thing only: the anchor is absent.
  #
  # THIS COPY HAS NO GUARD TEST OF ITS OWN. The previous sentence said the
  # contract was "exercised there" in style_page_test — a neighbour-vouch, and
  # this file's own rule against neighbour-vouching sits a few dozen lines above
  # it. Two things were wrong with the vouch: the count was five, not four, and
  # the neighbour exercised three of them until PR window-guard-branches-are-prose
  # added the missing two.
  #
  # What is true, stated as a fact about THIS file rather than a borrowed one:
  # wallet_cta_element is a semantic DUPLICATE of style_page_test's
  # open_tag_containing — same five invariants, same messages bar the method name
  # — and only that copy is exercised. Extracting both to one shared helper is the
  # standing fix; until then a change here must be mirrored there BY HAND, and
  # this comment is the only thing that says so.
  def wallet_cta_element(html)
    html = html.to_s
    site = html.index(/\.swap\(\s*'wallet-connect'/)
    return nil unless site

    start = html.rindex("<", site)
    raise "wallet_cta_element: misaligned — no \"<\" precedes the anchor" unless start

    element = nil
    quote = nil
    cursor = start
    while (cursor += 1) < html.length
      char = html[cursor]
      if quote
        quote = nil if char == quote
      elsif ['"', "'"].include?(char)
        quote = char
      elsif char == "<"
        raise "wallet_cta_element: misaligned — an unquoted \"<\" appears before " \
              "the tag closed, so the walk's quote state is inverted"
      elsif char == ">"
        element = html[start..cursor]
        break
      end
    end

    raise "wallet_cta_element: misaligned — the anchor is present but no tag " \
          "closed after it (the walk ran off the end)" unless element
    raise "wallet_cta_element: misaligned — the tag closed BEFORE the anchor, " \
          "so this window is not the element carrying it" unless cursor > site
    raise "wallet_cta_element: misaligned — the window is not a single open tag " \
          "(#{element.bytesize} bytes), so it overran the element" unless element.match?(OPEN_TAG)

    element
  end

  # A well-formed HTML OPEN TAG, whole. Attribute names are deliberately loose
  # (`@click`, `:disabled`, `x-show` are all legal here); values are the three
  # HTML shapes. An overrun window carries following markup, which cannot match.
  OPEN_TAG = %r{\A<[A-Za-z][^\s>/]*(?:\s+[^\s=>/]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]*))?)*\s*/?>\z}

  # The x-show EXPRESSION on the wallet CTA, or nil when it carries none.
  #
  # WHY THIS IS NOT `assert_includes auth, "methodOn('wallet')"`, which is what
  # style_page_test:580 does and what this assertion was first rebound to.
  # MEASURED on the rendered auth modal: `methodOn('wallet')` occurs TWICE, and
  # only one occurrence is the gem's. The other is ENGINE-owned, three lines
  # below the render call, on the "or" divider:
  #
  #   x-show="methodOn('magicLink') && (methodOn('google') || methodOn('wallet'))"
  #
  # That divider renders whether or not the gem's button does, so a
  # document-wide substring assert stays GREEN with the CTA's gate deleted
  # outright — reading an engine-owned divider while claiming to check a
  # gem-owned gate. It is the same failure registration_for and specimen_state
  # already document, one seam over.
  #
  # AN EARLIER DRAFT OF THIS COMMENT SAID style_page_test's bare form was "sound
  # where it lives, asking a weaker question of the whole page". That was wrong,
  # and wrong in the direction that buries findings. For the WALLET term the bare
  # form was not asking a weaker question — it was asking a DIFFERENT one, and
  # answering yes about an engine-owned divider. Measured there too: with this
  # same gate deleted, style_page_test's wallet assertion stayed green. It is
  # rebound now (StylePageTest#credential_visibility_gate).
  #
  # AND THE SECOND HALF OF THAT SENTENCE WAS WRONG TOO, which is the sharper
  # lesson. The finding recorded google and magicLink as "fine — they occur twice
  # in ways that still bite", and this comment repeated it. MEASURED instead of
  # repeated: the SECOND occurrence of each is that same "or" divider,
  # `methodOn('magicLink') && (methodOn('google') || methodOn('wallet'))`, which
  # carries ALL THREE terms on ONE unconditional element. Deleting the Google
  # button's own x-show, and separately the magic-link form's, each left the old
  # assertion GREEN. All three were inert together, and so was `termsOn()` (three
  # renders, two of them the modal's own x-data). Every one of them is rebound
  # now.
  #
  # A comment that over-vouches for a test one seam over is how an inert guard
  # survives review — and vouching for its NEIGHBOURS without re-running them is
  # how three more survive alongside it.
  #
  # Reading the EXPRESSION rather than the whole attribute is the actual repair.
  # The concern is that methodOn still owns visibility, never how that call is
  # spelled — so the gem tolerating a host that defines no methodOn
  # (`typeof methodOn === 'function' ? methodOn('wallet') : true`) satisfies it,
  # while removing the x-show or moving the decision into ERB does not.
  def wallet_cta_visibility_gate(html)
    wallet_cta_element(html)&.slice(/\sx-show="([^"]*)"/, 1)
  end

  # The x-data STATE a specimen card is seeded with.
  #
  # This lives on style/_modal_specimen's glow WRAPPER, outside the <article>
  # specimen_card windows, so it needs its own window rather than a second use
  # of that one. Anchored on the nearest wrapper before the label: every
  # specimen opens its x-data with the same copiedRef key.
  #
  # Here the windowing is genuinely LOAD-BEARING, and the decoy is measured. A
  # base app's page carries TWO "wallet: true" substrings before this fix and
  # ONE after it, because the auth partial's own _methodDefaults renders
  # `wallet: <the capability>` into its x-data. So a document-wide assertion
  # would be reading the MODAL's default when it meant to read the CARD's
  # toggle seed — passing, on the wrong string, in exactly the base-app-with-
  # web3-on case that matters most.
  def specimen_state(html, label)
    idx = html.index(">#{label}</span>")
    return nil unless idx

    start = html.rindex(%(x-data="{ copiedRef: false), idx)
    return nil unless start

    close = html.index(%("), start + %(x-data=").length)
    close ? html[start...close] : nil
  end

  # with_features, plus the auth_methods axis. Both are global config an app
  # sets in its initializer, and this file's subject depends on BOTH: the
  # capability decides whether the wallet method defaults on, auth_methods
  # decides whether it is offered at all, and neither answers the gem question.
  def with_auth(features, auth_methods)
    original = Studio.auth_methods
    Studio.auth_methods = auth_methods
    with_features(features) { yield }
  ensure
    Studio.auth_methods = original
  end

  # ONE specimen card's <article> element, windowed.
  #
  # The windowing is the whole assertion, and this file already learned why once
  # (see registration_for). For role="button" it is worse than for the glow
  # expression: dozens of cards on this page are triggers, so a document-wide
  # assert is true for EVERY input and a document-wide refute is false for every
  # input. Both would be inert while looking like coverage.
  #
  # Anchored on the header label's own <span>, which is exact and not a prefix:
  # ">Sign Wallet</span>" cannot match the "(no remembered brand)" card, and the
  # hidden x-ref="ref" reference sentence names the card mid-string, never as
  # ">Sign Wallet</span>".
  def specimen_card(html, label)
    idx = html.index(">#{label}</span>")
    return nil unless idx

    opening = html.rindex("<article", idx)
    closing = html.index("</article>", idx)
    return nil unless opening && closing

    html[opening...closing]
  end

  # The x-data ATTRIBUTE only. Windowing matters: the picker's own doc comment
  # names several hooks, so a document-wide assertion for a hook name is green
  # whether or not the hook reached the component.
  def x_data(html)
    html[/x-data="(.*?)"\s*\n?\s*class="relative"/m, 1].to_s
  end
end
