# frozen_string_literal: true

module Studio
  class Survey
    # The per-question results the admin panel draws. Pure Ruby over plain rows,
    # so the arithmetic is unit-tested without a database.
    #
    #   rows: an Enumerable of hashes { answers: {key => {"value" => ...}},
    #                                   respondent: "alex" | "anonymous",
    #                                   at: Time }
    #
    # Counts are over the rows that ANSWERED the question, not all rows — a
    # skipped optional question does not dilute its own distribution. A stored
    # value whose option was later removed from the definition still counts,
    # under its label snapshot and marked retired, so editing a survey never
    # silently drops answers from the totals.
    class Breakdown
      Bucket = Struct.new(:value, :label, :face, :count, :percent, :retired, keyword_init: true)
      TextEntry = Struct.new(:text, :respondent, :at, keyword_init: true)
      Result = Struct.new(:question, :answered, :buckets, :average, :entries, keyword_init: true) do
        def text? = question.text?
      end

      def initialize(survey, rows)
        @survey = survey
        @rows = rows.to_a
      end

      def results
        @results ||= @survey.questions.map { |q| result_for(q) }
      end

      def self.percent(count, total)
        return 0 if total.to_i.zero?

        ((count.to_f / total) * 100).round
      end

      private

      def answers_for(question)
        @rows.filter_map do |row|
          entry = (row[:answers] || {})[question.key]
          next unless entry.is_a?(Hash) && !question.blank_value?(entry["value"])

          [entry, row]
        end
      end

      def result_for(question)
        found = answers_for(question)
        return text_result(question, found) if question.text?

        counts = Hash.new(0)
        snapshots = {}
        found.each do |entry, _row|
          displays = Array(entry["display"])
          Array(entry["value"]).each_with_index do |v, i|
            counts[v.to_s] += 1
            snapshots[v.to_s] ||= displays[i]
          end
        end

        total = found.size
        buckets = question.options.map do |opt|
          n = counts.delete(opt.value.to_s) || 0
          Bucket.new(value: opt.value, label: opt.label, face: opt.face, count: n,
                     percent: self.class.percent(n, total), retired: false)
        end
        counts.sort.each do |value, n|
          buckets << Bucket.new(value: value, label: snapshots[value].presence || value, count: n,
                                percent: self.class.percent(n, total), retired: true)
        end

        Result.new(question: question, answered: total, buckets: buckets, average: average(question, found), entries: [])
      end

      def average(question, found)
        return nil unless question.scale?

        nums = found.map { |entry, _| Integer(entry["value"].to_s, exception: false) }.compact
        return nil if nums.empty?

        (nums.sum.to_f / nums.size).round(2)
      end

      def text_result(question, found)
        entries = found.map do |entry, row|
          TextEntry.new(text: entry["value"].to_s, respondent: row[:respondent].presence || "anonymous", at: row[:at])
        end
        entries.sort_by! { |e| e.at || Time.at(0) }.reverse!
        Result.new(question: question, answered: entries.size, buckets: [], average: nil, entries: entries)
      end
    end
  end
end
