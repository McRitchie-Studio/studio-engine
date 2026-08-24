# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"

# [component] Guard for the admin/style living style guide (renamed from
# admin/design_system). Load-bearing properties, each exercised (not just
# declared):
#
#   1. Studio.routes draws admin_style_path -> style#index, AND keeps the legacy
#      admin_design_system_path helper resolving as a redirect to /admin/style
#      (a shipped host sidebar still links the old helper).
#   2. The require_admin gate the controller relies on (from the already-included
#      Studio::ErrorHandling concern) redirects a logged-out visitor AND a
#      logged-in non-admin to root, and lets an admin through.
#   3. StyleController wires that gate as a before_action.
#   4. The view is a bare content wrapper that REFERENCES every primitive family
#      (buttons, surfaces/text/form, motion, effect), wires the four-section nav
#      in order (Theme landing / Modals / Tricks / Tasks) with matching anchor
#      targets, and keeps the color role tokens in the Theme section (Theme owns
#      "the colors"). The dummy app does not compile the engine CSS, so specimens
#      are unstyled here by design — this asserts the classes/contract.
#   5. Studio.feature?(name) gates capability specimens. Off by default, so the
#      Leveling (Tricks) and web3 + leveling (Modals) groups render
#      "disabled-but-present" — present + flagged, never hidden.
#   6. Modals wires a page-scoped store (dsModals) whose Open affordances push the
#      real engine card blocks (processing/success/error/countdown) full-size.
#   7. Theme folds the /admin/theme role-color editor into the page AND persists
#      Save + Regenerate IN PLACE (fetch, no navigation).
#   8. Tasks mounts the LIVE studio/board primitive (demo mode) over the static
#      stage-* palette reference.
#   9. The Tricks Leveling group renders the REAL .level-badge tiers, and
#      engine-motion.css ships the ported ladder (modern slash-rgb form).
class StylePageTest < ActiveSupport::TestCase
  def routes
    Rails.application.routes.url_helpers
  end

  # --- 1. route drawn into every host (+ legacy redirect) --------------------

  test "Studio.routes draws /admin/style -> style#index" do
    assert_equal "/admin/style", routes.admin_style_path

    route = Rails.application.routes.routes.find { |r| r.name == "admin_style" }
    refute_nil route, "expected a named admin_style route"
    assert_equal "style", route.defaults[:controller]
    assert_equal "index", route.defaults[:action]
  end

  test "the legacy admin_design_system helper survives as a redirect to /admin/style" do
    # The helper must still resolve — MS's shipped sidebar links admin_design_system_path.
    assert_equal "/admin/design_system", routes.admin_design_system_path

    route = Rails.application.routes.routes.find { |r| r.name == "admin_design_system" }
    refute_nil route, "the admin_design_system helper must survive the rename"

    # It is now a redirect (no controller#action dispatch).
    endpoint = route.app
    endpoint = endpoint.app while endpoint.respond_to?(:app) &&
                                 !endpoint.is_a?(ActionDispatch::Routing::Redirect)
    assert endpoint.is_a?(ActionDispatch::Routing::Redirect),
      "admin_design_system must be a redirect to /admin/style, not a controller action"
  end

  # --- 2. the require_admin gate actually gates ------------------------------

  # A bare controller including the SAME concern the real controller inherits
  # its gate from, so require_admin is exercised, not merely named.
  class AdminGateProbeController < ActionController::Base
    include Studio::ErrorHandling
  end

  # Invoke require_admin with a stubbed viewer; return the captured redirect
  # ({} when the gate lets the request through).
  def gate_result_for(user)
    controller = AdminGateProbeController.new
    captured = {}
    controller.define_singleton_method(:current_user) { user }
    controller.define_singleton_method(:root_path) { "/" }
    controller.define_singleton_method(:redirect_to) do |target, response_options = {}|
      captured[:target] = target
      captured[:options] = response_options
      nil
    end
    controller.send(:require_admin)
    captured
  end

  def admin_user
    Object.new.tap { |u| u.define_singleton_method(:admin?) { true } }
  end

  def non_admin_user
    Object.new.tap { |u| u.define_singleton_method(:admin?) { false } }
  end

  test "require_admin lets an admin through" do
    assert_empty gate_result_for(admin_user), "an admin must not be redirected"
  end

  test "require_admin redirects a logged-in non-admin to root" do
    result = gate_result_for(non_admin_user)
    refute_empty result, "a non-admin must be redirected"
    assert_equal "/", result[:target]
  end

  test "require_admin redirects a logged-out visitor to root" do
    result = gate_result_for(nil)
    refute_empty result, "a logged-out visitor must be redirected"
    assert_equal "/", result[:target]
  end

  # --- 3. the real controller wires the gate ---------------------------------

  test "StyleController wires require_admin as a before_action" do
    # The controller inherits the host ApplicationController; the dummy app ships
    # none, so stand one in (mirroring the host contract: < ActionController::Base
    # + the shared error-handling concern) and let Zeitwerk autoload the real
    # controller onto it.
    Object.const_set(:ApplicationController, Class.new(ActionController::Base) {
      include Studio::ErrorHandling
    }) unless Object.const_defined?(:ApplicationController)

    filters = StyleController._process_action_callbacks.map(&:filter)
    assert_includes filters, :require_admin,
      "StyleController must gate index with before_action :require_admin"
    assert StyleController.method_defined?(:index) ||
           StyleController.private_method_defined?(:index),
      "StyleController must define the index action"
  end

  # --- 4. the view references every primitive family -------------------------

  REQUIRED_CLASSES = %w[
    btn btn-primary btn-secondary btn-success btn-danger btn-warning
    btn-neutral btn-outline btn-google btn-sm btn-lg
    card card-hover badge input-field empty-state label-upper
    studio-border-glow spinner loading-dots sheen ping fade-edge progress-meter
  ].freeze

  REQUIRED_THEME_TOKENS = %w[
    --color-cta --color-surface --color-success --color-danger
    --color-warning --color-text --color-border-strong
  ].freeze

  # The four EFFECT primitives added to engine-motion.css — real engine classes
  # the Effects group specimens, so they belong in the referenced-class contract.
  REQUIRED_EFFECT_CLASSES = %w[
    text-gradient studio-glow surface-glass conic-surface
  ].freeze

  # Theme is the landing section; the section order the nav pills follow.
  SECTION_ANCHORS = %w[theme modals tricks tasks].freeze

  def render_index
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    # A host renders this page through ApplicationController, which has EVERY
    # engine helper mixed in (the engine sets no isolate_namespace, so its
    # app/helpers join the host's helper path). This bare view has none, so give
    # it the whole set — naming one module would model a weaker host than any real
    # one, and would need editing again for the next helper-backed specimen.
    view.extend(Studio::Engine.helpers)
    view.render(template: "style/index")
  end

  test "the view is a bare content wrapper (no host layout of its own)" do
    html = render_index
    assert_includes html, "Style", "expected the page heading"
    refute_includes html, "<html", "a bare content wrapper must not emit its own <html> shell"
    refute_includes html, "<body", "a bare content wrapper must not emit its own <body> shell"
  end

  # The "at" format is the first specimen family that is a HELPER rather than a
  # CSS class, so REQUIRED_CLASSES cannot cover it. What makes the specimens real
  # is the pair: live stamps from the helper AND the script that localizes them.
  # The hold-to-confirm specimens. Three, and each proves something different:
  # the fizz on its own, the button live, and the button re-themed from an
  # ancestor with no new CSS. A broken partial path here 500s the whole page in
  # every host, so this renders them rather than string-matching the source.
  test "the Tricks section stages the hold-to-confirm button and its fizz" do
    doc = Nokogiri::HTML.fragment(render_index)

    buttons = doc.css(".hold-stack > button.hold-btn")
    assert_operator buttons.size, :>=, 2,
      "expected a live hold button specimen and a re-themed one"

    # Every staged stack has its bubbles as a SIBLING of the button — the shape
    # that lets them sit behind it.
    doc.css(".hold-stack").each do |stack|
      assert stack.at_css("> .hold-fizz"), "each staged stack renders its fizz layer"
      assert_nil stack.at_css("button.hold-btn .fizz-bit"),
        "no bubble may render inside the button"
    end

    # The standalone fizz specimen binds a palette, so its bubbles resolve to
    # slots rather than their fallback hues.
    palette = doc.css(".hold-stack[style*='--fizz-c-1:']")
    assert_operator palette.size, :>=, 1, "a specimen must show the palette binding"

    # The re-themed one drives the --hold-* inputs, which is the whole claim of
    # the third specimen: one instance restyled without touching the stylesheet.
    rethemed = doc.at_css("[style*='--hold-success-to']")
    assert rethemed, "expected a specimen re-theming the button from an ancestor"
    assert rethemed.at_css(".hold-btn"), "and it must actually contain a button"
  end

  test "the Tricks section stages the 'at' time-stamp primitive" do
    html = render_index
    stamps = Nokogiri::HTML.fragment(html).css("time[data-at-stamp]")

    assert_operator stamps.size, :>=, 4,
      "expected the at-format specimens to render LIVE stamps, not hand-written markup"

    stamps.each do |stamp|
      refute_empty stamp["data-at-epoch"].to_s,
        "every stamp carries the epoch the client re-stamps from"
      assert stamp.at_css("[data-at-text]"), "every stamp needs the text slot the client rewrites"

      flag = stamp.at_css("[data-at-flag]")
      assert flag, "every stamp needs the flag slot the client fills"
      assert_equal "", flag.text,
        "the server must never assert a country — it cannot know the reader's timezone"
    end
  end

  # THE CLAIM THE WHOLE ADOPTION STORY RESTS ON: a host writes `at_time_tag` in a
  # view and it just works, because the engine sets no isolate_namespace and its
  # app/helpers join the host's helper path. Every other test here extends a bare
  # view by hand, which would keep passing if that inheritance broke — so pin it
  # against a REAL host controller, where nothing was extended by us.
  test "a host controller gets the engine's helpers with no wiring" do
    assert_includes PagesController._helpers.instance_methods, :at_time_tag,
      "a host must reach at_time_tag through plain helper inheritance — if this fails, " \
      "every README recipe and every specimen is wrong about adoption"
  end

  # THE RE-STAMPER MUST BE ABLE TO RUN, WHICH IS NOT THE SAME AS BEING PRESENT.
  #
  # The first version of this guard was `assert_includes html, "__atTimeFmt"`. It
  # was written to catch exactly the failure it then MISSED: a close-tag inside the
  # partial's leading ERB comment ended that comment early, so the remaining prose
  # rendered as page text — and because the prose named a script tag inside angle
  # brackets, the browser opened a phantom element that swallowed the real script
  # and the genuine close tag closed the phantom. The bytes "__atTimeFmt" were
  # still on the page. Nothing executed. Every reader of the design system, and of
  # every page of any host following the documented recipe, silently got
  # app-timezone stamps with no flag.
  #
  # So this asserts the STRUCTURE the browser will build, not the presence of a
  # string. Review re-proved it by mutation on 2026-08-11: reintroduce the leaked
  # prose and the retired one-liner still PASSES while this one fails, naming the
  # text that swallowed the script.
  # (The behavior itself — that it runs and localizes — is proven in a real engine
  # by the consuming app's Playwright lane: mcritchie-studio's
  # e2e/at_time_flag.spec.js.)
  test "the at-format re-stamper is a well-formed script element, not text that merely contains it" do
    doc = Nokogiri::HTML.fragment(render_index)
    carriers = doc.css("script").select { |s| s.text.include?("__atTimeFmt") }

    assert_equal 1, carriers.size, "expected exactly one script to carry the re-stamper"

    # THE assertion. Parse the page the way a browser does and demand that the
    # element carrying the re-stamper BEGINS with it. Leaked prose ahead of the
    # real open tag lands inside this element's content — so anything before the
    # IIFE means a phantom element swallowed the script and nothing will execute.
    # (A raw count of open vs close tags cannot serve here: an unrelated engine
    # script legitimately names a script tag inside a JS comment.)
    assert carriers.first.text.lstrip.start_with?("(function"),
      "the re-stamper's script element must BEGIN with its IIFE — anything before it is " \
      "leaked page text that has swallowed the script, and nothing will execute. Saw: " \
      "#{carriers.first.text.lstrip[0, 80].inspect}"
  end

  test "the view references every primitive family's class" do
    html = render_index
    REQUIRED_CLASSES.each do |klass|
      assert_includes html, klass,
        "the Tricks gallery must render a specimen using .#{klass}"
    end
  end

  test "the Tricks section references the four effect primitives" do
    html = render_index
    REQUIRED_EFFECT_CLASSES.each do |klass|
      assert_includes html, klass,
        "the Effects group must render a specimen using .#{klass}"
    end
  end

  test "the section nav links all four sections to matching anchor targets" do
    html = render_index
    SECTION_ANCHORS.each do |anchor|
      assert_includes html, %(href="##{anchor}"),
        "the section nav must link to ##{anchor}"
      assert_includes html, %(id="#{anchor}"),
        "section ##{anchor} must exist as an anchor target"
    end
  end

  test "the sections render in order: Theme (landing), Modals, Tricks, Tasks" do
    html = render_index
    positions = SECTION_ANCHORS.map { |id| html.index(%(id="#{id}")) }
    refute_includes positions, nil, "every section anchor must be present"
    assert_equal positions, positions.sort,
      "sections must appear in order Theme, Modals, Tricks, Tasks"
  end

  test "the color role tokens live in the Theme section, not Tricks" do
    html = render_index
    theme_start  = html.index('id="theme"')
    modals_start = html.index('id="modals"')
    refute_nil theme_start
    refute_nil modals_start
    theme_slice = html[theme_start...modals_start] # Theme first, Modals second
    REQUIRED_THEME_TOKENS.each do |token|
      assert_includes theme_slice, token,
        "Theme owns the color role token #{token} (moved out of Tricks)"
    end
    assert_includes theme_slice, "The colors",
      "Theme leads with the colors block"
    refute_includes html, "Theme tokens",
      "the Tricks section no longer carries a 'Theme tokens' sub-section"
  end

  # --- 6. Modals: page-scoped store opens the real engine card blocks --------

  test "the Modals section wires live engine-block modals via the dsModals store" do
    html = render_index
    assert_includes html, 'id="modals"'
    assert_includes html, "Alpine.store('dsModals'",
      "the Modals section registers its own page-scoped modal store"
    %w[ds-processing ds-success ds-error ds-countdown].each do |id|
      assert_includes html, "$store.dsModals.open('#{id}')",
        "the gallery must wire an Open for the #{id} specimen"
    end
    assert_includes html, "Entry confirmed", "ds-success renders the real success card block"
    assert_includes html, "Something went wrong. Give it another try.",
      "ds-error renders the real error card block"
  end

  # --- 6b. the ported Turf Monster modals register + open ---------------------

  # The page-scoped host (dsModals) mirrors the shared host's full API — the
  # in-modal step machine relies on advance() and the directional swap().
  test "the dsModals store exposes the full host API (open/swap/advance/close)" do
    html = render_index
    %w[open: swap: advance: close: cardClasses: current:].each do |method|
      assert_includes html, method,
        "the page-scoped modal store must define #{method}"
    end
    assert_includes html, "modal-card-mount",
      "cardClasses drives the ported enter animation classes"
    assert_includes html, "dsSolanaModal",
      "the on-chain-tx modal reads through the dsSolanaModal proxy"
  end

  # Every ported modal registers a single-root <template x-if> on its id in the
  # page overlay.
  test "the overlay registers the ported modal ids" do
    html = render_index
    %w[auth crop-photo saving wallet-connect onchain-tx wallet-deposit
       template-wizard template-form template-action template-status
       template-success].each do |id|
      assert_includes html, "$store.dsModals.current().id === '#{id}'",
        "the overlay must register the #{id} modal"
    end
  end

  # --- 6c. Web3 Contest + Contest entry & eligibility flows -------------------

  # The Modals sub-sections rename ("Web3" -> "Web3 Contest", "Eligibility &
  # entry" -> "Contest entry & eligibility") and reorder (entry sits DIRECTLY
  # under Web3 Contest).
  def modals_subheadings(html)
    modals_start = html.index('id="modals"')
    tricks_start = html.index('id="tricks"')
    refute_nil modals_start, "the Modals section anchor must exist"
    refute_nil tricks_start, "the Tricks section anchor must exist"
    slice = html[modals_start...tricks_start]
    slice.scan(%r{text-xl font-bold text-heading">([^<]+)</h3>}).flatten
  end

  test "the Modals sub-sections rename Web3 Contest + Contest entry, in the right order" do
    headings = modals_subheadings(render_index)

    web3     = headings.index("Web3 Contest")
    entry    = headings.index("Contest entry &amp; eligibility")
    leveling = headings.index("Profile Leveling")

    refute_nil web3,  "the Web3 section is renamed to Web3 Contest"
    refute_nil entry, "the section is renamed to Contest entry & eligibility"
    refute_nil leveling, "Profile Leveling still present"

    refute_includes headings, "Web3", "the bare 'Web3' heading is gone (renamed to Web3 Contest)"
    refute_includes headings, "Eligibility &amp; entry", "the old heading is gone"

    assert_operator leveling, :<, web3, "Web3 Contest follows Profile Leveling"
    assert_equal web3 + 1, entry,
      "Contest entry & eligibility sits DIRECTLY under Web3 Contest (no section between)"
  end

  test "the Web3 Contest walk + Contest entry flow wire every specimen Open affordance" do
    html = render_index

    # Web3 Contest walk: Connect Wallet -> Processing -> On-chain success/error.
    assert_includes html, "$store.dsModals.open('wallet-connect')"
    assert_includes html, "$store.dsModals.open('onchain-tx', { state: 'processing'"
    assert_includes html, "$store.dsModals.open('onchain-tx', { state: 'success'"
    assert_includes html, "$store.dsModals.open('onchain-tx', { state: 'error'"
    # Picking a wallet continues the walk (swaps to the processing modal).
    assert_includes html, "Alpine.store('dsModals').swap('onchain-tx'"

    # Contest entry flow: Entry tokens -> Payment processing -> Minted -> enter -> entered.
    %w[picker confirming minted entering entered].each do |step|
      assert_includes html, "$store.dsModals.open('entry-tokens', { step: '#{step}'",
        "the entry flow wires an Open for the #{step} step"
    end
  end

  test "the Processing card success/error toggle flips the resolved on-chain state" do
    html = render_index

    # The per-card toggle (like the leveling toggle) — a checkbox bound to opts.demoError.
    assert_includes html, %(x-model="opts.demoError"), "the Processing card carries a demoError toggle"
    assert_includes html, "Resolve to error", "the toggle is labeled"
    # The toggle flows into the open() call as demoError.
    assert_includes html, "demoError: opts.demoError"

    # The on-chain-tx modal branches on demoError: checked -> error, unchecked -> success.
    assert_includes html, "entry.props.demoError", "the auto-resolve reads the demoError flag"
    assert_includes html, "advance({ state: 'error'", "checked resolves to the error state"
    assert_includes html, "advance({ state: 'success'", "unchecked resolves to the success state"
  end

  test "the minimum-visible-duration convention ships and the demo load modals honor it" do
    html = render_index

    # The single convention definition (rendered by the page + the shared host).
    assert_includes html, "window.StudioModals.holdAtLeast", "holdAtLeast helper ships"
    assert_includes html, "MIN_LOAD_MS = window.StudioModals.MIN_LOAD_MS || 1400",
      "the standard default min duration ships"
    # resolveAt = max(min_duration, actual): the anti-flicker floor math.
    assert_includes html, "Math.max(0, minMs - (Date.now() - startedAt))",
      "holdAtLeast waits the remainder of the floor"

    # _processing_card's reusable prop: the retrofit demos self-resolve after the floor.
    assert_includes html, "window.StudioModals.holdAtLeast(1400).then",
      "_processing_card schedules the demo auto-resolve via the floor"
    assert_includes html, "$store.dsModals.swap('ds-success')",
      "the System Processing specimen auto-advances to success (retrofit)"
    assert_includes html, "$store.dsModals.close()",
      "the Saving specimen self-terminates after the floor (retrofit)"

    # The entry-flow load steps use the convention (not a hardcoded timeout).
    assert_includes html, "window.StudioModals.holdAtLeast(window.StudioModals.MIN_LOAD_MS)",
      "the entry-tokens load steps hold at least MIN_LOAD_MS"
    assert_includes html, "autoAdvance('confirming', { step: 'minted' })",
      "Confirming your purchase advances via the convention"
    assert_includes html, "Confirming your purchase…"
    assert_includes html, "Consuming one token on-chain to create your contest entry",
      "the Contest enter processing step copy is present"
  end

  test "the Contest entry section states the honest web2/web3 map" do
    html = render_index

    # The engine represents the REAL divergence: the token mint is web2-only.
    assert_includes html, "Web2 vs web3", "the section names the web2/web3 map"
    assert_includes html, "mints no token", "web3 funds USDC directly and mints no token"
    assert_includes html, "same on-chain Entry PDA", "both paths converge on the Entry PDA"
    assert_includes html, "web2-only", "the note frames the mint/consume prelude as web2-only"
  end

  # The AUTH suite — the #1 gap. Its bespoke step machine + blocks are present,
  # and the specimens open the real modal at a step.
  test "the Auth modal ports the credentials step machine + its blocks" do
    html = render_index
    # Opened at the credentials step with picksRequired AND the method config the
    # specimen toggles feed (methods { magicLink, google, wallet } + terms).
    assert_includes html, "$store.dsModals.open('auth', { step: 'credentials', picksRequired: 6, methods:",
      "the Sign in specimen opens the auth modal at the credentials step with method config"
    assert_includes html, "$store.dsModals.open('auth', { step: 'magic-link-sent'",
      "a 'magic link sent' variant specimen is wired"
    # The step machine itself.
    assert_includes html, "isCredentialsStep",
      "the auth partial carries the credentials-step guard"
    %w[magic-link-sent magic-link-resent].each do |step|
      assert_includes html, "props.step === '#{step}'",
        "the auth step machine handles the #{step} step"
    end
    # The magic-link CTA runs behind the stub, and the age gate is exercised.
    assert_includes html, "window.postMagicLink",
      "the magic-link CTA no-ops behind the postMagicLink stub"
    assert_includes html, "data-age-attestation",
      "the auth modal renders the legal-age attestation"
  end

  # --- 6c. Modals QoL: conversational copy, toggles, whole-card click, glow ----

  # Item 1 — the specimen header carries an agent-ready CONVERSATIONAL reference
  # (a sentence naming the modal + how to open it), not a raw JS blob copy.
  test "modal specimens copy a conversational reference from the header" do
    html = render_index
    assert_includes html, "Copy an agent-ready reference to this modal",
      "the header Copy affordance is present"
    assert_includes html, %(the Auth "Sign in" modal (studio-engine style/modals/_auth, step 'credentials')),
      "the reference names the modal + partial + step as a sentence"
    assert_includes html, "$refs.ref.textContent",
      "Copy reads the reference text, not a raw snippet"
    # The TITLE itself is the copy control (centered) — the standalone "Copy"
    # text button is gone, and the copy click/keys don't bubble to card-open.
    refute_includes html, %(x-text="copiedRef ? 'Copied' : 'Copy'"),
      "the standalone Copy text button was removed (title is the control)"
    assert_includes html, "@keydown.stop",
      "the title-copy control stops keydown from bubbling to the card open"
  end

  # Item 2b — equal-height cards: each specimen card stretches to its grid row
  # (h-full over a flex column), so a tall card no longer leaves siblings short.
  test "specimen cards stretch to equal height per row (h-full flex column)" do
    html = render_index
    assert_includes html, "flex flex-col h-full",
      "specimen cards use a full-height flex column so a grid row equalizes height"
  end

  # Items 2 + 3 — whole card is the trigger (role=button + keyboard), and the Auth
  # specimen carries the method toggles that gate the modal.
  test "modal specimens are whole-card clickable and carry option toggles" do
    html = render_index
    assert_includes html, 'role="button"',
      "the whole specimen card is a button"
    assert_includes html, "@keydown.enter.prevent",
      "Enter opens the modal (keyboard accessible)"
    assert_includes html, "@keydown.space.prevent",
      "Space opens the modal (keyboard accessible)"
    %w[opts.magicLink opts.google opts.wallet opts.terms].each do |model|
      assert_includes html, %(x-model="#{model}"),
        "the Auth specimen has the #{model} option toggle"
    end
    %w[Magic\ Link Google Solana\ Wallet Terms].each do |lbl|
      assert_includes html, lbl, "the toggle row labels #{lbl}"
    end
  end

  # Item 2 (gating) — the ported auth modal actually GATES each method + terms on
  # props, so the toggles configure a live open.
  test "the auth modal gates each credential method + terms via props" do
    html = render_index
    assert_includes html, "methodOn('google')", "Google is gated"
    assert_includes html, "methodOn('wallet')", "Solana wallet is gated"
    assert_includes html, "methodOn('magicLink')", "magic link is gated"
    assert_includes html, "termsOn()", "the age-attestation terms block is gated"
    assert_includes html, "_methodDefaults", "method defaults come from Studio.auth_method?"
  end

  # Item 4 — the magic-link-resent step has its own specimen.
  test "the Magic link resent step has its own specimen" do
    html = render_index
    assert_includes html, "$store.dsModals.open('auth', { step: 'magic-link-resent'",
      "a magic-link-resent specimen opens that step"
  end

  # Items 5 + 6 — the active-card glow follows the step machine off the store, and
  # Profile lists Image upload BEFORE Crop photo.
  test "the active-card glow is wired off the store, and Profile orders upload before crop" do
    html = render_index
    assert_includes html, "--studio-team-glow-opacity",
      "cards fade the ported glow via the opacity var"
    assert_includes html, "$store.dsModals.current().props.step || 'credentials'",
      "the glow matches the current modal + step reactively"
    upload_at = html.index("Image upload")
    crop_at   = html.index("Crop photo")
    refute_nil upload_at
    refute_nil crop_at
    assert upload_at < crop_at, "Profile must list Image upload before Crop photo"
  end

  # Regression — the glow must FAIL CLOSED. Every glow-capable specimen card
  # carries .studio-team-glow statically, and the primitive's CSS default is
  # --studio-team-glow-opacity: 1 (visible). So the "only the active card glows"
  # behavior rode entirely on the reactive Alpine :style dimming inactive cards to
  # 0 — which means before Alpine hydrates (or if it never loads) ALL reactive-glow
  # cards paint their ring at once (the fail-open flash). The fix renders a STATIC
  # inline --studio-team-glow-opacity: 0 beside the reactive :style so the ring is
  # OFF at first paint. Assert the RENDERED attributes on real glow-card elements
  # (not a source substring), and that the reactive 0<->0.95 fade still drives.
  test "specimen glow cards default to opacity 0 (fail-closed) and keep the reactive fade" do
    doc = Nokogiri::HTML.fragment(render_index)
    # A specimen glow card = .studio-team-glow that ALSO carries the reactive
    # :style binding (this is what distinguishes it from the always-on Tricks demos).
    glow_cards = doc.css(".studio-team-glow").select do |el|
      el[":style"].to_s.include?("--studio-team-glow-opacity")
    end
    refute_empty glow_cards,
      "expected specimen glow cards wired with the reactive :style binding"

    glow_cards.each do |card|
      assert_equal "--studio-team-glow-opacity: 0", card["style"].to_s.strip,
        "a specimen glow card must render a STATIC inline --studio-team-glow-opacity: 0 " \
        "so the ring is OFF at first paint (fail-closed, before Alpine hydrates)"
      assert_match(/\?\s*'0\.95'\s*:\s*'0'/, card[":style"].to_s,
        "the reactive :style must still drive the glow 0.95 (active) / 0 (inactive) for the cross-fade")
    end

    # The always-on Tricks demos (.studio-team-glow WITHOUT the reactive binding)
    # must NOT get the fail-closed override — they are meant to glow on sight.
    always_on = doc.css(".studio-team-glow").reject do |el|
      el[":style"].to_s.include?("--studio-team-glow-opacity")
    end
    always_on.each do |demo|
      refute_includes demo["style"].to_s, "--studio-team-glow-opacity: 0",
        "the always-on Tricks glow demos must stay visible (no fail-closed override)"
    end
  end

  # Item 7 — the single-color team glow ships in engine-motion.css and renders as
  # its own Tricks specimen, alongside the rainbow border glow (both in the bag).
  test "the studio-team-glow primitive ships in engine-motion.css and Tricks" do
    css = File.read("app/assets/tailwind/studio_engine/engine-motion.css")
    assert_includes css, ".studio-team-glow", "the team glow class is ported"
    assert_includes css, "--studio-team-glow-color", "the glow color is a CSS var (default CTA)"
    assert_includes css, "@keyframes studio-team-glow-spin", "the single-color ring rotation ships"
    refute_match(/rgba\(var\(--color-[^)]+-rgb\)/, css,
      "the port keeps the modern slash-rgb form, never legacy rgba(var(--*-rgb))")

    html = render_index
    assert_includes html, "studio-team-glow rounded-xl",
      "Tricks renders a studio-team-glow specimen"
    assert_includes html, "studio-border-glow",
      "the rainbow border glow specimen is still in the bag"
  end

  # THE PAGE MUST STAGE BOTH SHAPES THE RING SUPPORTS, BECAUSE IT SUPPORTS TWO.
  #
  # .studio-team-glow paints its wedges on pseudos at z-index -1 / -2, and CSS
  # paints an element's background FIRST and its negative-z descendants ON TOP of
  # it (CSS 2.1 Appendix E, steps 1 and 2). Something has to cover the middle or
  # the "ring" washes the whole face. Two things can:
  #
  #   · an opaque CHILD in front (step 3) — the WRAPPER shape, TM's holo-wrap /
  #     holo-card split, what the Modals section's glow cards ship;
  #   · the hole the primitive itself cuts — the CARD shape, a host with its own
  #     background, which is the only shape a live board card can wear (Turbo
  #     targets the card element for replace and remove, so a wrapper around it is
  #     orphaned on every remove).
  #
  # An earlier version of this guard demanded the wrapper shape of EVERY host,
  # which was right while the wrapper was the only shape and wrong the moment the
  # hole landed. So it asserts what is still load-bearing: the page demonstrates
  # both, so neither can quietly stop working. That the hole exists at all is
  # asserted in CSS by EngineMotionCssTest.
  test "the selection glow is staged in both of its documented shapes" do
    doc   = Nokogiri::HTML.fragment(render_index)
    hosts = doc.css(".studio-team-glow")
    refute_empty hosts, "expected the page to stage .studio-team-glow"

    card_shape, wrapper_shape = hosts.partition do |host|
      host["class"].to_s.split.grep(/\Abg-/).any?
    end

    refute_empty card_shape,
      "the Effects specimen must stage the CARD shape — the host carrying its own " \
      "background — since that is the only shape a board card can wear"
    refute_empty wrapper_shape,
      "the Modals glow cards must still stage the WRAPPER shape (bare host + opaque child)"

    wrapper_shape.each do |host|
      refute_empty host.element_children,
        "a background-free glow host has nothing covering its middle unless it has a " \
        "child in front"
    end
  end

  # ...and the specimen must TEACH what it stages: the snippet beside it is
  # copy-paste fuel for an agent, so it has to show the shape that rings AND the
  # second color knob, which is the whole reason a two-type caller reaches for it.
  test "the selection-glow snippet teaches the card shape and the second color" do
    doc = Nokogiri::HTML.fragment(render_index)

    snippet = doc.css("code[x-ref=snippet]").map(&:text).find { |t| t.include?("studio-team-glow") }
    refute_nil snippet, "the selection-glow specimen must ship a copyable usage snippet"

    host_lines = snippet.lines.select { |l| l.include?("studio-team-glow") }
    assert host_lines.any? { |l| l.match?(/\bbg-/) },
      "the recipe must show the glow class and a background on the SAME element — the " \
      "card shape. Saw: #{host_lines.join.strip.inspect}"
    assert_includes snippet, "--studio-team-glow-color-b",
      "the recipe must show the second wedge's color knob, or a two-color caller has " \
      "no way to discover it"
  end

  # PROFILE — crop / upload ACTUALLY open: cropper_assets is rendered on the
  # page (loading cropper.js + the factory) and the specimens open crop-photo.
  test "the Profile crop/upload modals are wired to open live" do
    html = render_index
    assert_includes html, "cropPhotoModal",
      "studio/cropper_assets is rendered so the crop factory is defined"
    assert_includes html, "cropperjs",
      "cropper.js is loaded on the page"
    assert_includes html, "$store.dsModals.open('crop-photo', { imageUrl:",
      "the Crop photo specimen opens the crop state"
    assert_includes html, "$store.dsModals.open('crop-photo', { cropReady: false })",
      "the Image upload specimen opens the empty picker (picker sub-state)"
    # The crop modal + saving card mount on the page-scoped store, not the
    # app-level shared host.
    assert_includes html, "cropPhotoModal({ store: 'dsModals' })",
      "the crop modal is mounted on the page-scoped dsModals host"
  end

  # The two Profile specimens open the SAME modal id (crop-photo) but must glow
  # the RIGHT card: the glow discriminates on the crop sub-state (props.cropReady),
  # which the crop factory sets true when the cropper mounts — so the glow moves
  # from Image upload (picker) to Crop photo (cropping) as an image is loaded.
  test "the Profile glow distinguishes crop-photo picker vs crop sub-state" do
    html = render_index
    # Image upload glows only in the picker sub-state; Crop photo only in crop.
    assert_includes html, "$store.dsModals.current().id === 'crop-photo' && !$store.dsModals.current().props.cropReady",
      "Image upload glows only when crop-photo is the empty picker"
    assert_includes html, "$store.dsModals.current().id === 'crop-photo' && !!$store.dsModals.current().props.cropReady",
      "Crop photo glows only when crop-photo has an image loaded"
    # The crop factory reflects the sub-state onto the store so the glow can react.
    factory = File.read("app/views/studio/modals/_image_upload.html.erb")
    assert_includes factory, "cur.props.cropReady = true",
      "mountCropper sets cropReady on the store entry (picker -> cropper transition)"
  end

  # web3 (wallet-connect, on-chain-tx, wallet-deposit) and leveling (level-up)
  # render disabled-but-present-yet-openable when the host has the capability
  # off: greyed + badged, but the trigger keeps its click affordance (a preview
  # you can still open), never inert.
  test "with :web3 and :leveling OFF the capability modal specimens are disabled-but-present-yet-openable" do
    original = Studio.features
    begin
      Studio.features = [] # MS default: web3 + leveling off
      html = render_index

      # The ported modal ids stay present with a working Open affordance.
      %w[wallet-connect onchain-tx wallet-deposit levelup].each do |id|
        assert_includes html, "$store.dsModals.open('#{id}'",
          "the #{id} specimen stays present + openable, not hidden"
      end
      assert_includes html, "disabled on this app",
        "the capability specimens are flagged disabled"
      assert_includes html, 'aria-disabled="true"',
        "the disabled specimens are marked for assistive tech"
      # Openable treatment: the greyed content keeps pointer events (opacity-60
      # grayscale), NOT the inert opacity-40 + pointer-events-none variant.
      assert_includes html, "opacity-60 grayscale",
        "a disabled-but-openable specimen keeps its click affordance"
    ensure
      Studio.features = original
    end
  end

  # --- 7. Theme: the /admin/theme editor folded in + save-in-place -----------

  test "the Theme section folds in the admin/theme role-color editor" do
    html = render_index
    assert_includes html, 'id="theme"'
    assert_includes html, 'action="/admin/theme"',
      "the editor posts to the admin_theme route"
    assert_includes html, 'action="/admin/theme/regenerate"',
      "the regenerate control posts to the admin_theme_regenerate route"
    assert_includes html, 'name="theme_setting[primary]"',
      "the editor renders the role-color inputs"
    assert_includes html, "dsThemeEditor(",
      "the live-preview editor factory is wired"
  end

  test "the Theme section persists Save + Regenerate IN PLACE (no navigation)" do
    html = render_index
    assert_includes html, "@submit.prevent",
      "the Theme forms are intercepted so the page does not navigate away"
    assert_includes html, "saveTheme($event)",
      "Save is intercepted in place"
    assert_includes html, "regenerate($event)",
      "Regenerate is intercepted in place"
    assert_includes html, "fetch(form.action",
      "the section submits via fetch and stays put"
  end

  # --- 8. Tasks: the LIVE board primitive + the static reference -------------

  test "the Tasks section renders the LIVE board primitive over the stage-* reference" do
    html = render_index
    assert_includes html, 'id="tasks"'

    # Phase D: the section now mounts the REAL studio/board primitive in demo mode
    # (drag works, no POST), not just a static sketch.
    assert_includes html, 'data-test="studio-board"',
      "the Tasks section mounts the real studio/board primitive"
    assert_includes html, "studioBoard(",
      "the board is wired to the page-level studioBoard factory"
    assert_includes html, 'id="card-engine-board-primitive"',
      "the specimen renders real demo cards through the card-shell contract"

    # The static reference palette is kept beneath the live primitive.
    %w[stage-fresh stage-shipped stage-closed].each do |stage|
      assert_includes html, stage,
        "the Tasks reference must render the #{stage} palette role"
    end
    assert_includes html, "cursor-grab",
      "the demo cards show the drag / rank affordance"
    assert_includes html, "What every board inherits",
      "the standard-vs-custom reference is present"
  end

  # --- 5. the capability-feature flag + disabled-but-present gating -----------

  test "Studio.feature? is false by default and true once opted in" do
    original = Studio.features
    begin
      Studio.features = []
      refute Studio.feature?(:leveling), "features default to [] (all off)"

      Studio.features = %i[leveling web3]
      assert Studio.feature?(:leveling), "an opted-in feature reads true"
      assert Studio.feature?("web3"), "feature? accepts a String too"
      refute Studio.feature?(:missing), "a feature not opted in reads false"
    ensure
      Studio.features = original
    end
  end

  test "with :leveling OFF the Tricks leveling specimens render disabled-but-present" do
    original = Studio.features
    begin
      Studio.features = [] # MS default: leveling off
      html = render_index

      assert_includes html, "Leveling",
        "the leveling sub-section heading is present"
      assert_includes html, "level-badge-10",
        "the leveling specimen stays present, not hidden"
      assert_includes html, "disabled on this app",
        "the disabled-but-present specimen is flagged"
      assert_includes html, 'aria-disabled="true"',
        "the disabled specimen is marked for assistive tech"
    ensure
      Studio.features = original
    end
  end

  # --- 9. the REAL level-badge tiers render + the engine ships the ladder -----

  test "the Tricks Leveling group renders the real level-badge tiers" do
    html = render_index
    (1..10).each do |lvl|
      assert_includes html, "level-badge-#{lvl}",
        "the Leveling group must render tier .level-badge-#{lvl}"
    end
    assert_includes html, "level-up-pop",
      "the Leveling group must render the .level-up-pop burst demo"
  end

  test "engine-motion.css ships the ported level-badge ladder in the modern rgb form" do
    css = File.read("app/assets/tailwind/studio_engine/engine-motion.css")
    assert_includes css, ".level-badge {", "the .level-badge base is ported"
    (1..10).each do |lvl|
      assert_includes css, ".level-badge-#{lvl}", "tier .level-badge-#{lvl} is ported"
    end
    assert_includes css, "@keyframes level-holographic", "the L10 holographic keyframe is ported"
    assert_includes css, "@keyframes level-shimmer",     "the L9 shimmer keyframe is ported"
    assert_includes css, ".level-up-pop",  "the level-up burst is ported"
    assert_includes css, ".badge-with-sheen", "the sheen wrapper is ported as a plain class"
    # The port must NOT reintroduce TM's broken legacy rgba(var(--*-rgb), a) form —
    # a space-separated rgb var is invalid inside legacy rgba() and silently drops.
    refute_match(/rgba\(var\(--color-[^)]+-rgb\)/, css,
      "space-separated rgb vars must use the modern slash form rgb(var(...) / a)")
  end

  # --- 10. the Confetti & pulse Tricks group renders all three specimens -------

  test "the Tricks Confetti & pulse group renders both confetti effects + the pulse" do
    html = render_index
    assert_includes html, "Confetti &amp; pulse",
      "the Tricks section carries a Confetti & pulse group heading"

    # Confetti card-burst — the callable is named prominently AND wired to a live
    # 'fire it' demo that aims at the specimen card.
    assert_includes html, "window.studioConfetti.burst(el)",
      "the burst specimen surfaces the window.studioConfetti.burst call name"
    assert_includes html, "window.studioConfetti.burst($refs.burstCard)",
      "the burst specimen has a live 'Fire burst' demo aimed at the card"

    # Confetti side-cannons — named + a live 'fire it' demo.
    assert_includes html, "window.studioConfetti.cannons()",
      "the cannons specimen surfaces the window.studioConfetti.cannons call name"
    assert_includes html, "Fire cannons",
      "the cannons specimen has a live 'Fire cannons' demo button"

    # Pulsing button — the .pulse-cta class specimen rides a real .btn.
    assert_includes html, "btn btn-primary pulse-cta",
      "the pulse specimen renders a real .btn with .pulse-cta"
    assert_includes html, ".pulse-cta",
      "the pulse specimen surfaces the .pulse-cta class name"
  end
  # --- 11. the onboarding chain is shown as ONE sequence ----------------------
  #
  # The chain is three modals sharing ONE progress pill, and until 2026-08-24 the
  # page rendered step 1 in the Onboarding section, step 2 in "Contest entry &
  # eligibility", and step 3 nowhere at all — so it showed a 1-of-3 pill and a
  # 2-of-3 pill and never a 3-of-3, which is the one thing a pill exists to be
  # read against. These tests hold the reunification in place; a card drifting
  # back out of the section is exactly the regression they exist to catch.

  # Nokogiri, not string matching: "does this label appear on the page" cannot
  # tell WHICH section it appears in, and the section is the whole point here.
  def section_html(heading)
    doc = Nokogiri::HTML(render_index)
    h3  = doc.css("h3").find { |n| n.text.strip == heading }
    assert h3, "no section heading #{heading.inspect} on the page"
    h3.ancestors("section").first.to_html
  end

  ONBOARDING_CHAIN = ["First name", "Age gate (DOB)", "Wallet setup"].freeze

  # Rails.root is the DUMMY app in this suite, not the engine — a source read
  # rooted there silently looks in test/dummy and raises ENOENT. Engine files
  # resolve through Studio::Engine.root.
  WALLET_SETUP_SPECIMEN =
    Studio::Engine.root.join("app/views/style/modals/_wallet_setup.html.erb").freeze

  test "the Onboarding section carries all three chain steps, in walked order" do
    section = section_html("Onboarding")
    positions = ONBOARDING_CHAIN.map do |label|
      idx = section.index(label)
      assert idx, "chain step #{label.inspect} is missing from the Onboarding section"
      idx
    end
    assert_equal positions.sort, positions,
      "the chain steps must appear in walked order #{ONBOARDING_CHAIN.join(' -> ')} — " \
      "the pill sequence is unreadable if the cards are out of order"
  end

  test "the age gate no longer sits in the contest-entry section" do
    # It is ENFORCED at contest entry, which is why it lived there; its CARD
    # belongs with the chain it walks. The section keeps a note saying so.
    section = section_html("Contest entry & eligibility")
    assert_not_includes section, "Age gate (DOB)",
      "the age gate specimen moved to Onboarding — a copy here splits the pill sequence again"
  end

  test "the contest-entry walk still resumes from the age gate after the move" do
    # The move must not break the demo: confirming the gate advances to Entry
    # tokens through page-level wiring on the primitive's own 'age-verified' hook.
    html = render_index
    assert_includes html, "@age-verified.window=",
      "the page-level age-verified wiring is what carries the entry walk"
    assert_includes html, "$store.dsModals.open('entry-tokens', { step: 'picker' })",
      "confirming the age gate must still advance to the Entry tokens picker"
  end

  # --- 12. the wallet-setup specimen ------------------------------------------

  test "the wallet setup specimen renders and is registered on the guide's host" do
    html = render_index
    assert_includes html, "$store.dsModals.current().id === 'wallet-setup'",
      "the specimen needs a registration on the page-scoped host or the card opens blank"
    assert_includes html, "Set up your wallet",
      "the wallet setup card renders its title"
  end

  test "the wallet setup specimen fills the 3-of-3 pill" do
    # This card is the ONLY one that completes the chain's pill. If it stops
    # rendering the pill, the section's whole reason for grouping evaporates.
    section = section_html("Onboarding")
    assert_includes section, "Wallet setup"
    html = render_index
    assert_includes html, "$store.dsModals.open('wallet-setup', { detected: opts.detected })",
      "the card opens through its own detected toggle"
  end

  test "the wallet setup specimen composes engine chrome rather than copying it" do
    # The Tier-2 contract: an app-specific flow may live here, but only if it is
    # built from engine blocks. A specimen that hand-rolls its own chrome is a
    # second copy of the shell/pill/brand marks, which is what this catches.
    source = WALLET_SETUP_SPECIMEN.read
    %w[shell progress_pill wallet_brand_sprite].each do |block|
      assert_includes source, %(studio/modals/blocks/#{block}),
        "the specimen must compose the engine's #{block} block, not re-draw it"
    end
  end

  test "the wallet setup specimen keeps its x-data free of quote killers" do
    # Same failure mode the host apps guard: a double quote inside the
    # double-quoted x-data closes the attribute early and Alpine mounts the
    # component as a SILENT no-op — every markup assertion above still passes
    # while the card is dead in a browser.
    source = WALLET_SETUP_SPECIMEN.read
    x_data = source[/x-data="(\{.*?\})"\s*\n/m, 1]
    assert x_data.present?, "could not locate the x-data attribute — did the root element change?"
    assert_not_includes x_data, %("), "a double quote closes the attribute early and kills the modal"
    assert_not_includes x_data, "`", "a backtick in an ERB-rendered attribute is the other way this dies"
  end

  # --- 13. one modal id, two cards: the glow must tell them apart --------------

  test "both web3 step-up specimens carry a glow discriminator" do
    # The pair opens the SAME modal id. Before this discriminator existed only
    # the first card passed a glow_when, so opening the SECOND card lit the
    # FIRST — the precise bug a glow helper exists to prevent. ds_glow gained a
    # provider: presence check because the brand is a free-form string with no
    # fixed value for step:/state: to match.
    #
    # ASSERT ON THE FULL CONJUNCT, never the bare expression. "!$store…provider"
    # is a SUBSTRING of "!!$store…provider", so a naive assert_includes for the
    # no-brand form matches the remembered card's expression and passes even when
    # the no-brand card has no glow at all. That is precisely how this test first
    # went green against a deliberately broken page. The "&& " prefix is what
    # makes the two forms mutually exclusive.
    html = render_index
    present = "&& !!$store.dsModals.current().props.provider"
    absent  = "&& !$store.dsModals.current().props.provider"
    refute absent.include?(present) || present.include?(absent),
      "the two glow forms must not be substrings of one another, or neither assertion below bites"

    assert_includes html, present,
      "the remembered-brand card must glow only when a provider is present"
    assert_includes html, absent,
      "the no-brand card must glow only when a provider is absent"
  end

  test "the two step-up thumbnails are visually distinguishable" do
    # They used to differ by ONE border-dashed class on a 20px row, which no
    # reviewer can see — and these two are the likeliest pair on the page to be
    # mistaken for duplicates, because they share a modal id AND a title.
    section = section_html("Web3 Contest")
    assert_includes section, "border border-dashed",
      "the no-brand thumbnail keeps its dashed empty slot"
    assert_includes section, %(<span class="w-4 h-4 rounded shrink-0" style="background: var(--color-primary)"></span>),
      "the remembered thumbnail needs a filled brand tile — a dashed border alone is not a visible difference"
  end

  # --- 14. the Web3 Contest section reads as runs, not a flat list -------------

  test "the Web3 Contest section labels its three runs" do
    # The section advertises a walked flow but had grown to eight cards, only
    # three of which were that walk.
    #
    # ASSERT ON THE h4 ELEMENTS, not on the section's text. Every run name is
    # ALSO written in the section's prose paragraph, so an assert_includes
    # against the section HTML matches the prose and passes with the headings
    # deleted — this test went green against a mutated heading before it read
    # the elements.
    doc     = Nokogiri::HTML(section_html("Web3 Contest"))
    headings = doc.css("h4").map { |h| h.text.split("—").first.to_s.strip }

    ["The walk", "Proving a wallet", "Funding & confirmation"].each do |run|
      assert_includes headings, run,
        "the Web3 Contest section is missing its #{run.inspect} run heading (found: #{headings.inspect})"
    end
  end
end
