# frozen_string_literal: true

module Studio
  module Board
    # Shared `reorder` action for board controllers. The three McRitchie Studio
    # kanban controllers (tasks / news / content) each carried a BYTE-IDENTICAL
    # `reorder` — guard the incoming id array, restamp the column with 100-gaps
    # INSIDE `rescue_and_log` (so a failure lands in ErrorLog — backend write
    # discipline), render `{ success: true }`, and rescue to a 422. This concern is
    # that action, neutral: the including controller declares its model, id column,
    # and the incoming param, and the ranking rule itself is delegated to the model's
    # Studio::Board::Rankable#reposition! (one place owns the 100-gap math). This is
    # THE designated shared write action, so it owns the ErrorLog logging here rather
    # than leaving each host to re-add it.
    #
    #   class TasksController < ApplicationController
    #     include Studio::Board::Reorderable
    #     board_reorderable model: Task, id_attr: :slug, param: :slugs
    #   end
    #
    #   # Route it however the app names the endpoint:
    #   post "tasks/reorder", to: "tasks#reorder"
    #
    # The POST body the studio/board factory sends is `{ <param>: [...ids],
    # zone: "<zone-key>" }`; this action reads only `<param>` (the ordered id list)
    # and ignores the advisory `zone`, so a kanban and a depth-chart board share it.
    module Reorderable
      extend ActiveSupport::Concern

      included do
        class_attribute :board_reorder_model,     instance_accessor: false
        class_attribute :board_reorder_id_attr,   instance_accessor: false, default: :slug
        class_attribute :board_reorder_param,     instance_accessor: false, default: :slugs
        class_attribute :board_reorder_gap,       instance_accessor: false, default: 100
        class_attribute :board_reorder_direction, instance_accessor: false, default: :desc
      end

      class_methods do
        # Configure the reorder action for this controller's board.
        def board_reorderable(model:, id_attr: :slug, param: :slugs, gap: 100, direction: :desc)
          self.board_reorder_model     = model
          self.board_reorder_id_attr   = id_attr
          self.board_reorder_param     = param
          self.board_reorder_gap       = gap
          self.board_reorder_direction = direction
        end
      end

      # POST — restamp a column from its DOM-ordered id list. Neutral param
      # (`slugs` or `ids`), 100-gap, DESC by default. Mirrors the MS hand-rolled
      # `reorder` exactly, INCLUDING its ErrorLog logging: the restamp runs inside
      # `rescue_and_log(target: nil)` (Studio::ErrorHandling), which captures a
      # failure to ErrorLog and RE-RAISES to the outer 422 net below — the "every
      # write path logs" discipline, owned here since this is the one shared write
      # action. `respond_to?` guards it so a host whose ApplicationController somehow
      # lacks the concern still degrades to a bare restamp + 422 (no NoMethodError).
      def reorder
        model = self.class.board_reorder_model
        raise "board_reorderable model not configured" unless model

        param = self.class.board_reorder_param
        ids = params[param]
        return render(json: { error: "#{param} required" }, status: :unprocessable_entity) unless ids.is_a?(Array)

        if respond_to?(:rescue_and_log)
          rescue_and_log(target: nil) { board_reorder_apply(model, ids) }
        else
          board_reorder_apply(model, ids)
        end
        render json: { success: true }
      rescue StandardError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      # Delegate to the model's Rankable#reposition! when available (the shared
      # 100-gap rule), else fall back to the same per-id update_all loop inline so
      # a model that only carries a `position` column still reorders.
      def board_reorder_apply(model, ids)
        id_attr   = self.class.board_reorder_id_attr
        gap       = self.class.board_reorder_gap
        direction = self.class.board_reorder_direction

        if model.respond_to?(:reposition!)
          model.reposition!(ids, gap: gap, direction: direction, id_attr: id_attr)
        else
          length = ids.length
          ids.each_with_index do |id, index|
            rank = direction.to_sym == :asc ? (index + 1) * gap : (length - index) * gap
            model.where(id_attr => id).update_all(position: rank)
          end
        end
      end
    end
  end
end
