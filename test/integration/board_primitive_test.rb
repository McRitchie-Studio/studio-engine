# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "cgi"
require "json"

# [integration] Guard for the board primitive's MARKUP contract — the data-* identity
# every board card + zone must emit so window.studioBoard can move/reorder it, and
# the /admin/style demo specimen that renders the real primitive. Renders the
# partials through a bare ActionView (the dummy compiles no engine CSS, so this
# asserts the CONTRACT, not styling), mirroring style_page_test.
#
# The contract (extracted from the MS tasks board it converges):
#   card:  id="card-<id>", class .kanban-card, data-<id_attr>, data-<zone_attr>
#   zone:  id="dropzone-<key>", class .kanban-dropzone, data-<zone_attr>, .kanban-empty
class BoardPrimitiveTest < ActiveSupport::TestCase
  def view
    # A host renders these views through ApplicationController, which has EVERY
    # engine helper mixed in (no isolate_namespace). A bare test view has none, so
    # give it the whole set rather than the one module today's specimens happen to
    # call — otherwise the next helper-backed specimen breaks all five harnesses.
    ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
                    .tap { |v| v.extend(Studio::Engine.helpers) }
  end

  def render_board(locals)
    view.render(partial: "studio/board/board", locals: locals)
  end

  # Extract the studioBoard(...) opts the board serialized into its x-data and parse
  # them back to a Hash — an EFFECT assertion on the real serialization (HTML-escaped
  # JSON), not a substring proxy. The inner quotes render as &quot;, so unescape first.
  def board_opts_hash(html)
    raw = html[/x-data="studioBoard\((.+?)\)"/m, 1]
    refute_nil raw, "the board must serialize studioBoard opts into x-data"
    JSON.parse(CGI.unescapeHTML(raw))
  end

  DEFAULT_LOCALS = {
    card_partial: "style/board/demo_card",
    card_as: :card,
    reorder_url: "#",
    demo: true
  }.freeze

  def columns_fixture
    [
      { key: "designed", label: "Designed", badge_class: "stage-fresh",
        cards: [{ id: "alpha", zone: "designed", title: "Alpha", repo: "studio-engine", who: "SH" }] },
      { key: "shipped", label: "Shipped", badge_class: "stage-shipped",
        cards: [{ id: "omega", zone: "shipped", title: "Omega", repo: "mcritchie", who: "ST" }] }
    ]
  end

  # --- the CARD half of the identity contract --------------------------------

  test "each card emits id=card-<id>, .kanban-card and the default data-slug/stage" do
    html = render_board(DEFAULT_LOCALS.merge(columns: columns_fixture))

    assert_includes html, 'id="card-alpha"', "the card carries the dom id card-<id>"
    assert_includes html, "kanban-card", "the card carries the .kanban-card draggable class"
    assert_includes html, 'data-slug="alpha"', "the card carries data-<id_attr> (default slug)"
    assert_includes html, 'data-stage="designed"', "the card carries its current zone (default stage)"
    assert_includes html, 'id="card-omega"'
    assert_includes html, 'data-stage="shipped"'
  end

  # --- the ZONE half of the identity contract --------------------------------

  test "each column emits id=dropzone-<key>, .kanban-dropzone, data-<zone_attr> and an empty state" do
    html = render_board(DEFAULT_LOCALS.merge(columns: columns_fixture))

    assert_includes html, 'id="dropzone-designed"', "the zone carries id dropzone-<key>"
    assert_includes html, 'id="dropzone-shipped"'
    assert_includes html, "kanban-dropzone", "the zone carries the .kanban-dropzone target class"
    assert_includes html, 'data-stage="designed"', "the zone carries data-<zone_attr>"
    assert_includes html, "kanban-empty", "the column renders the empty state element"
    assert_includes html, 'data-board-count="designed"', "the count badge is keyed for updateCounts"
    assert_includes html, 'data-test="studio-board"', "the board root is test-addressable"
  end

  # --- the contract is neutral: custom id_attr / zone_attr -------------------

  test "id_attr and zone_attr drive the data-* names, so ONE primitive fits any board" do
    html = render_board(DEFAULT_LOCALS.merge(
      columns: [{ key: "lane-1", label: "Lane 1",
                  cards: [{ id: "w1", zone: "lane-1", title: "W1", repo: "x", who: "SH" }] }],
      id_attr: "ref",
      zone_attr: "lane",
      card_locals: { id_attr: "ref", zone_attr: "lane" }
    ))

    assert_includes html, 'data-ref="w1"', "the card data-attr follows id_attr"
    assert_includes html, 'data-lane="lane-1"', "the zone data-attr follows zone_attr"
    assert_includes html, 'id="dropzone-lane-1"'
    assert_includes html, 'id="card-w1"'
    # The factory is configured with the same neutral names.
    assert_includes html, "studioBoard(", "the factory is wired via x-data"
    assert_match(/ref/, html)
  end

  # --- the factory carries its behavior config through opts ------------------

  test "the board serializes its move/reorder/demo config into the studioBoard opts" do
    html = render_board(DEFAULT_LOCALS.merge(
      columns: columns_fixture,
      move_url: "/tasks/:id.json",
      move_param: { resource: "task", attr: "stage" },
      reorder_payload: :slugs,
      group: "studio-board-demo"
    ))

    # The x-data attribute HTML-escapes the JSON quotes; assert on the escaped form.
    assert_includes html, "studioBoard("
    assert_includes html, "studio-board-demo", "the group flows into the factory opts"
    assert_includes html, "demo", "demo mode flows into the factory opts"
    assert_includes html, "/tasks/:id.json", "the move template flows into the factory opts"
  end

  # --- factory source-presence checks (NOT behavioral) -----------------------
  # HONEST SCOPE: these are SOURCE-SUBSTRING assertions on the factory JS, not
  # behavioral ones — the engine has no JS/system harness, so the factory is never
  # executed here. They guard that the load-bearing lines stay present (the
  # same-zone-never-PATCH guard, the flake-fix init ordering, the event seam); they
  # do NOT prove runtime behavior. The genuine effect-assertions in this suite are
  # the Ruby rank math (board_rankable_test) and the rendered-markup contract above.
  # Promote these to real behavioral coverage when a JS/system-test harness lands.
  test "the factory keeps the load-bearing guard lines present in source" do
    factory = File.read("app/views/studio/_board_assets.html.erb")
    assert_includes factory, "var moved = fromZone !== toZone",
      "a move is decided by the DROPZONES, not the card"
    assert_includes factory, "if (moved)",
      "the zone PATCH runs only on a real cross-column move"
    assert_includes factory, "data-alpine-ready",
      "the $nextTick → data-alpine-ready init ordering (flake fix) is preserved"
    assert_includes factory, 'window.dispatchEvent(new CustomEvent("studio:"',
      "the primary extension seam is dispatched window events"
  end

  # --- the /admin/style Board specimen renders the REAL primitive (demo) -----

  test "the /admin/style Tasks section renders the live board primitive in demo mode" do
    html = view.render(template: "style/index")

    assert_includes html, 'data-test="studio-board"',
      "the Tasks section mounts the real studio/board primitive"
    assert_includes html, 'id="card-engine-board-primitive"',
      "the specimen renders real demo cards through the card-shell contract"
    assert_includes html, 'id="dropzone-designed"'
    assert_includes html, "studio-board-demo",
      "the specimen runs in demo mode (its own group, no real board on the page)"
    # The static stage-palette reference is kept beneath the live primitive.
    assert_includes html, "What every board inherits",
      "the standard-vs-custom reference stays under the live specimen"
  end

  # --- the vendored SortableJS ships and is wired ----------------------------

  test "SortableJS is vendored and registered for precompile + loaded in the head" do
    vendored = File.read("app/assets/javascripts/studio/sortable.js")
    assert_includes vendored, "Sortable 1.15.6", "the pinned SortableJS version ships"
    assert_includes vendored, "VENDORED into studio-engine", "the house vendoring header is kept"

    engine = File.read("lib/studio/engine.rb")
    assert_includes engine, "studio/sortable.js", "sortable is added to config.assets.precompile"

    head = File.read("app/views/layouts/studio/_head.html.erb")
    assert_includes head, 'javascript_include_tag "studio/sortable"',
      "the head loads the vendored sortable (no CDN)"
  end

  # ==========================================================================
  # 0.28.0 — the five additive board-chrome hooks the /tasks pilot surfaced.
  # Every test asserts the RENDERED EFFECT, and each closes with the mirror
  # assertion that the 0.27.0 default rendering is unchanged (additive + opt-in).
  # ==========================================================================

  NEUTRAL_COUNT_CLASSES = "bg-surface-alt text-secondary border border-subtle"

  # --- gap 2: a per-column count_class colours the neutral count chip --------

  test "gap 2 — count_class emits a raw colour class on the count chip" do
    html = render_board(DEFAULT_LOCALS.merge(
      columns: [{ key: "designed", label: "Designed",
                  count_class: "bg-blue-500/10 text-blue-500 border border-blue-500/30",
                  cards: [{ id: "a", zone: "designed", title: "A", repo: "x", who: "SH" }] }]
    ))

    # The colour lands ON the count chip (the stage-count span, keyed for updateCounts).
    assert_match(/stage-count[^"]*text-blue-500[^"]*"\s+data-board-count="designed"/, html,
      "the count chip carries the raw count_class colour")
    refute_includes html, NEUTRAL_COUNT_CLASSES,
      "count_class REPLACES the neutral chip colours (no double-painting)"
  end

  test "gap 2 backward-compat — no count_class renders the exact 0.27.0 neutral chip" do
    html = render_board(DEFAULT_LOCALS.merge(
      columns: [{ key: "designed", label: "Designed",
                  cards: [{ id: "a", zone: "designed", title: "A", repo: "x", who: "SH" }] }]
    ))
    assert_includes html, NEUTRAL_COUNT_CLASSES,
      "with no count_class the chip keeps the 0.27.0 neutral colours"
  end

  # --- gap 5: bindable visibility, per-board min-width, a kickoff slot --------

  test "gap 5 — show_expr emits a bindable x-show (+ x-cloak) on the column" do
    html = render_board(DEFAULT_LOCALS.merge(
      columns: [{ key: "archived", label: "Archived", show_expr: "state.showArchived",
                  cards: [{ id: "a", zone: "archived", title: "A", repo: "x", who: "SH" }] }]
    ))
    assert_match(/data-board-column="archived"[^>]*x-show="state\.showArchived"/m, html,
      "the toggle-able column binds visibility to the board state")
    assert_match(/data-board-column="archived"[^>]*x-cloak/m, html,
      "x-cloak rides along so it can't flash before Alpine boots")
  end

  test "gap 5 — min_width overrides the column min-width, default stays sm:min-w-[190px]" do
    custom = render_board(DEFAULT_LOCALS.merge(
      columns: [{ key: "designed", label: "Designed", min_width: "sm:min-w-[22rem]",
                  cards: [{ id: "a", zone: "designed", title: "A", repo: "x", who: "SH" }] }]
    ))
    assert_includes custom, "sm:min-w-[22rem]", "min_width sets the column width"
    refute_includes custom, "sm:min-w-[190px]", "the custom width replaces the default"

    default = render_board(DEFAULT_LOCALS.merge(columns: columns_fixture))
    assert_includes default, "sm:min-w-[190px]", "with no min_width the 0.27.0 default holds"
  end

  test "gap 5 — kickoff renders a fixed-height slot under the header" do
    html = render_board(DEFAULT_LOCALS.merge(
      columns: [{ key: "designed", label: "Designed",
                  kickoff: "<span class='kick-chip'>go</span>".html_safe,
                  cards: [{ id: "a", zone: "designed", title: "A", repo: "x", who: "SH" }] }]
    ))
    assert_includes html, "studio-board-kickoff", "the kickoff slot wrapper renders"
    assert_includes html, "kick-chip", "the kickoff content renders inside the slot"

    plain = render_board(DEFAULT_LOCALS.merge(columns: columns_fixture))
    refute_includes plain, "studio-board-kickoff", "no kickoff ⇒ no slot (0.27.0)"
  end

  # --- gap 1: a board_state home + header slot for chrome --------------------

  test "gap 1 — board_state seeds the studioBoard state bag" do
    html = render_board(DEFAULT_LOCALS.merge(
      columns: columns_fixture,
      board_state: { showArchived: false, hiddenApps: [] }
    ))
    opts = board_opts_hash(html)
    assert_equal({ "showArchived" => false, "hiddenApps" => [] }, opts["state"],
      "the chrome state is serialized onto the studioBoard scope")
  end

  test "gap 1 — header_slot renders chrome above the columns" do
    html = render_board(DEFAULT_LOCALS.merge(
      columns: columns_fixture,
      header_slot: "<div class='my-chrome-toggle'>Toggle</div>".html_safe
    ))
    assert_includes html, "studio-board-header", "the header slot wrapper renders"
    assert_includes html, "my-chrome-toggle", "the chrome markup renders in the header"
    assert_operator html.index("my-chrome-toggle"), :<, html.index('id="dropzone-'),
      "the header sits ABOVE the columns"
  end

  test "gap 1 backward-compat — no board_state ⇒ state opt is absent (null)" do
    html = render_board(DEFAULT_LOCALS.merge(columns: columns_fixture))
    assert_nil board_opts_hash(html)["state"], "an unset board_state serializes as null"
  end

  # --- gap 3: archive_zone re-parents an exiting card instead of removing ----

  test "gap 3 — archive_zone is serialized so the exit path re-parents" do
    html = render_board(DEFAULT_LOCALS.merge(columns: columns_fixture, archive_zone: "archived"))
    assert_equal "archived", board_opts_hash(html)["archiveZone"],
      "the archive re-parent target rides the studioBoard opts"
  end

  test "gap 3 backward-compat — no archive_zone ⇒ archiveZone opt is null (remove)" do
    html = render_board(DEFAULT_LOCALS.merge(columns: columns_fixture))
    assert_nil board_opts_hash(html)["archiveZone"],
      "with no archive_zone the card is removed on exit (0.27.0)"
  end

  # --- gaps 3 + 4 + 1: the factory JS carries the load-bearing exit/state lines
  # SOURCE-substring scope (same honest limit as the guard-lines test above: the
  # engine runs no JS harness, so the factory is never executed here). These guard
  # that the re-parent branch, the exit marker, resetCardExit, and the state helpers
  # stay present; the EFFECT that they are WIRED is proven by the opts tests above.

  test "gap 4 — animateCardExit stamps the observable data-exit-action marker in source" do
    factory = File.read("app/views/studio/_board_assets.html.erb")
    assert_includes factory, "card.dataset.exitAction = kind",
      "the exit path marks WHICH exit is running (observable; e2e asserts it)"
  end

  test "gap 3 — the fallback re-parents to the archive dropzone in source" do
    factory = File.read("app/views/studio/_board_assets.html.erb")
    assert_includes factory, 'document.getElementById("dropzone-" + self.archiveZone)',
      "an archive exit resolves the archive column's dropzone"
    assert_includes factory, "zone.insertBefore(card, anchor)",
      "the card is re-parented into the archive column, not removed"
    assert_includes factory, "resetCardExit",
      "the re-parented card's exit animation is cleared so it is visible again"
  end

  test "gap 1 — the factory exposes the chrome-state helpers in source" do
    factory = File.read("app/views/studio/_board_assets.html.erb")
    assert_includes factory, "state: (opts.state", "the state bag is seeded from opts"
    assert_includes factory, "toggleState:", "a boolean-flag toggle helper is exposed"
    assert_includes factory, "toggleInState:", "a list-membership toggle helper is exposed"
    assert_includes factory, "listHas:", "a list-membership read helper is exposed"
  end

  # --- the /admin/style specimen demonstrates the enriched chrome LIVE --------

  test "the /admin/style Tasks section renders the enriched 0.28.0 chrome specimen" do
    html = view.render(template: "style/index")

    assert_includes html, "studio-board-chrome",
      "the enriched specimen mounts as its own demo board"
    assert_includes html, 'data-test="chrome-archived-toggle"',
      "the header_slot toggle (no outer wrapper) is present"
    assert_includes html, 'x-show="state.showArchived"',
      "the archived column binds visibility to the shared board state"
    assert_includes html, "studio-board-kickoff", "a column kickoff slot is demonstrated"
    assert_includes html, "text-blue-500", "a coloured count chip (count_class) is demonstrated"
    assert_includes html, 'id="dropzone-archived"',
      "the archive re-parent target column is on the board"

    # The original 0.27.0 demo specimen is untouched — both coexist.
    assert_includes html, 'id="card-engine-board-primitive"',
      "the first (0.27.0) demo specimen still renders"
    assert_includes html, "studio-board-demo", "the first specimen keeps its own demo group"
  end

  # ==========================================================================
  # 0.29.0 — DG: the four depth-chart gaps. Every test asserts the RENDERED
  # EFFECT and closes with the mirror that the 0.28.0 default is unchanged.
  # ==========================================================================

  def groups_fixture
    [
      { key: "offense", label: "Offense", cols_class: "grid-cols-2",
        columns: [
          { key: "QB", label: "QB", cards: [{ id: "qb1", zone: "QB", title: "QB1", repo: "d1", who: "1" }] },
          { key: "RB", label: "RB", cards: [{ id: "rb1", zone: "RB", title: "RB1", repo: "d1", who: "1" }] } ] },
      { key: "defense", label: "Defense",
        columns: [
          { key: "CB", label: "CB", cards: [{ id: "cb1", zone: "CB", title: "CB1", repo: "d1", who: "1" }] } ] }
    ]
  end

  # --- DG3: a two-level side→position grid via `groups:` ---------------------

  test "DG3 — groups render labelled sections, each a grid of its position lanes" do
    html = render_board(DEFAULT_LOCALS.merge(
      groups: groups_fixture, zone_attr: "position", card_locals: { zone_attr: "position" }
    ))

    assert_includes html, 'data-board-group="offense"', "each side is a labelled section"
    assert_includes html, 'data-board-group="defense"'
    assert_includes html, ">Offense<", "the group label renders"
    assert_includes html, "grid gap-4 grid-cols-2", "offense uses its cols_class grid"
    assert_includes html, "grid gap-4 grid-cols-2 sm:grid-cols-3 lg:grid-cols-4",
      "a group without cols_class falls back to the responsive default"
    # the identity contract still holds inside the grid
    assert_includes html, 'id="dropzone-QB"'
    assert_includes html, 'id="dropzone-CB"'
    assert_includes html, 'data-position="QB"'
    # the grid columns drop the flat-row width utilities
    refute_includes html, "sm:flex-1", "a grid lane is sized by the cell, not flex-1"
    # the factory's label map merges across EVERY group's columns
    opts = board_opts_hash(html)
    assert_equal "QB", opts["labels"]["QB"]
    assert_equal "CB", opts["labels"]["CB"], "labels reach into every group"
  end

  test "DG3 backward-compat — no groups renders the 0.28.0 flat row" do
    html = render_board(DEFAULT_LOCALS.merge(columns: columns_fixture))
    refute_includes html, "studio-board-group", "a flat board has no group sections"
    assert_includes html, "sm:flex-row", "it keeps the horizontal flex row"
    assert_includes html, "sm:flex-1", "and the flex-1 columns"
  end

  # --- DG4: per-card lock (contract + factory opt) ---------------------------

  test "DG4 — a locked card carries .kanban-locked + data-locked; lockedSelector rides the opts" do
    html = render_board(DEFAULT_LOCALS.merge(
      columns: [{ key: "QB", label: "QB", cards: [
        { id: "starter", zone: "QB", title: "Starter", repo: "d1", who: "1", locked: true },
        { id: "backup",  zone: "QB", title: "Backup",  repo: "d2", who: "2" } ] }],
      zone_attr: "position", card_locals: { zone_attr: "position" },
      locked_selector: ".kanban-locked"
    ))

    assert_match(/id="card-starter"[^>]*kanban-locked/m, html, "the pinned card carries .kanban-locked")
    assert_match(/id="card-starter"[^>]*data-locked="true"/m, html, "and the data-locked marker")
    refute_match(/id="card-backup"[^>]*kanban-locked/m, html, "an unlocked card does NOT")
    assert_equal ".kanban-locked", board_opts_hash(html)["lockedSelector"],
      "the factory is told which cards to pin"
  end

  test "DG4 backward-compat — no locked_selector ⇒ lockedSelector opt is null" do
    html = render_board(DEFAULT_LOCALS.merge(columns: columns_fixture))
    assert_nil board_opts_hash(html)["lockedSelector"], "every card stays draggable (0.28.0)"
  end

  test "DG4 — the factory keeps the lock filter + pin guard present in source" do
    factory = File.read("app/views/studio/_board_assets.html.erb")
    assert_includes factory, "self.lockedSelector ? (self.sortFilter",
      "locked cards join the undraggable filter"
    assert_includes factory, "cfg.onMove = function",
      "a drag can't cross a locked sibling (the pin guard)"
  end

  # --- the /admin/style specimen demonstrates the depth-chart shape LIVE ------

  test "the /admin/style Tasks section renders the depth-chart grid+lock specimen (0.29.0)" do
    html = view.render(template: "style/index")

    assert_includes html, 'data-board-group="offense"', "the specimen renders side sections"
    assert_includes html, 'data-board-group="defense"'
    assert_includes html, 'id="dropzone-QB"', "position lanes render as columns in the grid"
    assert_match(/id="card-dc-qb1"[^>]*kanban-locked/m, html, "the starter is pinned (locked)")
    assert_includes html, 'data-position="QB"', "the lane zone_attr is position"

    # All three board specimens coexist on the page.
    assert_includes html, 'id="card-engine-board-primitive"', "the 0.27.0 demo specimen stays"
    assert_includes html, "studio-board-chrome", "the 0.28.0 chrome specimen stays"
  end
end
