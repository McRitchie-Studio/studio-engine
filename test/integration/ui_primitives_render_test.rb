# frozen_string_literal: true

# Boots studio-engine inside the real dummy Rails app (test/dummy) and renders
# the flagship UI primitives — the canonical modal host and the slot-based
# user nav — through the full Rails view stack (engine view paths wired by the
# railtie, real partial resolution, real url helpers from Studio.routes). The
# unit view tests (test/views/*) pin the emitted contracts; this proves the
# same partials resolve and render inside a consuming app.

require "bundler/setup"
require "tempfile"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

# Renderer controller for the user-nav: supplies the auth helpers a host app's
# ApplicationController exposes (the partial reads them via helper methods).
class UserNavRenderHostController < ActionController::Base
  helper_method :logged_in?, :current_user

  class StubUser
    def display_name = "Dummy User"
    def avatar = @avatar ||= Class.new { def attached? = false }.new
    def avatar_color = "#0ea5e9"
    def avatar_initials = "DU"
  end

  def logged_in? = true

  def current_user = @current_user ||= StubUser.new
end

class UiPrimitivesRenderTest < ActiveSupport::TestCase
  test "modal host renders through the dummy app with a block registration" do
    html = ActionController::Base.render(inline: <<~ERB)
      <%= render "studio/modals/host" do %>
        <template x-if="$store.modals.current().id === 'demo'">
          <div>DUMMY-REGISTERED-MODAL</div>
        </template>
      <% end %>
    ERB

    assert_includes html, "DUMMY-REGISTERED-MODAL"
    assert_includes html, 'data-studio-controller="modal-host"'
    assert_includes html, 'data-modal-host-store-value="modals"'
    assert_includes html, "@keyframes modal-card-in"
  end

  # THE SHARED HOST'S FOCUS WIRING, which nothing covered until now.
  #
  # Measured by a reviewer's mutation: captureFocus, tabindex=-1, the tab trap AND
  # the max-h/overflow rule were ALL removed from _host.html.erb at once and the
  # entire engine suite stayed green — 102 files, 1455 runs. Only dialogLabel bit.
  # The cause is structural rather than sloppy: every e2e lab page the lane can
  # reach renders the SCOPED host, so the shared one is untested by construction.
  #
  # These are substring assertions on rendered output, which is a weak tier — but
  # weak and present beats absent, and it is the cheapest thing that turns four
  # silent deletions into four red lines.
  test "the shared modal host emits its focus trap wiring" do
    html = ActionController::Base.render(partial: "studio/modals/host")

    assert_includes html, "captureFocus",
                    "the shared host stopped capturing focus on open — the dialog no longer traps"
    assert_includes html, "tabindex=\"-1\"",
                    "the backdrop is no longer focusable, so captureFocus has nothing to land on"
    assert_includes html, "keydown.tab.prevent",
                    "the tab interception is gone; native tabbing walks straight out of the dialog"
    assert_includes html, "cycleFocus",
                    "Tab is intercepted but nothing re-dispatches it — focus would go nowhere"
    assert_match(/max-h-\[|overflow-y-(auto|scroll)/, html,
                 "the scroll rule is gone; a tall card's escape hatch becomes unreachable on a " \
                 "short viewport (measured at 844x390: scroll delta 971px -> 0)")
  end

  # THE REGRESSION THIS PR EXISTS FOR. A swap()/advance() leaves current() truthy,
  # so the outer template never re-mounts and x-init never re-runs captureFocus —
  # focus fell to <body> and the trap released. refocus() closes that, and BOTH
  # hosts must carry it: they diverge only in the scoped store name.
  test "both hosts re-focus the backdrop after the top entry changes" do
    source = File.read(File.expand_path("../../app/javascript/studio/modal_host.js", __dir__))

    assert_includes source, "refocus: function",
                    "the focus trap has no refocus(): a swap releases it"
    { "createModalStore" => "shared", "createScopedModalStore" => "scoped" }.each do |factory, label|
      body = source[/export function #{factory}\(.*?\n}\n/m]
      refute_nil body, "studio/modal_host must define #{factory}"
      # ANCHORED ON THE RECEIVER, not the bare name: the module DOCUMENTS
      # refocus() in prose, so /refocus\(\)/ matches a comment and stays green
      # with every call deleted. A call has a receiver.
      assert_match(/(?:self|this)\.refocus\(\)/, body,
                   "the #{label} store never CALLS refocus(), which is the same as not having it")
    end
  end

  # Both hosts, rendered through the REAL controller render path, emit NO script:
  # the store is studio/modal_host, a nonced module. An ERB comment ends at its
  # FIRST "%" + ">", so a comment body containing one closes early and leaks its
  # prose into the document; prose carrying a literal script tag opens a phantom
  # element (the propagate-at-format-gem defect). So the render must carry no
  # script tag at all, and the module itself must parse.
  test "both modal hosts emit no script, and the module they bind parses" do
    {
      "studio/modals/host" => {},
      "studio/modals/scoped_host" => { store: "pageModals" }
    }.each do |partial, locals|
      html = ActionController::Base.render(partial: partial, locals: locals)
      refute_match(/<script/i, html, "#{partial} must emit no script: its store is studio/modal_host")
      assert_includes html, 'data-studio-controller="modal-host"', "#{partial} must bind the modal-host controller"
    end

    node = `which node 2>/dev/null`.strip
    refute_empty node, "node runtime NOT FOUND (mise install node@20)"
    path = File.expand_path("../../app/javascript/studio/modal_host.js", __dir__)
    out = `#{node} --input-type=module --check < #{path} 2>&1`
    assert $?.success?, "studio/modal_host does not parse:\n#{out}"
  end

  test "user nav renders the hub-style legacy call through the dummy app" do
    html = UserNavRenderHostController.render(
      inline: %(<%= render "components/user_nav", show_logout_link: true %>)
    )

    assert_includes html, "Dummy User"
    assert_includes html, "Log out"
    assert_includes html, "/logout", "expected the real logout route from Studio.routes"
  end

  test "user nav renders partial slots against real engine partials" do
    html = UserNavRenderHostController.render(inline: <<~ERB)
      <%= render "components/user_nav",
            balance_slot: { partial: "components/emoji_swap", locals: { base: "💰", hover: "✨" } },
            div2_slot: "components/theme_toggle" %>
    ERB

    assert_includes html, "studio-emoji-swap", "balance_slot should render the engine emoji_swap partial"
    assert_includes html, "$store.theme.toggle()", "div2_slot should render the engine theme_toggle partial"
    refute_includes html, "seedsNavbar", "div2_slot should replace the default level bar"
  end
end
