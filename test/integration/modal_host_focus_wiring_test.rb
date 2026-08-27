# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

# [integration] The focus wiring must survive RENDERING, with the right store bound.
#
# The e2e specs prove the behaviour in a browser; this proves the seam underneath
# it. _scoped_host takes its store name as a local and interpolates it into every
# binding, so a page that brings its own store ("labModals") must emit
# $store.labModals.captureFocus — not the shared host's $store.modals. That is an
# ERB interpolation fact: it is invisible in the partial's source, where the name
# is a <%= %>, and a browser test cannot distinguish "bound to the wrong store"
# from "the store happens to exist under both names".
class ModalHostFocusWiringTest < ActionDispatch::IntegrationTest
  test "a scoped host binds the focus contract to ITS OWN store" do
    get "/lab/birthday_gate"
    assert_response :success
    html = response.body

    assert_includes html, "$store.labModals.captureFocus($el)",
      "focus capture must be bound to the page's own store; the shared $store.modals " \
      "does not exist here and would throw on open"
    assert_includes html, "$store.labModals.cycleFocus($el, $event)",
      "so must the tab trap"
    assert_includes html, "$store.labModals.dialogLabel()",
      "and the accessible name"

    refute_includes html, "$store.modals.captureFocus",
      "binding the SHARED store on a scoped page is the failure this interpolation exists to prevent"
  end

  test "the dialog is focusable and the card can scroll" do
    get "/lab/birthday_gate"
    html = response.body

    assert_includes html, 'tabindex="-1"',
      "the backdrop must be programmatically focusable, or captureFocus has nothing to focus"
    assert_match(/max-h-\[85dvh\][^"]*overflow-y-auto|overflow-y-auto[^"]*max-h-\[85dvh\]/, html,
      "a card taller than the viewport must scroll — on a non-dismissible card an " \
      "unreachable confirm button is a dead end")
  end
end
