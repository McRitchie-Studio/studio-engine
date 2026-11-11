# frozen_string_literal: true

require "test_helper"
require "json"
require "action_view"

# [unit] The shared host's on-demand half (Studio.modals): with nothing
# registered it renders none of it, so every app that registers nothing keeps
# the host it had; with a registration it advertises the ids, marks its card,
# and carries the loading and error cards inside that card. The browser half is
# test/javascript/modal_host_remote.test.mjs and e2e/modal_remote.spec.js.
class ModalHostRemoteTest < Minitest::Test
  # A view with what a host's views have: the route helper and logged_in?.
  module HostHelpers
    attr_accessor :signed_in

    def studio_modal_path(id:) = "/_studio/modals/#{id}"
    def logged_in? = !!signed_in
  end

  def teardown
    Studio.modals.clear!
  end

  def render_host(signed_in: false)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.extend(HostHelpers)
    view.signed_in = signed_in
    view.render(partial: "studio/modals/host")
  end

  def test_nothing_registered_renders_no_on_demand_markup
    Studio.modals.clear!
    html = render_host

    refute_includes html, "data-modal-host-remote-value"
    refute_includes html, "data-modal-host-card"
    refute_includes html, "data-modal-remote-state"
    refute_includes html, "_remote"
  end

  def test_a_registration_advertises_the_ids_on_the_host_template
    Studio.modals.register :rules, partial: "modals/rules"
    Studio.modals.register :auth, partial: "modals/auth", prefetch: true
    Studio.modals.register :wallet, partial: "modals/wallet", auth: :user, prefetch: true

    config = advertised(render_host)
    assert_equal "/_studio/modals/__id__", config["url"]
    assert_equal %w[rules auth wallet], config["ids"]
    assert_equal %w[auth], config["prefetch"], "a signed-out page prefetches no :user modal"

    assert_equal %w[auth wallet], advertised(render_host(signed_in: true))["prefetch"]
  end

  def test_the_card_is_marked_and_carries_the_loading_and_error_cards
    Studio.modals.register :rules, partial: "modals/rules"
    html = render_host

    card_open = html[/<div class="bg-surface rounded-xl[^>]*>/m]
    refute_nil card_open
    assert_includes card_open, "data-modal-host-card"

    card_at = html.index(card_open)
    loading_at = html.index('data-modal-remote-state="loading"')
    error_at = html.index('data-modal-remote-state="error"')
    assert loading_at && loading_at > card_at, "the loading card sits inside the card"
    assert error_at && error_at > card_at, "the error card sits inside the card"
    assert_includes html, "$store.modals._remote[$store.modals.current()?.id] === 'loading'"
    assert_includes html, "$store.modals._remote[$store.modals.current()?.id] === 'error'"
    refute_match(/<script/i, html)
  end

  # ---- engine-modals-fetch-hardening ----

  def test_the_loading_card_is_a_polite_status
    Studio.modals.register :rules, partial: "modals/rules"
    loading = render_host[/<div data-modal-remote-state="loading"[^>]*>/]
    refute_nil loading
    assert_includes loading, 'role="status"'
    assert_includes loading, 'aria-live="polite"'
  end

  def test_the_error_card_offers_try_again_and_a_close_that_ignores_dismissible
    Studio.modals.register :rules, partial: "modals/rules"
    html = render_host
    error_at = html.index('data-modal-remote-state="error"')
    error_card = html[error_at, 3000]
    assert_includes error_card, '@studio-modal-retry="$store.modals.retryRemote()"'
    assert_includes error_card, "$dispatch('studio-modal-retry')"
    assert_includes error_card, "Try again"
    assert_includes error_card, 'x-text="$store.modals.remoteErrorText()"'
    # Close calls close() itself, not the dismissible-gated Escape path.
    assert_match(/@click="\$store\.modals\.close\(\)"[^>]*>\s*Close/m, error_card)
  end

  def test_the_advertisement_carries_the_timeout_session_marker_and_debug
    Studio.modals.register :rules, partial: "modals/rules"
    Studio.modals.fetch_timeout_ms = 9000
    config = advertised(render_host)
    assert_equal 9000, config["timeout_ms"]
    assert_equal Studio::Modals.session_marker(nil), config["session"], "no controller: the constant marker"
    assert_includes [true, false], config["debug"]
  ensure
    Studio.modals.fetch_timeout_ms = Studio::Modals::Registry::DEFAULT_FETCH_TIMEOUT_MS
  end

  private

  def advertised(html)
    raw = html[/data-modal-host-remote-value="([^"]*)"/, 1]
    refute_nil raw, "the host advertises nothing"
    JSON.parse(CGI.unescapeHTML(raw))
  end
end
