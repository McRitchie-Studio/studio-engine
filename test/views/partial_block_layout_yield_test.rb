# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"

# [unit] An engine partial rendered from a LAYOUT must never re-emit the page body.
#
# THE BUG (modal-header-yields-whole-page, found 2026-09-16). ActionView compiles
# every template into a method and ALWAYS calls it with a block — PartialRenderer
# passes `{ |*name| view._layout_for(*name, &block) }` whether or not the caller's
# render had one. So `block_given?` is true inside EVERY partial, and a `yield`
# with no caller block falls through to `_layout_for`'s other branch: the
# layout's content, which is the ENTIRE rendered page body once the layout is
# rendering. turf-monster renders its modal host from the layout, the username
# modal's plain "Saved" card reaches blocks/_card_header with a nil subtitle,
# and the header's `elsif block_given?` branch yielded the whole page a second
# time inside a <template> — ~400 KB per signed-in page that never paints.
#
# Every test renders a page whose body is PAGE_MARKER through a real layout
# (test/views/fixtures/layout_yield_app/layouts/page.html.erb) that renders the
# probe AFTER its own yield, and counts the marker. A count of 2 is the bug.
class PartialBlockLayoutYieldTest < ActiveSupport::TestCase
  ENGINE_ROOT  = File.expand_path("../..", __dir__)
  LAYOUT_APP   = File.join(ENGINE_ROOT, "test/views/fixtures/layout_yield_app")
  PAGE_MARKER  = "PAGE-BODY-MARKER-5c1e"
  BLOCK_MARKER = "CALLER-BLOCK-MARKER-9d04"

  # --- blocks/_card_header: the live leak --------------------------------------

  test "card header with no block and no subtitle does not re-emit the page body" do
    html = render_page(<<~ERB)
      <%= render "studio/modals/blocks/card_header", title: "Saved" %>
    ERB

    assert_page_once html
    assert_includes html, "Saved", "the probe must actually have rendered the header"
  end

  test "card header with a nil subtitle local does not re-emit the page body" do
    # The exact shape turf-monster hit: _leveling_activity forwards
    # `subtitle: confirm_subtitle`, and confirm_subtitle defaults to nil.
    html = render_page(<<~ERB)
      <%= render "studio/modals/blocks/card_header", size: :lg, icon_color: "success", title: "Saved", subtitle: nil %>
    ERB

    assert_page_once html
  end

  test "the username modal inside the modal host does not re-emit the page body" do
    # The production path end to end: layout -> host (real block) -> change_username
    # -> leveling_activity's plain confirm card -> card_header, no subtitle, no block.
    html = render_page(<<~ERB)
      <%= render "studio/modals/host" do %>
        <template x-if="$store.modals.current()?.id === 'username'">
          <%= render "studio/modals/blocks/change_username", current_username: "picker", submit_url: "/u" %>
        </template>
      <% end %>
    ERB

    assert_page_once html
    assert_includes html, "Change Username", "the username modal must actually have rendered"
  end

  test "card header block still fills the subtitle area when rendered from a layout" do
    html = render_page(<<~ERB)
      <%= render "studio/modals/blocks/card_header", title: "Check your inbox" do %>
        <span>#{BLOCK_MARKER}</span>
      <% end %>
    ERB

    assert_page_once html
    assert_match(%r{<p class="text-xs text-secondary mb-5">\s*<span>#{BLOCK_MARKER}</span>\s*</p>}, html,
                 "a caller's block must still render inside the subtitle paragraph")
  end

  test "card header subtitle local still outranks a block" do
    html = render_page(<<~ERB)
      <%= render "studio/modals/blocks/card_header", title: "T", subtitle: "Static subtext" do %>
        #{BLOCK_MARKER}
      <% end %>
    ERB

    assert_includes html, "Static subtext"
    refute_includes html, BLOCK_MARKER
  end

  test "card header with neither subtitle nor block renders no subtitle paragraph outside a layout" do
    # The other half of the predicate. Outside a layout a caller-less yield is
    # EMPTY rather than the page, which content_for(:layout) cannot tell from a
    # real block, so the blank guard decides. Without it this render kept an
    # empty mb-5 paragraph while the same call from a layout dropped it.
    html = view.render(partial: "studio/modals/blocks/card_header", locals: { title: "Saved" })

    assert_includes html, "Saved"
    # /<p[\s>]/, not "<p": the check pill's <path> would match a bare prefix.
    refute_match(/<p[\s>]/, html, "no subtitle and no block must leave no subtitle paragraph")
  end

  # --- blocks/_success_card: same predicate, both slot positions ----------------

  test "success card with an empty block renders no slot wrapper" do
    html = render_page(<<~ERB)
      <%= render "studio/modals/blocks/success_card", title: "Done", cta_label: "Continue", cta_event: "go" do %><% end %>
    ERB

    assert_page_once html
    refute_match(%r{<div class="mt-3">\s*</div>}, html, "an empty block must not leave an empty slot wrapper")
  end

  test "success card with no block does not re-emit the page body below the CTA" do
    html = render_page(<<~ERB)
      <%= render "studio/modals/blocks/success_card", title: "Done", cta_label: "Continue", cta_event: "go" %>
    ERB

    assert_page_once html
  end

  test "success card with no block does not re-emit the page body above the CTA" do
    html = render_page(<<~ERB)
      <%= render "studio/modals/blocks/success_card", title: "Done", cta_label: "Continue", cta_event: "go", slot_position: :above_cta %>
    ERB

    assert_page_once html
  end

  test "success card block renders below the CTA by default and above it on request" do
    below = render_page(<<~ERB)
      <%= render "studio/modals/blocks/success_card", title: "Done", cta_label: "Continue-CTA", cta_event: "go" do %>
        #{BLOCK_MARKER}
      <% end %>
    ERB
    above = render_page(<<~ERB)
      <%= render "studio/modals/blocks/success_card", title: "Done", cta_label: "Continue-CTA", cta_event: "go", slot_position: :above_cta do %>
        #{BLOCK_MARKER}
      <% end %>
    ERB

    [below, above].each { |html| assert_page_once html }
    assert_equal 1, below.scan(BLOCK_MARKER).size, "the block renders exactly once"
    assert_equal 1, above.scan(BLOCK_MARKER).size, "the block renders exactly once"
    assert_operator below.index(BLOCK_MARKER), :>, below.index("Continue-CTA"), "default slot sits below the CTA"
    assert_operator above.index(BLOCK_MARKER), :<, above.index("Continue-CTA"), "above_cta slot sits above the CTA"
  end

  # --- _host / _scoped_host: the registration seam ------------------------------

  test "modal host with no block does not re-emit the page body" do
    # A host rendered bare is a documented shape: an app whose modals all live in
    # app/views/modals/_host_extras registers nothing per callsite.
    html = render_page(<<~ERB)
      <%= render "studio/modals/host" %>
    ERB

    assert_page_once html
  end

  test "modal host block registrations still render from a layout" do
    html = render_page(<<~ERB)
      <%= render "studio/modals/host" do %>
        <template x-if="$store.modals.current()?.id === 'demo'"><div>#{BLOCK_MARKER}</div></template>
      <% end %>
    ERB

    assert_page_once html
    assert_equal 1, html.scan(BLOCK_MARKER).size
  end

  test "scoped modal host with no block does not re-emit the page body" do
    html = render_page(<<~ERB)
      <%= render "studio/modals/scoped_host", store: "demoModals" %>
    ERB

    assert_page_once html
  end

  test "scoped modal host block registrations still render from a layout" do
    html = render_page(<<~ERB)
      <%= render "studio/modals/scoped_host", store: "demoModals" do %>
        <template x-if="$store.demoModals.current()?.id === 'demo'"><div>#{BLOCK_MARKER}</div></template>
      <% end %>
    ERB

    assert_page_once html
    assert_equal 1, html.scan(BLOCK_MARKER).size
  end

  private

  def view
    # Engine helpers mixed in, as ApplicationController gives a host (no
    # isolate_namespace) — change_username's leveling chrome calls them.
    ActionView::Base.with_empty_template_cache
                    .with_view_paths([File.join(ENGINE_ROOT, "app/views"), LAYOUT_APP])
                    .tap { |v| v.extend(Studio::Engine.helpers) }
  end

  def render_page(probe)
    view.render(inline: PAGE_MARKER, layout: "layouts/page", locals: { probe: probe })
  end

  def assert_page_once(html)
    count = html.scan(PAGE_MARKER).size
    assert_equal 1, count,
                 "the page body appears #{count} times in the response (#{html.bytesize} bytes) — " \
                 "a partial rendered from the layout yielded the layout's content back into the page"
  end
end
