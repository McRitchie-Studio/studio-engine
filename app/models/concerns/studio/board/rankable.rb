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
    #     self.board_zone_attr = :position_group   # a lane, not a kanban stage
    #   end
    module Rankable
      extend ActiveSupport::Concern

      included do
        # The column the record ranks WITHIN. Default matches the three MS kanban
        # boards (stage); a within-lane board overrides it, and `nil` ranks globally.
        class_attribute :board_zone_attr, instance_accessor: false, default: :stage

        # Board order: highest `position` first (freshest/top card wins), NULLS last,
        # then newest by created_at as a stable tiebreak. Arel.sql: the fragment is a
        # fixed literal, not user input.
        scope :board_ordered, -> { order(Arel.sql("position DESC NULLS LAST, created_at DESC")) }
      end

      # Seed the genesis rank on create: max(position) within this record's zone plus
      # a 100 gap. A no-op when `position` is already set, so an explicit rank is
      # never clobbered. Wire from the host via `before_create :set_initial_position`.
      def set_initial_position
        return if position.present?

        self.position = self.class.board_next_position(zone_value_for_rank)
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
          (scope.maximum(:position) || 0) + gap
        end

        # Restamp a column top-to-bottom in ONE pass. `ids` arrive in DOM order (top
        # first). Under the `position DESC` board sort the TOP card must hold the
        # HIGHEST rank, so with `direction: :desc` (the board default) the first id
        # gets the largest value and each next one drops by `gap` — 100-spacing that
        # leaves gaps for the next drag insert. `direction: :asc` ranks the other way
        # (first id smallest) for an ascending board. This is exactly the per-id
        # `update_all(position: ...)` loop the MS tasks/news/content reorder actions
        # each ran by hand, lifted into the model. Returns the ids it stamped.
        def reposition!(ids, gap: 100, direction: :desc, id_attr: primary_key)
          ids = Array(ids)
          length = ids.length
          ids.each_with_index do |id, index|
            rank = direction.to_sym == :asc ? (index + 1) * gap : (length - index) * gap
            where(id_attr => id).update_all(position: rank)
          end
          ids
        end
      end
    end
  end
end
