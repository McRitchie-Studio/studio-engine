# frozen_string_literal: true

require "test_helper"
require "action_view"
require "open3"

# [component] The browser session store (app/assets/javascripts/studio/session.js),
# EXECUTED under node, plus the wiring that delivers it to every page.
#
# WHY NODE AND NOT STRING ASSERTIONS. The store's value is its transitions: which
# state a page lands in when another tab signs out, whether a declared switch stays
# silent, whether two tabs stop talking. A grep of the source is structurally blind
# to all of it. test/support/session_store_harness.js loads the REAL file into
# isolated vm contexts, one per tab, sharing a fake BroadcastChannel bus and a fake
# server, and drives each scenario by calling the store.
#
# Every scenario is asserted BY NAME below. A scenario deleted or renamed in the
# harness therefore fails here instead of quietly shrinking the coverage, and a
# scenario added there without a line here fails the count check.
#
# A missing node runtime FAILS; it never skips (see ModalHostStoreBehaviorTest for
# the same rule and why). CI installs node in the engine-suite lane.
class StudioSessionStoreTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  STORE = File.join(ROOT, "app/assets/javascripts/studio/session.js")
  HARNESS = File.join(ROOT, "test/support/session_store_harness.js")

  SCENARIOS = %w[
    seats_an_anonymous_page
    seats_an_authenticated_page
    stays_dormant_without_a_stamp
    treats_an_unreadable_stamp_as_dormant
    peer_sign_out_rehydrates_to_signed_out
    peer_sign_in_rehydrates_an_anonymous_page
    peer_drift_without_a_rehydrate_url_stays_stale_and_warns
    an_older_peer_never_moves_a_newer_tab
    answers_an_older_announce_with_its_own
    same_millisecond_disagreement_does_not_ping_pong
    server_401_on_return_reads_as_revoked
    server_probe_of_an_unchanged_session_is_silent
    a_short_absence_does_not_probe
    bfcache_restore_probes_the_server
    expiry_marks_stale_then_rehydrates
    plugin_source_mismatch_then_resolve
    an_unbound_source_never_mismatches
    a_source_can_supply_its_own_bound_and_equality
    expect_change_suppresses_the_mismatch_warning
    holds_expire_and_match_only_their_scope
    session_scope_hold_covers_web2_drift
    manual_refresh_waits_for_a_probe_already_in_flight
    navigation_adopts_a_new_session_without_a_warning
    a_restored_older_snapshot_goes_stale_and_rechecks
    a_failed_rehydrate_on_a_stale_page_is_drift
    register_refuses_bad_reserved_and_duplicate_names
    subscribers_receive_transitions_and_can_leave
    mirrors_into_an_alpine_store_without_touching_host_stores
    works_without_broadcast_channel
  ].freeze

  def self.node_path
    @node_path ||= `which node 2>/dev/null`.strip
  end

  # One node run for the whole class: the scenarios are independent inside it.
  def self.harness_output
    @harness_output ||= begin
      raise "node runtime NOT FOUND on PATH" if node_path.empty?

      out, status = Open3.capture2e(node_path, HARNESS, STORE)
      [out, status]
    end
  end

  def output
    self.class.harness_output.first
  end

  def test_node_runtime_is_available
    refute_empty self.class.node_path,
                 "node runtime NOT FOUND on PATH. The session store suite executes the store for " \
                 "real; skipping it would report green with zero coverage. Install node " \
                 "(mise install node@20) and re-run."
  end

  def test_the_harness_passes_every_scenario_it_runs
    out, status = self.class.harness_output
    assert status.success?, "node harness failed:\n#{out}"
    assert_includes out, "SESSION-STORE-SCENARIOS #{SCENARIOS.size}/#{SCENARIOS.size}", out
  end

  def test_the_harness_runs_exactly_the_scenarios_named_here
    ran = output.lines.filter_map { |line| line[/\A(?:PASS|FAIL) ([a-z0-9_]+)/, 1] }
    assert_equal SCENARIOS.sort, ran.sort, "the Ruby list and the harness disagree"
  end

  SCENARIOS.each do |name|
    define_method("test_scenario_#{name}") do
      assert_includes output.lines.map(&:strip), "PASS #{name}", output
    end
  end

  # ---- delivery -------------------------------------------------------------

  def test_the_stamp_partial_loads_the_store_from_the_asset_pipeline
    partial = File.read(File.join(ROOT, "app/views/studio/_session_stamp.html.erb"))
    assert_includes partial, %(javascript_include_tag "studio/session")
    refute_match(/javascript_include_tag "studio\/session"[^%]*defer/, partial,
                 "the store must run before deferred Alpine so it hears alpine:init")
  end

  def test_the_head_renders_the_stamp_partial
    head = File.read(File.join(ROOT, "app/views/layouts/studio/_head.html.erb"))
    assert_includes head, %(render "studio/session_stamp")
    assert_operator head.index(%(render "studio/session_stamp")), :<, head.index(%(javascript_include_tag "studio/alpine")),
                    "the store loads before Alpine"
  end

  def test_the_asset_is_precompiled_and_packaged
    engine_rb = File.read(File.join(ROOT, "lib/studio/engine.rb"))
    assert_includes engine_rb, "studio/session.js", "sprockets hosts need the precompile entry"

    spec = Gem::Specification.load(File.join(ROOT, "studio-engine.gemspec"))
    %w[
      app/assets/javascripts/studio/session.js
      app/views/studio/_session_stamp.html.erb
      app/controllers/studio/session_states_controller.rb
      app/controllers/concerns/studio/session_drift.rb
      lib/studio/session_fingerprint.rb
    ].each do |path|
      assert_includes spec.files, path, "the gem must package #{path}"
    end
  end

  # ---- the head, rendered -----------------------------------------------------

  def test_a_head_rendered_without_the_concern_is_unchanged
    html = render_head
    refute_includes html, "studio-session", "no stamp outside a Studio::ErrorHandling controller"
    refute_includes html, "studio/session", "and no store either"
  end

  def test_a_head_rendered_with_the_concern_carries_one_stamp_and_the_store
    stamp = { v: 1, state: "anonymous", fingerprint: "anonymous", issuedAt: 1, expiresAt: nil,
              rehydrateUrl: nil, identities: {} }
    html = render_head { |view| view.define_singleton_method(:studio_session_page_stamp) { stamp } }

    assert_equal 1, html.scan('name="studio-session"').size
    assert_includes html, "studio/session"
    content = html[/<meta name="studio-session" content="([^"]*)"/, 1]
    refute_nil content
    assert_equal JSON.parse(stamp.to_json), JSON.parse(CGI.unescapeHTML(content))
  end

  def test_a_nil_stamp_renders_nothing
    html = render_head { |view| view.define_singleton_method(:studio_session_page_stamp) { nil } }
    refute_includes html, "studio-session"
    refute_includes html, "studio/session"
  end

  private

  def render_head
    view = ActionView::Base.with_empty_template_cache.with_view_paths([File.join(ROOT, "app/views")])
    def view.csrf_meta_tags = ""
    def view.csp_meta_tag = ""
    def view.studio_theme_css_tag = ""
    def view.javascript_importmap_tags = "<script></script>"
    yield view if block_given?

    view.render(partial: "layouts/studio/head")
  end
end
