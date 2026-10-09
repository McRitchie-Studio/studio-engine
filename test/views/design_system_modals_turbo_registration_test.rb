# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "tempfile"
require "nokogiri"
require "json"

# [component] The /admin/style page-scoped modal store (dsModals) is there
# before Alpine reads it, on a first load and on a Turbo Drive visit alike.
#
# THE FAILURE THIS GUARDS. Alpine fires alpine:init exactly ONCE, on the first
# full-document load. A Turbo Drive advance visit (the admin sidebar's "Design
# System" link) swaps <body> without it firing again, so a store registered only
# on alpine:init is undefined after the visit: every specimen card's @click,
# :style and <template x-if> that reads $store.dsModals throws, modals do not
# open, and the throwing :style wipes each card's static
# --studio-team-glow-opacity: 0 so every glow lights.
#
# HOW THE STORE REGISTERS. The guide's overlay declares itself a modal host
# (data-studio-controller="modal-host", data-modal-host-store-value="dsModals"),
# and studio/modal_host registers every declared host's store: on alpine:init,
# and before a Turbo render from the incoming body.
#
# A string match cannot see this failure, so the declaration is read out of the
# RENDERED page and handed to studio/modal_host, which is executed under node
# with minimal window/document/Alpine stubs in both navigation paths. The
# store's registration is asserted by observing whether it lands.
class DesignSystemModalsTurboRegistrationTest < ActiveSupport::TestCase
  MODAL_HOST = File.expand_path("../../app/javascript/studio/modal_host.js", __dir__)

  # A missing node runtime FAILS here; it must never `skip`. This is the only
  # coverage that observes the guide's store registering from its rendered
  # declaration, so a skip would read as a pass on the mechanism it protects.
  def test_node_runtime_is_available
    refute_empty node_path,
                 "node runtime NOT FOUND on PATH. The dsModals Turbo-registration suite " \
                 "executes the store registration for real; skipping it would report green " \
                 "with zero coverage. Install node (mise install node@20) and re-run."
  end

  def test_the_overlay_declares_the_full_stack_under_the_guides_name
    host = ds_modals_host
    assert_equal "modal-host", host["data-studio-controller"]
    assert_equal "dsModals", host["data-modal-host-store-value"]
    assert_nil host["data-modal-host-scoped-value"],
               "the guide's store is the full stack (advance, the animation registry), not the scoped one"
  end

  def test_dsmodals_registers_on_turbo_visit_and_on_first_load
    out = nil
    Tempfile.create(["ds_modals_turbo_harness", ".mjs"]) do |f|
      f.write("import { installModalHost, HOST_SELECTOR } from #{"file://#{MODAL_HOST}".to_json};\n",
              "const HOST_ATTRIBUTES = #{ds_modals_host.to_json};\n",
              HARNESS)
      f.flush
      out = `#{node_path} #{f.path} 2>&1`
    end

    assert $?.success?, "node harness failed:\n#{out}"
    assert_includes out, "ALL-DSMODALS-TURBO-SCENARIOS-PASS", out
  end

  private

  def node_path
    @node_path ||= `which node 2>/dev/null`.strip
  end

  # The attributes of the overlay's outer <template>, out of the real
  # /admin/style page (the path style_page_test.rb renders).
  def ds_modals_host
    @ds_modals_host ||= begin
      # A host renders these views through ApplicationController, which has EVERY
      # engine helper mixed in (no isolate_namespace). A bare test view has none,
      # so give it the whole set.
      view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
      view.extend(Studio::Engine.helpers)
      html = view.render(template: "style/index")
      template = Nokogiri::HTML5.fragment(html).css("template").find { |t| t["x-if"] == "$store.dsModals.current()" }
      refute_nil template, "expected /admin/style to render the dsModals overlay template"
      template.attributes.transform_values(&:value)
    end
  end

  # A document that finds the rendered host by studio/modal_host's own selector,
  # and an Alpine whose store registry both a started and a late Alpine share.
  HARNESS = <<~'JS'
    function assert(cond, msg) {
      if (!cond) { console.error('FAIL: ' + msg); process.exit(1); }
    }
    const hostNode = () => ({ getAttribute: (name) => (name in HOST_ATTRIBUTES ? HOST_ATTRIBUTES[name] : null) });
    function makeRoot(hosts) {
      return { querySelectorAll: (selector) => (selector === HOST_SELECTOR ? hosts : []) };
    }
    function makeDocument(hosts) {
      const listeners = {};
      return Object.assign(makeRoot(hosts), {
        listeners,
        addEventListener(name, fn) { (listeners[name] = listeners[name] || []).push(fn); },
        fire(name, event) { (listeners[name] || []).slice().forEach((fn) => fn(event || {})); },
        body: { classList: { add() {}, remove() {} } },
        contains: () => false,
        activeElement: null
      });
    }
    function makeAlpine(stores, started) {
      const alpine = {
        store(name, def) {
          if (def === undefined) return stores[name];
          stores[name] = def;
        }
      };
      if (started) alpine.version = '3.16.1';
      return alpine;
    }

    // Scenario A — first full-document load. The module runs before Alpine, so
    // nothing registers until alpine:init, and then the store is there.
    {
      const stores = {};
      const doc = makeDocument([hostNode()]);
      const win = { setTimeout };
      installModalHost(doc, win);
      assert(!stores.dsModals, 'FIRST-LOAD: dsModals must not exist before Alpine boots');
      win.Alpine = makeAlpine(stores, false);
      doc.fire('alpine:init');
      assert(stores.dsModals, 'FIRST-LOAD: dsModals registers when alpine:init fires');
      assert(typeof stores.dsModals.advance === 'function', 'FIRST-LOAD: the guide gets the full stack, with advance()');
      assert(typeof stores.dsModals.cardClasses === 'function' && typeof stores.dsModals.swap === 'function',
        'FIRST-LOAD: the store carries the API the specimens call');
    }

    // Scenario B — Turbo Drive advance visit. Alpine started on a page with no
    // guide on it; alpine:init never fires again. The store MUST register from
    // the incoming body, before Alpine sees it. This is the property the
    // failure violates.
    {
      const stores = {};
      const doc = makeDocument([]);
      const win = { setTimeout, Alpine: makeAlpine(stores, true) };
      installModalHost(doc, win);
      doc.fire('alpine:init');
      assert(!stores.dsModals, 'TURBO: a page with no guide registers no dsModals');
      doc.fire('turbo:before-render', { detail: { newBody: makeRoot([hostNode()]) } });
      assert(stores.dsModals,
        'TURBO: dsModals must register from the incoming body, with no alpine:init');

      // Scenario C — idempotent. Another visit to the guide keeps the ORIGINAL
      // store, so live modal state is never clobbered.
      const first = stores.dsModals;
      doc.fire('turbo:before-render', { detail: { newBody: makeRoot([hostNode()]) } });
      doc.fire('alpine:init');
      assert(stores.dsModals === first, 'IDEMPOTENT: re-registration keeps the original store');
    }

    // Scenario D — Alpine already running when the module arrives (a host that
    // loads it ahead of the module tags): the store registers at once.
    {
      const stores = {};
      const doc = makeDocument([hostNode()]);
      installModalHost(doc, { setTimeout, Alpine: makeAlpine(stores, true) });
      assert(stores.dsModals, 'LATE-MODULE: dsModals registers at once when Alpine is already up');
    }

    console.log('ALL-DSMODALS-TURBO-SCENARIOS-PASS');
  JS
end
