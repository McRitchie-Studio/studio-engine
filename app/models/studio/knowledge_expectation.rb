module Studio
  # One row per document the knowledge layer EXPECTS — the other half of the
  # coverage question. Documents record what exists; expectations record what
  # should, so the gap between them is computable instead of remembered.
  #
  # Two cadences:
  #
  #   once    — a single fulfilling document satisfies it forever (an LOI, a
  #             lease, tracker item 14).
  #   monthly — one document per calendar month from start_on onward (aging
  #             inventory, bank statements). Each month is a SLOT; a slot is
  #             filled when a linked doc's as-of date falls inside it, and the
  #             coverage view names the missing months outright.
  #
  # Fulfillment is an EXPLICIT link — Studio::KnowledgeDoc#expectation_id, set
  # at triage — never a name match: a fuzzy matcher silently merges lookalike
  # documents, an id never does.
  #
  # Installed per consumer like the other studio_* tables.
  class KnowledgeExpectation < ApplicationRecord
    self.table_name = "studio_knowledge_expectations"

    CADENCES = %w[once monthly].freeze

    has_many :docs, class_name: "Studio::KnowledgeDoc",
                    foreign_key: :expectation_id, inverse_of: :expectation,
                    dependent: :nullify

    validates :entity, presence: true
    validates :title, presence: true
    validates :cadence, inclusion: { in: CADENCES }

    before_validation :normalize_fields

    scope :for_entity, ->(entity) { where(entity: entity) }
    scope :active,     -> { where(active: true) }

    def monthly?
      cadence == "monthly"
    end

    # The linked documents that can fill slots — superseded rows never count.
    def fulfilling_docs
      docs.active.to_a
    end

    # Monthly slot months, oldest first: start_on's month (or this row's
    # creation month) through as_of's month. Nil for once-cadence.
    def slot_months(as_of: Date.current)
      return nil unless monthly?

      first = (start_on || created_at&.to_date || as_of).beginning_of_month
      last  = as_of.beginning_of_month
      return [] if first > last

      months = []
      cursor = first
      while cursor <= last
        months << cursor
        cursor = cursor.next_month
      end
      months
    end

    # Coverage for the view, one shape per cadence:
    #   once:    { filled: bool, docs: [...] }
    #   monthly: { slots: [{ month:, docs: [...] }], missing_months: [...] }
    def coverage(as_of: Date.current)
      linked = fulfilling_docs
      return { filled: linked.any?, docs: linked } unless monthly?

      slots = slot_months(as_of: as_of).map do |month|
        { month: month,
          docs: linked.select { |doc| doc.display_date&.beginning_of_month == month } }
      end
      { slots: slots, missing_months: slots.select { |slot| slot[:docs].empty? }.map { |slot| slot[:month] } }
    end

    def filled?(as_of: Date.current)
      result = coverage(as_of: as_of)
      monthly? ? result[:missing_months].empty? : result[:filled]
    end

    private

    def normalize_fields
      self.entity = entity.to_s.strip.downcase if entity
      self.path   = Studio::KnowledgeDoc.normalize_path(path)
    end
  end
end
