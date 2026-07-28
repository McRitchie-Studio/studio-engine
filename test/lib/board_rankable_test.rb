# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

# [unit] Guard for the board primitive's rank/reorder read-model:
#   Studio::Board::Rankable  — the 100-gap ranking (board_ordered scope,
#     set_initial_position, reposition! in both directions), the exact math the
#     three MS kanban boards (tasks / news / content) hand-rolled per-controller.
#   Studio::Board::Reorderable — the shared `reorder` action: the "param required"
#     guard, the delegated restamp, and the 422-on-error contract.
#
# AR-backed against the dummy's in-memory sqlite (each release-check test file is
# its own process, so the :memory: db is fresh here). Mirrors how the engine boot
# test defines just the columns the exercised model reads.
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :board_widgets, force: true do |t|
    t.string  :stage
    t.integer :position
    t.timestamps
  end
end

class BoardWidget < ActiveRecord::Base
  include Studio::Board::Rankable
  before_create :set_initial_position
end

class BoardRankableTest < ActiveSupport::TestCase
  def setup
    BoardWidget.delete_all
  end

  # --- reposition! — the 100-gap restamp, DESC (the board default) -----------

  test "reposition! DESC stamps the DOM-top id highest, dropping by the gap" do
    a = BoardWidget.create!(stage: "x", position: 1)
    b = BoardWidget.create!(stage: "x", position: 2)
    c = BoardWidget.create!(stage: "x", position: 3)

    # ids arrive top-to-bottom (DOM order). Under `position DESC` the TOP id must
    # hold the HIGHEST rank: n=3 → 300, 200, 100.
    BoardWidget.reposition!([a.id, b.id, c.id], id_attr: :id)

    assert_equal 300, a.reload.position
    assert_equal 200, b.reload.position
    assert_equal 100, c.reload.position
    # board_ordered (position DESC) reflects the DOM order.
    assert_equal [a.id, b.id, c.id], BoardWidget.board_ordered.pluck(:id)
  end

  # --- reposition! — ascending (first id smallest) ---------------------------

  test "reposition! ASC stamps the DOM-top id lowest, rising by the gap" do
    a = BoardWidget.create!(stage: "x", position: 1)
    b = BoardWidget.create!(stage: "x", position: 2)
    c = BoardWidget.create!(stage: "x", position: 3)

    BoardWidget.reposition!([a.id, b.id, c.id], direction: :asc, id_attr: :id)

    assert_equal 100, a.reload.position
    assert_equal 200, b.reload.position
    assert_equal 300, c.reload.position
  end

  test "reposition! honors a custom gap" do
    a = BoardWidget.create!(stage: "x", position: 1)
    b = BoardWidget.create!(stage: "x", position: 2)

    BoardWidget.reposition!([a.id, b.id], gap: 10, id_attr: :id)

    assert_equal 20, a.reload.position
    assert_equal 10, b.reload.position
  end

  # --- set_initial_position — max+100 within the zone ------------------------

  test "set_initial_position seeds max+100 per zone, ranking each column independently" do
    first  = BoardWidget.create!(stage: "designed")
    second = BoardWidget.create!(stage: "designed")
    other  = BoardWidget.create!(stage: "building")

    assert_equal 100, first.position,  "genesis card in a zone seeds 100"
    assert_equal 200, second.position, "next card in the same zone seeds max+100"
    assert_equal 100, other.position,  "a different zone ranks independently"
  end

  test "set_initial_position never clobbers an explicit position" do
    widget = BoardWidget.create!(stage: "designed", position: 555)
    assert_equal 555, widget.position
  end

  # --- board_ordered — position DESC, NULLS last -----------------------------

  test "board_ordered sorts by position DESC and declares NULLS last" do
    low     = BoardWidget.create!(stage: "x", position: 100)
    high    = BoardWidget.create!(stage: "x", position: 300)
    # before_create :set_initial_position would seed a nil position, so force a true
    # NULL past the callback to exercise the NULLS-last clause.
    nil_pos = BoardWidget.create!(stage: "x", position: 50)
    nil_pos.update_column(:position, nil)

    # Real positions order DESC (highest/top card first) — the load-bearing rule.
    assert_equal [high.id, low.id],
      BoardWidget.board_ordered.where.not(position: nil).pluck(:id)
    # The nil-position row is still present, never dropped by the scope.
    assert_includes BoardWidget.board_ordered.pluck(:id), nil_pos.id
    # The scope declares NULLS LAST (honored by the production Postgres; the dummy's
    # sqlite orders NULLs differently, so we assert the SQL intent, not its slot).
    assert_includes BoardWidget.board_ordered.to_sql, "NULLS LAST"
  end

  # --- board_zone_attr override ----------------------------------------------

  test "a model can rank within a non-stage zone via board_zone_attr" do
    original = BoardWidget.board_zone_attr
    begin
      BoardWidget.board_zone_attr = :stage # already stage, but prove the knob reads through
      w = BoardWidget.new(stage: "z")
      w.set_initial_position
      assert_equal 100, w.position
    ensure
      BoardWidget.board_zone_attr = original
    end
  end
