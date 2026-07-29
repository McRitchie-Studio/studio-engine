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
        class_attribute :board_reorder_model,       instance_accessor: false
        class_attribute :board_reorder_id_attr,     instance_accessor: false, default: :slug
        class_attribute :board_reorder_param,       instance_accessor: false, default: :slugs
        class_attribute :board_reorder_gap,         instance_accessor: false, default: 100
        class_attribute :board_reorder_direction,   instance_accessor: false, default: :desc
        # DG1/DG2/DG4 — optional column + lock config. Defaults keep the exact 0.28.0
        # kanban reorder: rank by the model's board_rank_attr, no lock skip. A depth
        # chart passes gap: 1, direction: :asc (1..N depths) + skip_locked: true.
        class_attribute :board_reorder_rank_attr,   instance_accessor: false, default: nil
        class_attribute :board_reorder_skip_locked, instance_accessor: false, default: false
        class_attribute :board_reorder_lock_attr,   instance_accessor: false, default: :locked
      end

      class_methods do
        # Configure the reorder action for this controller's board.
        def board_reorderable(model:, id_attr: :slug, param: :slugs, gap: 100, direction: :desc,
                              rank_attr: nil, skip_locked: false, lock_attr: :locked)
          self.board_reorder_model       = model
          self.board_reorder_id_attr     = id_attr
          self.board_reorder_param       = param
          self.board_reorder_gap         = gap
          self.board_reorder_direction   = direction
          self.board_reorder_rank_attr   = rank_attr
          self.board_reorder_skip_locked = skip_locked
          self.board_reorder_lock_attr   = lock_attr
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

      # POST — flip a card's lock flag (DG4). A locked entry is a pinned card the
      # reorder skips (a confirmed depth-chart starter). Config-gated on the
      # board_reorderable model + lock_attr; mirrors the MS depth-chart toggle_lock,
      # INCLUDING its rescue_and_log(target: record) backend-write discipline, and
      # the same respond_to? degrade the reorder action uses. Route it however the
      # app names the endpoint (e.g. `post "…/:id/toggle_lock"`).
      def board_toggle_lock
        model = self.class.board_reorder_model
        raise "board_reorderable model not configured" unless model

        id_attr   = self.class.board_reorder_id_attr
        lock_attr = self.class.board_reorder_lock_attr
        record    = model.find_by(id_attr => params[:id])
        return render(json: { error: "not found" }, status: :not_found) unless record

        flip = -> { record.update!(lock_attr => !record.public_send(lock_attr)) }
        if respond_to?(:rescue_and_log)
          rescue_and_log(target: record) { flip.call }
        else
          flip.call
        end
        render json: { ok: true, locked: record.public_send(lock_attr) }
      rescue StandardError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      # Delegate to the model's Rankable#reposition! when available (the shared
      # rank rule), else fall back to the same per-id update_all loop inline so a
      # model that only carries a rank column still reorders. Threads the DG1 rank
      # column and DG4 lock-skip config through both paths.
      def board_reorder_apply(model, ids)
        id_attr     = self.class.board_reorder_id_attr
        gap         = self.class.board_reorder_gap
        direction   = self.class.board_reorder_direction
        rank_attr   = self.class.board_reorder_rank_attr
        skip_locked = self.class.board_reorder_skip_locked
        lock_attr   = self.class.board_reorder_lock_attr

        if model.respond_to?(:reposition!)
          kwargs = { gap: gap, direction: direction, id_attr: id_attr,
                     skip_locked: skip_locked, lock_attr: lock_attr }
          kwargs[:rank_attr] = rank_attr if rank_attr
          model.reposition!(ids, **kwargs)
        else
          rank_col = rank_attr || :position
          length = ids.length
          ids.each_with_index do |id, index|
            rank = direction.to_sym == :asc ? (index + 1) * gap : (length - index) * gap
            rel  = model.where(id_attr => id)
            rel  = rel.where.not(lock_attr => true) if skip_locked
            rel.update_all(rank_col => rank)
          end
        end
      end
    end
  end
end
