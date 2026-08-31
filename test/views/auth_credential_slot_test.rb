# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "action_view"
require "nokogiri"

# [unit] The auth modal's CREDENTIAL SLOT — the seam a web3 layer contributes a
# sign-in button through, so the base template never carries wallet markup.
#
# The architecture this pins: studio-engine plus McRitchie Studio is the base
# template for EVERY app, web2 and web3 alike; solana-studio plus Turf Monster is
# the web3 bolt-on. Sign-in is a base concern, so the auth modal stays here and
# is never forked. Which CREDENTIALS it offers is not a base concern, so the
# wallet button lives in the gem that implements wallets and reaches the modal by
# being on the view path.
#
# WHY A FIXTURE AND NOT THE REAL GEM. This engine does not depend on
# solana-studio and must not — a base template that depended on its own bolt-on
# would invert the whole arrangement. The fixture occupies the same path the gem
# occupies in a real host, so what these tests observe is the ENGINE's half of
# the contract: that it looks, that it renders what it finds, and that finding
# nothing is a survivable outcome rather than a 500.
class AuthCredentialSlotTest < Minitest::Test
  SLOT_PATH = "solana_studio/auth/_wallet_credential"
  LAYER     = "test/views/fixtures/wallet_credential_layer"

  def setup
    @original_auth_methods = Studio.auth_methods
    @original_features     = Studio.features
  end

  def teardown
    Studio.auth_methods = @original_auth_methods
    Studio.features     = @original_features
  end

  # --- the layer is present ---------------------------------------------

  def test_a_contributed_credential_renders_into_the_modal
    web3_app!

    assert contributed_cta(render_auth(with_layer: true)),
           "the engine must render the partial it finds at #{SLOT_PATH}"
  end

  def test_the_contributed_button_lands_inside_the_credentials_step
    web3_app!
    # Placement is the half a "does the string appear" assertion cannot see. The
    # credentials step is the only step where a sign-in CTA means anything; a
    # button rendered outside it would show during "check your inbox".
    cta = contributed_cta(render_auth(with_layer: true))

    refute_nil cta
    assert cta.ancestors.any? { |el| el["x-show"] == "isCredentialsStep" },
           "the contributed credential must render inside the credentials step"
  end

  def test_the_engine_passes_the_modal_store_down
    web3_app!
    # The slot's one required local. A wrong store name fails as a button that
    # does nothing when clicked, which no markup assertion would catch, so the
    # local is required (no default) on the gem side and pinned here.
    cta = contributed_cta(render_auth(with_layer: true))

    assert_includes cta["@click"].to_s, "$store.dsModals.swap(",
                    "the modal store must reach the contributed partial"
  end

  # --- the layer is absent ----------------------------------------------

  def test_a_base_template_app_carries_no_wallet_cta
    web3_app!
    # THE ACCEPTANCE CRITERION, stated as a test: configured for wallet, but with
    # no layer implementing it, the base template renders no wallet button. This
    # is the state a newsletter app built on studio-engine alone is in.
    assert_nil wallet_cta(render_auth(with_layer: false)),
               "the base template must ship no wallet CTA of its own"
  end

  def test_a_missing_layer_renders_instead_of_raising
    web3_app!
    # THE FAIL-SAFE. An app can declare wallet sign-in and forget the gem. That
    # misconfiguration must degrade to a missing button, never to a missing
    # partial error in front of someone trying to sign in. Asserting the OTHER
    # credentials survive proves the modal still did its job.
    html = render_auth(with_layer: false)

    assert_includes html, "methodOn('google')", "Google must still render"
    assert_includes html, "methodOn('magicLink')", "magic link must still render"
  end

  # --- the capability gate ----------------------------------------------

  def test_the_slot_stays_shut_when_the_app_wants_no_wallet
    # McRitchie Studio's shape: it bundles solana-studio for the Ruby signing
    # primitives, so the partial IS on its view path, but it ships web3 off. The
    # layer being installed must not be read as the app wanting the button.
    Studio.auth_methods = %i[magic_link google]
    Studio.features     = []

    assert_nil contributed_cta(render_auth(with_layer: true)),
               "an app that declares no wallet method must render no wallet CTA"
  end

  def test_web3_off_shuts_the_slot_even_with_wallet_declared
    # The hub's CURRENT declaration: :wallet is in auth_methods but no features
    # are set. lib/studio.rb names this exact split, so the slot must honour
    # BOTH halves rather than the auth method alone.
    Studio.auth_methods = %i[magic_link google wallet]
    Studio.features     = []

    assert_nil contributed_cta(render_auth(with_layer: true)),
               "wallet declared without the web3 capability must render nothing"
  end

  def test_the_javascript_default_tracks_the_same_decision
    # One value drives the button, the "or" divider and the style guide's method
    # toggles. When they disagree the divider appears above nothing — the bug
    # this pins. Read the x-data attribute itself, not the document: "wallet:
    # false" occurring in a comment somewhere else would prove nothing.
    web3_app!
    with    = auth_x_data(render_auth(with_layer: true))
    without = auth_x_data(render_auth(with_layer: false))

    assert_includes with,    "wallet: true"
    assert_includes without, "wallet: false"
  end

  private

  def web3_app!
    Studio.auth_methods = %i[magic_link google wallet]
    Studio.features     = %i[web3]
  end

  def render_auth(with_layer:)
    paths = with_layer ? ["app/views", LAYER] : ["app/views"]
    ActionView::Base.with_empty_template_cache
                    .with_view_paths(paths)
                    .render(partial: "style/modals/auth")
  end

  # The fixture's own marker. Distinguishes "the engine rendered the contributed
  # partial" from "the engine drew a wallet button itself", which a bare Solana
  # text match could not tell apart.
  def contributed_cta(html)
    Nokogiri::HTML5.fragment(html).at_css("button[data-contributed-credential='wallet']")
  end

  # ANY wallet call-to-action, however drawn. Anchored on the button element
  # whose x-show is EXACTLY the wallet gate, so it cannot be satisfied by the
  # "or" divider (whose expression merely contains that call) or by prose in a
  # comment. That distinction is the point: after the move the divider still
  # mentions methodOn('wallet') and a substring assertion would pass forever.
  def wallet_cta(html)
    Nokogiri::HTML5.fragment(html).css("button").find do |b|
      b["x-show"].to_s.strip == "methodOn('wallet')"
    end
  end

  def auth_x_data(html)
    Nokogiri::HTML5.fragment(html).at_css("div[x-data]")["x-data"]
  end
end
