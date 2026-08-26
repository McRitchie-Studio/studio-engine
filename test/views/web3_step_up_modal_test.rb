# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"

# [unit] studio/modals/_web3_step_up — the shared WEB3 STEP-UP card.
#
# This partial is unusual for the Web3 section, and the difference is
# what most of these tests defend: the other cards there are style-guide
# SPECIMENS while each app keeps its own live modal, but this one is the REAL
# partial a host renders in production. So the style guide and the shipped card
# cannot drift — and every host hook has to be a local with a working default,
# or the "shared" partial is really turf's partial with extra steps.
class Web3StepUpModalTest < ActiveSupport::TestCase
  PARTIAL = "studio/modals/web3_step_up"
  SOURCE  = "app/views/studio/modals/_web3_step_up.html.erb"

  def render_card(**locals)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.extend(Studio::Engine.helpers)
    view.render(partial: PARTIAL, locals: locals)
  end

  def render_index
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.extend(Studio::Engine.helpers)
    view.render(template: "style/index")
  end

  def with_features(features)
    original = Studio.features
    Studio.features = features
    yield
  ensure
    Studio.features = original
  end

  # --- the silent-no-op guard -------------------------------------------------

  # A double quote inside the double-quoted x-data closes the attribute early and
  # Alpine mounts the whole component as a SILENT no-op: the markup still
  # renders, so every other assertion in this file would still pass while the
  # card is dead in a browser. It has bitten the ecosystem twice, so every
  # step-machine modal carries this guard.
  test "the x-data attribute contains no double quotes or backticks" do
    x_data = File.read(SOURCE)[/x-data="(\{.*?\})"\s*\n/m, 1]
    assert x_data, "could not locate the x-data attribute — did the root element change?"
    assert_not_includes x_data, '"'
    assert_not_includes x_data, "`"
  end

  # --- the two shapes ---------------------------------------------------------

  test "it renders the standard wallet ROW, not a filled CTA" do
    html = render_card
    # The row shape the connect picker uses, so a wallet reads identically
    # everywhere it is offered.
    assert_includes html, "w-full flex items-center gap-3 p-3 rounded-xl bg-surface-alt border border-strong"
    assert_not_includes html, "btn btn-primary btn-lg"
    assert_includes html, "'#se-wallet-' + provider", "the row paints the brand's own sprite"
    assert_includes html, "Installed"
  end

  test "the row glows, because it is the one thing to press" do
    html = render_card
    assert_includes html, "pulse-cta"
    assert_includes html, "--pulse-cta-color: var(--color-primary)"
  end

  test "both provider states are present, and the fallback is not a dead end" do
    html = render_card
    # One template each. The card cannot know at render time which it will be —
    # the provider arrives as a prop — so BOTH must ship in the markup.
    assert_includes html, 'x-text="providerLabel"', "the remembered-brand row"
    assert_includes html, "Connect your wallet", "the no-brand fallback"
    # ...and the fallback's mark is a DRAWN wallet, not an emoji. The first pass
    # used U+1F45B PURSE, which renders as a pink handbag inches from Phantom's
    # real brand mark — the one thing on the card belonging to no design system.
    # Pinned by codepoint because the next well-meaning emoji looks fine in a
    # commit diff and wrong on screen.
    assert_not_includes html, "\u{1F45B}"
    assert_not_includes html, "&#128091;"
    assert_includes html, "get canOneClick() { return !!this.provider && !this.providerMissing; }"
  end

  test "presence is polled, never read once at mount" do
    # Wallet registration fills in asynchronously and this card auto-opens on the
    # render right after auth — the worst possible moment. A single early read
    # would badge an installed wallet as missing, with no way to correct it.
    html = render_card
    assert_includes html, "wallet-standard:register-wallet"
    assert_includes html, "setInterval"
    assert_includes html, "clearInterval", "and it must stop polling — this card can be reopened"
  end

  # --- host hooks are locals, with defaults ------------------------------------

  test "the modal store is a local, so the style guide can mount its own host" do
    assert_includes render_card, "$store.modals.current()"
    assert_includes render_card(modal_store: "dsModals"), "$store.dsModals.current()"
    assert_not_includes render_card(modal_store: "dsModals"), "$store.modals.current()",
                        "a half-swapped store leaves the card reading a host it is not mounted in"
  end

  test "the picker id and the back target are locals" do
    html = render_card(picker_modal_id: "pick-a-wallet", modal_id: "step-up")
    assert_includes html, "swap('pick-a-wallet'"
    assert_includes html, "backTo: 'step-up'"
  end

  test "the dismissal event is a local, and the card never opens the next modal" do
    # The HOST decides what follows — typically releasing an onboarding chain it
    # held while this card had the screen. A partial that opened the next modal
    # itself would make that decision for every app that renders it.
    html = render_card(dismiss_event: "stepped-up")
    assert_includes html, "CustomEvent('stepped-up')"
    assert_not_includes html, "open('onboarding"
  end

  test "the heading and subtext are locals" do
    html = render_card(heading: "Prove your wallet", subtext: "Custom why.")
    assert_includes html, "Prove your wallet"
    assert_includes html, "Custom why."
  end

  # --- the escape hatch --------------------------------------------------------

  test "the escape hatch ships by default and takes a host URL" do
    # A self-custody wallet is the one credential a host cannot reset for a user,
    # so the default must REACH someone rather than being opt-in.
    assert_includes render_card, "/help"
    assert_includes render_card, "Can&rsquo;t access your wallet?"
    assert_includes render_card(help_url: "/support", help_label: "Contact us"), "/support"
  end

  test "dropping the escape hatch takes a deliberate nil" do
    html = render_card(help_url: nil)
    assert_not_includes html, "Can&rsquo;t access your wallet?"
  end

  test "the card is dismissible" do
    # Advisory by construction — enforcement belongs to the host's on-chain gates,
    # never to this card. A card that could not be closed would lock a legitimate
    # owner out over a wallet they merely cannot reach right now.
    assert_includes render_card, "Not now"
    assert_includes render_card, 'aria-label="Close"'
  end

  # --- signing -----------------------------------------------------------------

  test "signing runs the wallet LOGIN, not the account-link path" do
    # linkMode binds to the current user but never grants the on-chain session —
    # the thing this card exists to obtain.
    assert_includes render_card, "solanaConnectAndVerify(name, { linkMode: false })"
  end

  test "it degrades rather than throwing when the host provides no wallet JS" do
    # The partial ships to any app that renders it, including one that has not
    # wired the global. A TypeError inside an Alpine handler is silent.
    assert_includes render_card, "typeof window.solanaConnectAndVerify !== 'function'"
  end

  # --- the style guide ---------------------------------------------------------

  test "the style guide registers the card and renders the REAL partial" do
    with_features(%i[web3]) do
      html = render_index
      assert_includes html, "$store.dsModals.current().id === 'web3-step-up'"
      # The proof it is the real partial and not a copy: the shared file's own
      # markup, reached through the style guide's render.
      assert_includes html, "solanaConnectAndVerify(name, { linkMode: false })"
      assert_includes html, "$store.dsModals.swap('wallet-connect'"
    end
  end

  # Renamed 2026-08-25: the pair are "Sign Wallet" cards now, in a section called
  # "Web3" rather than "Web3 Contest" — the section stopped being only about
  # contest entry once Setup Wallet and this pair moved into it.
  test "both Sign Wallet specimens appear in the Web3 section" do
    with_features(%i[web3]) do
      html = render_index
      assert_includes html, "Sign Wallet"
      assert_includes html, "Sign Wallet (no remembered brand)"
    end
  end

  test "the specimens stay openable with :web3 off" do
    # The section's disabled-but-present-yet-openable contract: a capability that
    # is off greys the card and badges it, but never hides a state from review.
    with_features([]) do
      html = render_index
      assert_includes html, "Sign Wallet"
      assert_includes html, "$store.dsModals.current().id === 'web3-step-up'"
    end
  end
end
