# frozen_string_literal: true

module Studio
  class Survey
    # CSV for one survey's responses. One row per response; one column per
    # question key in the CURRENT definition, then any retired key a stored
    # answer still carries, so an export never drops data the definition forgot.
    #
    # Written without the csv gem (a bundled, not default, gem from Ruby 3.4):
    # RFC 4180 quoting, plus a leading apostrophe on any cell a spreadsheet
    # would execute as a formula (=, +, -, @, tab, CR) — respondents type these
    # cells, so they are untrusted.
    class Export
      META = %w[response_id survey_version status started_at completed_at respondent user_id email_ref user_agent_class].freeze
      FORMULA_LEAD = /\A[=+\-@\t\r]/

      # rows: hashes with the META keys (as symbols) plus :answers.
      def initialize(survey, rows)
        @survey = survey
        @rows = rows.to_a
      end

      def keys
        @keys ||= begin
          current = @survey.keys
          retired = @rows.flat_map { |r| (r[:answers] || {}).keys }.uniq - current
          current + retired.sort
        end
      end

      def to_csv
        lines = [line(META + keys)]
        @rows.each do |row|
          answers = row[:answers] || {}
          cells = META.map { |k| format_time(row[k.to_sym]) }
          cells += keys.map { |k| answer_cell(answers[k]) }
          lines << line(cells)
        end
        lines.join
      end

      def self.cell(value)
        text = value.to_s
        text = "'#{text}" if text.match?(FORMULA_LEAD)
        text.match?(/[",\n\r]/) || text != text.strip ? %("#{text.gsub('"', '""')}") : text
      end

      private

      def line(cells) = "#{cells.map { |c| self.class.cell(c) }.join(",")}\r\n"

      def format_time(value)
        value.respond_to?(:iso8601) ? value.iso8601 : value
      end

      def answer_cell(entry)
        return nil unless entry.is_a?(Hash)

        value = entry["value"]
        value.is_a?(Array) ? value.join("; ") : value
      end
    end
  end
end
