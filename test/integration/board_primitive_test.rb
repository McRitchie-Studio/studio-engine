# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"

# [component] Guard for the board primitive's MARKUP contract — the data-* identity
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
    ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
  end

  def render_board(locals)
    view.render(partial: "studio/board/board", locals: locals)
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

  # --- a same-zone reorder must never PATCH the zone (guard lives in the factory) --

  test "the factory sources from/to from the dropzones so an in-place reorder never mismoves" do
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
end
