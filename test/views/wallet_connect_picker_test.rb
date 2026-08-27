# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "action_view"
require "nokogiri"

# The promoted Connect Wallet picker (studio/modals/_wallet_connect) and the
# style-guide specimen that now CONFIGURES it rather than copying it.
#
# Every assertion here exists because the thing it pins broke while the partial
# was being written, and in each case the page still RENDERED — which is the
# whole hazard of an Alpine component assembled through ERB. A picker with no
# hooks, and a picker whose hooks are HTML entities, both look fine.
class WalletConnectPickerTest < Minitest::Test
  # --- the extra_data seam ----------------------------------------------

  def test_extra_data_reaches_the_x_data
    # THE BUG THIS PINS: the first draft passed extra_data through a heredoc
    # written inline in the render tag. ERB closes a tag at its first close
    # marker, so the heredoc body became template TEXT, extra_data arrived
    # empty, and the picker rendered perfectly — minus every hook. Nothing
    # raised. Assert on the x-data ATTRIBUTE, not the document: a hook name
    # appearing anywhere else (a doc comment, a sibling script) proves nothing.
    assert_includes x_data(render_picker(extra_data: "probeHook() { return 42; }")),
                    "probeHook() { return 42; }"
  end

  def test_extra_data_is_appended_after_the_built_ins_not_replacing_them
    xd = x_data(render_picker(extra_data: "probeHook() { return 42; }"))

    assert_includes xd, "probeHook()"
    %w[pick( refresh( deepLink( brandIcon( missingInstalls showPhantomDeepLink].each do |built_in|
      assert_includes xd, built_in, "the built-in #{built_in} must survive an extra_data merge"
    end
  end

  def test_no_extra_data_leaves_a_syntactically_clean_x_data
    xd = x_data(render_picker)

    refute_includes xd, ",\n       \n", "an empty extra_data must not leave a dangling comma"
    assert_includes xd, "back() {"
  end

  def test_extra_data_is_not_html_escaped
    # THE BUG THIS PINS: marking extra_data html_safe is not enough — building
    # the fragment by interpolating it into a plain string literal loses the
    # safety, and every quote becomes an entity. That still PARSES, because a
    # browser decodes entities inside an attribute, so the page WORKS and only
    # the source reads wrong. No markup assertion on the document catches it.
    xd = x_data(render_picker(extra_data: "onBack() { Alpine.store('dsModals').close(); }"))

    assert_includes xd, "Alpine.store('dsModals').close();"
    refute_includes xd, "&#39;", "the developer-authored fragment must not be entity-escaped"
  end

  # --- the store and connect_fn locals -----------------------------------

  def test_store_local_rewires_every_store_reference
    html = render_picker(store: "dsModals")

    assert_includes html, "$store.dsModals.current()"
    assert_includes html, "Alpine.store('dsModals').close()"
    refute_includes html, "$store.modals.", "no default-store reference may survive an override"
  end

  def test_defaults_target_the_shared_host_and_the_house_connect_function
    html = render_picker

    assert_includes html, "$store.modals.current()"
    assert_includes html, "window.solanaConnectAndVerify(name, opts)"
  end

  def test_connect_fn_local_rewires_the_connect_call
    html = render_picker(connect_fn: "dsWalletConnectDemo")

    assert_includes html, "window.dsWalletConnectDemo(name, opts)"
    refute_includes html, "window.solanaConnectAndVerify("
  end

  # --- structure ---------------------------------------------------------

  def test_single_root_element
    # The host mounts this inside a template x-if, and Alpine requires exactly
    # one root. A second top-level node is dropped silently.
    html = render_picker.strip

    assert_equal 1, top_level_element_count(html)
    # ...and the counter can actually SEE a second root. Without this the
    # assertion above passed on a two-root document.
    assert_equal 2, top_level_element_count("#{html}\n<div>second root</div>")
  end

  def test_the_named_slot_renders_inside_the_root
    html = render_picker(slot: "studio/modals/shared/age_attestation")

    # It must sit inside the component root or it cannot see the x-data scope
    # extra_data contributes to — which is the entire point of the slot.
    assert_includes root_inner_html(html), "data-age-attestation"
  end

  def test_the_slot_takes_its_own_locals
    html = render_picker(slot: "studio/modals/shared/age_attestation",
                         slot_locals: { x_model: "probeModel" })

    assert_includes root_inner_html(html), %(x-model="probeModel")
  end

  def test_no_slot_renders_nothing_in_its_place
    refute_includes render_picker, "data-age-attestation"
  end

  # --- the slot must NOT be a block (the leak this partial shipped once) ------

  def test_rendering_without_a_slot_through_a_layout_leaks_nothing
    # THE BLOCKER THIS PINS, found in review. The first version took the slot as
    # a BLOCK and guarded it with `yield if block_given?`. `block_given?` is
    # ALWAYS TRUE inside a compiled Rails partial — PartialRenderer hands the
    # template a block either way — so with no caller block the yield fell
    # through to view_flow[:layout] and printed THE ENTIRE CAPTURED PAGE BODY
    # inside the wallet card. Both apps mount the modal host in
    # application.html.erb, which is precisely when that flow is populated, and
    # the hub's planned adoption is a bare render with no slot.
    #
    # THIS IS THE ONLY TIER THAT SEES IT. Every other test here renders the
    # partial DIRECTLY, and a direct render has no layout flow to leak — the one
    # path that stays clean. So this one renders through a layout, the way an
    # app actually does.
    html = render_picker_through_layout

    assert_includes html, "LEAKABLE-PAGE-BODY",
                    "the harness must actually populate the layout flow, or this proves nothing"
    refute_includes root_inner_html(html), "LEAKABLE-PAGE-BODY",
                    "the page body leaked into the wallet card"
  end

  def test_the_brand_sprite_definition_rides_inside_the_root
    # A sibling of the root is DROPPED by the host's template clone, and the
    # rows below then reference symbol ids nothing ever painted.
    #
    # Assert on the symbol DEFINITION, not on the id string. "se-wallet-phantom"
    # appears twice in this partial — once defining the symbol and once in the
    # deep-link row's <use href>. The <use> lives inside the root no matter where
    # the sprite goes, so an id-substring check is satisfied by the reference
    # alone and stays green with the sprite moved out entirely. Proved by
    # mutation: this test passed with the sprite relocated past the root's close.
    assert_includes root_inner_html(render_picker), %(<symbol id="se-wallet-phantom")
  end

  # --- the mobile Phantom contract (inherited from turf PR 472) ----------

  def test_mobile_collapses_phantom_to_a_single_row
    xd = x_data(render_picker)

    # The install list suppresses Phantom on mobile...
    assert_includes xd, "if (self.isMobile && i.name === 'Phantom') return false;"
    # ...and the deep-link row is the one that appears, only when Phantom is
    # NOT already injected (inside Phantom's own browser the detected row wins).
    assert_includes xd, "return this.isMobile && !this.hasWallet('Phantom');"
  end

  def test_the_deep_link_row_uses_the_engine_sprite_not_an_app_png
    html = render_picker

    assert_includes html, %(<use href="#se-wallet-phantom">)
    refute_includes html, "phantom-white.png", "the picker must not reach for a per-app asset"
  end

  # --- announcement -------------------------------------------------------

  def test_the_connect_error_announces
    # FOUND BY ADOPTION. The app markup this was promoted from showed a connect
    # failure and never announced it — the apps are not subject to the engine's
    # modal_error_announcement_render_test, so the defect rode along unseen for
    # as long as each app kept its own copy. Pinned here too, on the partial
    # itself, so it cannot regress for a consumer that never renders the guide.
    err = render_picker[%r{<p[^>]*x-text="error"[^>]*>}]

    assert err, "the connect-error paragraph must render"
    assert_includes err, %(role="alert")
  end

  # --- the guide specimen now CONFIGURES this partial --------------------

  def test_the_style_specimen_renders_the_promoted_partial
    html = view.render(partial: "style/modals/wallet_connect")

    # Built-ins prove it is the engine partial, not a copy of it.
    assert_includes html, "showPhantomDeepLink"
    assert_includes html, "window.dsWalletConnectDemo(name, opts)"
    # Hooks prove the configuration reached it.
    assert_includes x_data(html), "onConnected()"
    refute_includes x_data(html), "&#39;"
  end

  private

  def view
    ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
  end

  def render_picker(**locals)
    view.render(partial: "studio/modals/wallet_connect", locals: locals)
  end

  # The picker renders FROM THE LAYOUT here, the way an app renders it, so
  # view_flow[:layout] already holds this page body. Rendered from the TEMPLATE
  # the flow is still empty and the leak cannot appear — the arrangement this
  # probe shipped with first, which is why it passed with the bug restored.
  def render_picker_through_layout
    v = ActionView::Base.with_empty_template_cache
                        .with_view_paths(["app/views", "test/views/fixtures/picker_layout"])
    v.render(inline: %(<div>LEAKABLE-PAGE-BODY</div>), layout: "layouts/wallet_picker_probe")
  end

  # The x-data ATTRIBUTE only. Windowing matters: this partial's own doc comment
  # names several hooks, so a document-wide assertion for a hook name is green
  # whether or not the hook reached the component.
  def x_data(html)
    html[/x-data="(.*?)"\s*\n?\s*class="relative"/m, 1].to_s
  end

  # Inner HTML of the component root, by walking div depth to its match. Offset
  # comparisons cannot do this: content moved just past the root's close still
  # sits after the root's opening tag.
  def root_inner_html(html)
    open_at = html.index("<div x-data=")
    return nil unless open_at

    cursor = html.index(">", html.index('class="relative"', open_at))
    return nil unless cursor

    cursor += 1
    depth = 1
    scan = cursor
    while depth.positive?
      m = html.match(%r{<(/?)div\b[^>]*?(/?)>}, scan)
      return nil unless m

      scan = m.end(0)
      if m[1] == "/"
        depth -= 1
        return html[cursor...m.begin(0)] if depth.zero?
      elsif m[2] != "/"
        depth += 1
      end
    end
    nil
  end

  # Nokogiri, not a hand-rolled tag scanner. The scanner this replaced read the
  # row's VOID <img> (no trailing slash, no close tag) as an OPEN element, so its
  # depth never returned to 0 and it answered 1 for ANY number of roots.
  def top_level_element_count(fragment)
    Nokogiri::HTML.fragment(fragment).element_children.length
  end
end