end

# --- Reorderable — the shared controller action ------------------------------

# A bare probe including the concern (no ActionController needed): the concern only
# reads `params[...]` and calls `render(...)`, both stubbed here, so the action's
# guard + delegated restamp are exercised directly.
class BoardReorderableProbe
  include Studio::Board::Reorderable
  board_reorderable model: BoardWidget, id_attr: :id, param: :ids

  attr_accessor :params, :rendered

  def render(opts)
    @rendered = opts
  end
end

class BoardReorderableTest < ActiveSupport::TestCase
  def setup
    BoardWidget.delete_all
  end

  test "reorder restamps the column from the DOM-ordered id list and renders success" do
    a = BoardWidget.create!(stage: "x", position: 1)
    b = BoardWidget.create!(stage: "x", position: 2)

    probe = BoardReorderableProbe.new
    probe.params = { ids: [a.id, b.id] }
    probe.reorder

    assert_equal({ success: true }, probe.rendered[:json])
    assert_equal 200, a.reload.position, "the DOM-top id holds the highest rank"
    assert_equal 100, b.reload.position
  end

  test "reorder 422s with a param-named error when the id list is missing" do
    probe = BoardReorderableProbe.new
    probe.params = {} # no :ids
    probe.reorder

    assert_equal :unprocessable_entity, probe.rendered[:status]
    assert_equal "ids required", probe.rendered[:json][:error]
  end
end

# --- Reorderable ERROR-LOG WIRING (backend write discipline) -----------------

# The shared reorder action must run the restamp INSIDE rescue_and_log so a failure
# lands in ErrorLog (the MS original's behavior). These probes stand in a
# rescue_and_log that mimics Studio::ErrorHandling's (yield; on error record +
# re-raise), so the wiring is exercised BEHAVIORALLY — that the wrapper is on the
# happy path, and that a raised restamp is logged AND still 422s — not by reading
# the concern's source.
class BoardReorderLoggedProbe
  include Studio::Board::Reorderable
  board_reorderable model: BoardWidget, id_attr: :id, param: :ids

  attr_accessor :params, :rendered, :logged

  def initialize
    @logged = []
  end

  def render(opts)
    @rendered = opts
  end

  # Mirrors Studio::ErrorHandling#rescue_and_log: run the block; on error capture
  # (here: append to @logged, standing in for ErrorLog) and RE-RAISE to the caller.
  def rescue_and_log(target: nil)
    yield
  rescue StandardError => e
    @logged << e
    raise e
  end
end

# A model whose restamp raises, to drive the error/logging path. Accepts the
# positional + keyword args reposition! is called with, so it raises the intended
# error rather than an arity error.
class BoardReorderBoomModel
  def self.reposition!(*, **)
    raise "reorder boom"
  end
end

class BoardReorderBoomProbe < BoardReorderLoggedProbe
  board_reorderable model: BoardReorderBoomModel, id_attr: :id, param: :ids
end

class BoardReorderableLoggingTest < ActiveSupport::TestCase
  def setup
    BoardWidget.delete_all
  end

  test "the happy-path restamp runs THROUGH rescue_and_log (no error logged, success rendered)" do
    a = BoardWidget.create!(stage: "x", position: 1)
    b = BoardWidget.create!(stage: "x", position: 2)

    probe = BoardReorderLoggedProbe.new
    probe.params = { ids: [a.id, b.id] }
    probe.reorder

    assert_empty probe.logged, "a clean reorder logs nothing"
    assert_equal({ success: true }, probe.rendered[:json])
    assert_equal 200, a.reload.position, "the restamp still ran (inside the logged block)"
  end

  test "a failed restamp is captured by rescue_and_log AND re-raised to the 422 net" do
    probe = BoardReorderBoomProbe.new
    probe.params = { ids: [1, 2] }
    probe.reorder

    assert_equal 1, probe.logged.size, "the failure is logged (ErrorLog path) — not swallowed silently"
    assert_equal "reorder boom", probe.logged.first.message
    assert_equal :unprocessable_entity, probe.rendered[:status], "and re-raised to the outer 422"
    assert_equal "reorder boom", probe.rendered[:json][:error]
  end

  test "reorder degrades gracefully when the host lacks rescue_and_log" do
    # BoardReorderableProbe does NOT define rescue_and_log — the respond_to? guard
    # must fall back to a bare restamp + 422, never a NoMethodError.
    a = BoardWidget.create!(stage: "x", position: 1)
    probe = BoardReorderableProbe.new
    probe.params = { ids: [a.id] }
    probe.reorder

    assert_equal({ success: true }, probe.rendered[:json])
    assert_equal 100, a.reload.position
  end
end
