# frozen_string_literal: true

module Studio
  module Board
    # Shared 100-gap rank read-model for board-orderable records — the kanban
    # columns (McRitchie Studio tasks / news / content) and the depth-chart lanes.
    # A record carries an integer `position`; the board renders by `board_ordered`
    # (highest position on top), and a drag-reorder restamps the whole column with
    # 100-gaps via `reposition!`. Ranking is ZONE-SCOPED: a fresh rank is computed
    # within the record's zone (a kanban `stage`, a depth-chart position group), so
    # every column ranks independently and 100-spacing leaves room for the next
    # drag insert without a full re-stamp.
    #
    # This is the read/rank half of the board primitive; the write half is
    # Studio::Board::Reorderable (the controller action that calls reposition!).
    #
    #   class Task < ApplicationRecord
    #     include Studio::Board::Rankable
    #     before_create :set_initial_position   # seeds the genesis rank
    #   end
    #
    #   class DepthChartEntry < ApplicationRecord
    #     include Studio::Board::Rankable
    #     self.board_zone_attr = :position     # a lane (QB/RB/…), not a kanban stage
    #     self.board_rank_attr = :depth        # rank by depth; `position` is a string
    #     self.board_rank_order = :asc         # depth 1 (the starter) sits on top
    #   end
    module Rankable
      extend ActiveSupport::Concern

      included do
        # The column the record ranks WITHIN. Default matches the three MS kanban
        # boards (stage); a within-lane board overrides it, and `nil` ranks globally.
        class_attribute :board_zone_attr, instance_accessor: false, default: :stage

        # The column the board RANKS BY. Default :position — the three MS kanban
        # boards and the 100-gap read-model. A board whose rank lives in another
        # column overrides it: the depth chart ranks by `depth` while its `position`
        # column holds a lane-code STRING, so every ranking read/write below follows
        # `board_rank_attr` rather than a hardcoded `position`.
        class_attribute :board_rank_attr, instance_accessor: false, default: :position

        # The board_ordered sort direction for the rank column. :desc (default) puts
        # the HIGHEST rank on top — the kanban freshest-first shape; :asc puts the
        # LOWEST on top so depth 1 (the starter) sits at the top of its lane.
        class_attribute :board_rank_order, instance_accessor: false, default: :desc

        # Board order: the rank column first (direction per board_rank_order), NULLS
        # last, then newest by created_at as a stable tiebreak. The column name is a
        # quoted identifier and the direction a whitelisted ASC/DESC literal — never
        # user input — so the Arel.sql fragment is injection-safe.
        scope :board_ordered, lambda {
          dir = board_rank_order.to_s.casecmp("asc").zero? ? "ASC" : "DESC"
          col = connection.quote_column_name(board_rank_attr)
          order(Arel.sql("#{col} #{dir} NULLS LAST, created_at DESC"))
        }
      end

      # Seed the genesis rank on create: max(rank column) within this record's zone
      # plus a 100 gap. A no-op when the rank is already set, so an explicit rank is
      # never clobbered. Wire from the host via `before_create :set_initial_position`.
      def set_initial_position
        rank_attr = self.class.board_rank_attr
        return if public_send(rank_attr).present?

        public_send("#{rank_attr}=", self.class.board_next_position(zone_value_for_rank))
      end

      # This record's zone value (nil when the model ranks globally).
      def zone_value_for_rank
        attr = self.class.board_zone_attr
        attr && respond_to?(attr) ? public_send(attr) : nil
      end

      class_methods do
        # max(position) + gap within a zone (or globally when the zone value / attr
        # is blank). The genesis seed and the "bump to top on a stage move" both read
        # from here, so the 100-gap rule lives in one place.
        def board_next_position(zone_value = nil, gap: 100)
          scope = board_zone_attr && zone_value ? where(board_zone_attr => zone_value) : all
          (scope.maximum(board_rank_attr) || 0) + gap
        end

        # Restamp a column top-to-bottom in ONE pass. `ids` arrive in DOM order (top
        # first). Under the `position DESC` board sort the TOP card must hold the
        # HIGHEST rank, so with `direction: :desc` (the board default) the first id
        # gets the largest value and each next one drops by `gap` — 100-spacing that
        # leaves gaps for the next drag insert. `direction: :asc` ranks the other way
        # (first id smallest) for an ascending board. This is exactly the per-id
        # `update_all(position: ...)` loop the MS tasks/news/content reorder actions
        # each ran by hand, lifted into the model. Returns the ids it stamped.
        #
        # DG2 — SEQUENTIAL 1..N RANKS: `gap: 1, direction: :asc` stamps 1, 2, 3, … N
        # (the depth chart's depth numbers, 1 = starter), not the 100-gapped default.
        # DG1 — a board that ranks by another column passes `rank_attr:` (defaults to
        # the model's `board_rank_attr`, so a configured model needs nothing here).
        # DG4 — `skip_locked: true` leaves a PINNED entry untouched: its rank column is
        # not written, so a locked starter keeps its depth while the others reflow
        # around it. The lock flag column is `lock_attr` (default :locked).
        def reposition!(ids, gap: 100, direction: :desc, id_attr: primary_key,
                        rank_attr: board_rank_attr, skip_locked: false, lock_attr: :locked)
          ids = Array(ids)
          length = ids.length
          ids.each_with_index do |id, index|
            rank = direction.to_sym == :asc ? (index + 1) * gap : (length - index) * gap
            rel  = where(id_attr => id)
            rel  = rel.where.not(lock_attr => true) if skip_locked
            rel.update_all(rank_attr => rank)
          end
          ids
        end
      end
    end
  end
end
