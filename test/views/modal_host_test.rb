# frozen_string_literal: true

require "test_helper"
require "action_view"

# Renders the canonical modal host (studio/modals/_host.html.erb) through
# ActionView and pins its contract: the Alpine.store('modals') API surface,
# the animation registry + inline keyframes (upstreamed from Turf Monster's
# shadow copy), dismissal guards, and block-based modal registration. These
# are string assertions on the emitted HTML/JS — the store logic itself runs
# in the browser, but the contract a consumer codes against is all here.
class ModalHostTest < Minitest::Test
  # --- registration -----------------------------------------------------

  def test_block_registered_modal_renders_inside_the_card
    html = render_host_with_block

    assert_includes html, "REGISTERED-MODAL-MARKER"
    # The registration must land inside the card div (after its opening tag)
    # and before the template closes.
    card_index = html.index("cardClasses()\"")
    marker_index = html.index("REGISTERED-MODAL-MARKER")
    close_index = html.rindex("</template>")
    refute_nil card_index
    assert_operator card_index, :<, marker_index
    assert_operator marker_index, :<, close_index
  end

  def test_renders_without_a_block
    html = render_host

    assert_includes html, "Alpine.store('modals'"
  end

  # --- store API surface ------------------------------------------------

  def test_store_exposes_the_full_stack_api
    html = render_host

    # Surface only. What isOpen/isLive actually RETURN across the lifecycle
    # is asserted by executing the store in
    # test/views/modal_host_store_behavior_test.rb — a substring match
    # cannot tell the two apart.
    %w[open: swap: advance: close: closeAll: closeAllDismissible: isOpen: isLive: current: cardClasses:
       _sync:].each do |method|
      assert_includes html, method, "expected Alpine store to define #{method}"
    end
  end

  def test_open_supports_replace_swap_with_direction
    html = render_host

    assert_includes html, "opts.replace"
    assert_includes html, "(opts.direction === 'back') ? 'back' : 'forward'"
    assert_includes html, "_swappingOut"
    assert_includes html, "_swappingIn"
    assert_includes html, "_settled"
  end

  def test_close_delays_splice_by_the_exit_animation_duration
    html = render_host

    assert_includes html, "modalAnim('exit', entry.props && entry.props.exitAnim).ms"
    assert_includes html, "self.stack.splice(idx, 1)"
  end

  def test_close_all_dismissible_keeps_non_dismissible_modals
    html = render_host

    assert_includes html, "modal.props.dismissible === false"
  end

  def test_hold_at_least_helper_ships
    html = render_host

    assert_includes html, "window.StudioModals.holdAtLeast"
  end

  # --- animation registry -----------------------------------------------

  def test_animation_registry_ships_pop_shake_slide_defaults
    entries = registry_entries(render_host)

    # Whitespace-tolerant parse (exact source columns are not the contract).
    # The registry's semantics — merge behavior, cardClasses resolution —
    # are exercised for real in test/views/modal_host_store_behavior_test.rb.
    assert_equal 320, entries["modal-card-mount"], "enter pop"
    assert_equal 600, entries["modal-card-shake-in"], "enter shake"
    assert_equal 220, entries["modal-card-swap-in"], "enter slide"
    assert_equal 220, entries["modal-card-unmount"], "exit pop"
    assert_equal 220, entries["modal-card-swap-out"], "exit slide"
  end

  def test_css_durations_equal_registry_ms_and_store_constants
    html = render_host
    registry = registry_entries(html)
    css = css_durations(html)

    refute_empty registry
    registry.each do |cls, ms|
      assert_equal ms, css[cls],
                   "registry ms for #{cls} must EQUAL its inline CSS animation duration " \
                   "(the store waits registry ms before splicing — a mismatch truncates or freezes the keyframe)"
    end

    close_anim_ms = html[/var CLOSE_ANIM_MS = (\d+)/, 1]&.to_i
    swap_in_ms    = html[/var SWAP_IN_MS\s*= (\d+)/, 1]&.to_i
    refute_nil close_anim_ms
    refute_nil swap_in_ms
    # Phase timing constants must match the keyframes they wait for.
    assert_equal close_anim_ms, css["modal-card-unmount"], "CLOSE_ANIM_MS vs default exit keyframe"
    assert_equal close_anim_ms, css["modal-card-swap-out"], "CLOSE_ANIM_MS vs forward slide-out"
    assert_equal close_anim_ms, css["modal-card-swap-out-back"], "CLOSE_ANIM_MS vs back slide-out"
    assert_equal swap_in_ms, css["modal-card-swap-in"], "SWAP_IN_MS vs forward slide-in"
    assert_equal swap_in_ms, css["modal-card-swap-in-back"], "SWAP_IN_MS vs back slide-in"
  end

  def test_card_binds_registry_driven_classes
    html = render_host

    assert_includes html, ':class="$store.modals.cardClasses()"'
    # Directional swap classes stay fixed names regardless of registry keys.
    %w[modal-card-swap-in modal-card-swap-out modal-card-swap-in-back modal-card-swap-out-back].each do |cls|
      assert_includes html, "'#{cls}'"
    end
  end

  # --- inline keyframe CSS ----------------------------------------------

  def test_keyframes_ship_inline_so_consumers_need_no_extra_css
    html = render_host

    %w[
      modal-card-in modal-card-out modal-backdrop-in modal-backdrop-out
      modal-card-shake-in modal-card-slide-out-right modal-card-slide-in-left
      modal-card-slide-out-left modal-card-slide-in-right
    ].each do |keyframe|
      assert_includes html, "@keyframes #{keyframe}", "expected inline keyframe #{keyframe}"
    end

    %w[
      modal-card-mount modal-card-unmount modal-backdrop-mount modal-backdrop-unmount
    ].each do |cls|
      assert_includes html, ".#{cls} ", "expected inline class .#{cls}"
    end
  end

  def test_reduced_motion_fallback_ships
    html = render_host

    assert_includes html, "@media (prefers-reduced-motion: reduce)"
  end

  def test_legacy_scroll_lock_and_drain_keyframe_survive
    html = render_host

    assert_includes html, "body.modal-open { overflow: hidden; }"
    assert_includes html, "@keyframes studio-modal-drain"
  end

  # --- dismissal + cleanup ----------------------------------------------

  def test_escape_and_click_outside_respect_dismissible_false
    html = render_host

    assert_includes html, "@keydown.escape.window=\"$store.modals.current() && $store.modals.current().props.dismissible !== false && $store.modals.close()\""
    assert_includes html, "@click.self=\"$store.modals.current() && $store.modals.current().props.dismissible !== false && $store.modals.close()\""
  end

  def test_bfcache_and_turbo_cleanup_registered
    html = render_host

    assert_includes html, "window.addEventListener('pageshow'"
    assert_includes html, "document.addEventListener('turbo:before-cache'"
  end

  # --- structure --------------------------------------------------------

  def test_template_x_if_has_a_single_root_element
    html = render_host

    template_body = html[/<template x-if="\$store\.modals\.current\(\)">(.*)<\/template>/m, 1]
    refute_nil template_body, "expected the x-if template wrapper"
    # Exactly one top-level element: the backdrop div opens immediately and
    # every other tag nests inside it (Alpine silently no-ops multi-root
    # x-if templates).
    assert_equal 1, top_level_element_count(template_body),
                 "template x-if must have exactly ONE root element"
  end

  def test_host_bakes_in_zero_modal_registrations
    # Positive invariant (not a spelling blacklist): every modal content
    # registration is CONSUMER-supplied through the block. The engine host
    # itself registers none — rendered without a block it contains zero
    # id-matching registrations; with a block, exactly the one we passed.
    assert_equal 0, registration_count(render_host)
    assert_equal 1, registration_count(render_host_with_block)
  end

  private

  # { "modal-card-mount" => 320, ... } parsed from the ModalAnimations
  # registry literals, whitespace-tolerant.
  def registry_entries(html)
    html.scan(/\{ cls: '([^']+)',\s*ms: (\d+) \}/).to_h { |cls, ms| [cls, ms.to_i] }
  end

  # { "modal-card-mount" => 320, ... } parsed from the inline CSS animation
  # shorthand declarations.
  def css_durations(html)
    html.scan(/\.([a-z][a-z-]*)\s*\{ animation: [a-z-]+\s+(\d+)ms/).to_h { |cls, ms| [cls, ms.to_i] }
  end

  # Count of id-matching modal content registrations in the rendered host.
  def registration_count(html)
    html.scan("$store.modals.current().id ===").size
  end

  def render_host
    view.render(partial: "studio/modals/host")
  end

  def render_host_with_block
    view.render(inline: <<~ERB)
      <%= render "studio/modals/host" do %>
        <template x-if="$store.modals.current().id === 'demo'">
          <div>REGISTERED-MODAL-MARKER</div>
        </template>
      <% end %>
    ERB
  end

  def view
    ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
  end

  # Counts elements sitting directly inside the fragment by walking tag
  # open/close depth. Void/self-closing tags don't appear at the template's
  # top level here, so a plain depth walk is enough.
  def top_level_element_count(fragment)
    depth = 0
    count = 0
    fragment.scan(%r{<(/?)([a-zA-Z][a-zA-Z0-9-]*)[^>]*?(/?)>}) do |closing, _tag, self_closing|
      if closing == "/"
        depth -= 1
      elsif self_closing == "/"
        count += 1 if depth.zero?
      else
        count += 1 if depth.zero?
        depth += 1
      end
    end
    count
  end
end
