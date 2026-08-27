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
    assert_includes html, "Alpine.store('modals'"
    assert_includes html, "advance: function(propsPatch, opts)"
    assert_includes html, "@keyframes modal-card-in"
    assert_includes html, "window.ModalAnimations"
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
    {
      "studio/modals/host" => {},
      "studio/modals/scoped_host" => { store: "pageModals" }
    }.each do |partial, locals|
      html = ActionController::Base.render(partial: partial, locals: locals)

      assert_includes html, "refocus: function",
                      "#{partial} has no refocus() — a swap releases the focus trap"
      # ANCHORED ON THE RECEIVER, not the bare name. Both hosts DOCUMENT refocus()
      # in prose, so /refocus\(\)/ matches the comment and stays green with every
      # call deleted — mutation caught exactly that. A call has a receiver.
      assert_match(/(?:self|this)\.refocus\(\)/, html,
                   "#{partial} defines refocus() but never CALLS it, which is the same as not " \
                   "having it")
    end
  end

  # Both hosts, rendered through the REAL controller render path, must emit a
  # store script that actually PARSES. The unit harness executes the store
  # under stubs; this asserts the thing that harness cannot see — that what a
  # live Rails app emits is syntactically whole.
  #
  # This is not hypothetical. An ERB comment ends at its FIRST "%" + ">", so a
  # comment body containing one closes early and leaks its prose into the
  # document; if that prose contains a literal script tag it opens a phantom
  # element that swallows the real script in every browser. That shipped once
  # (the propagate-at-format-gem defect). A substring assertion is blind to it;
  # a parse is not.
  test "both modal hosts emit a syntactically whole store script" do
    node = `which node 2>/dev/null`.strip
    refute_empty node,
                 "node runtime NOT FOUND. This test parses the rendered store script; " \
                 "skipping it would report green with zero coverage of script integrity. " \
                 "Install node (mise install node@20) and re-run."

    {
      "studio/modals/host" => {},
      "studio/modals/scoped_host" => { store: "pageModals" }
    }.each do |partial, locals|
      html = ActionController::Base.render(partial: partial, locals: locals)

      # The store lives in each partial's FIRST script block by design.
      script = html[%r{<script>(.*?)</script>}m, 1]
      refute_nil script, "#{partial} must emit a store <script>"

      assert_includes script, "isLive: function(id)",
                      "#{partial} must ship isLive through the real render path"

      Tempfile.create(["rendered_host", ".js"]) do |f|
        f.write(script)
        f.flush
        out = `#{node} --check #{f.path} 2>&1`
        assert $?.success?,
               "#{partial}'s emitted store script does not parse — a truncated ERB comment " \
               "or an unbalanced tag can leak prose into it:\n#{out}"
      end
    end
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
