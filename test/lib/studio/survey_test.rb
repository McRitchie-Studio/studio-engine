# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/studio/survey"
require_relative "../../../lib/studio/survey/breakdown"
require_relative "../../../lib/studio/survey/export"

# [unit] Studio::Survey — the definition DSL, its validation, answer
# normalization, the version stamp, the results breakdown arithmetic and the
# CSV export. All pure Ruby; storage and the HTTP flow are in
# test/integration/survey_*_test.rb.
class SurveyDslTest < Minitest::Test
  def setup
    Studio::Survey.reset!
  end

  def teardown
    Studio::Survey.reset!
  end

  def define(slug = "first-game", &block)
    Studio::Survey.define(slug) do
      title "How was your first game?"
      instance_eval(&block) if block
    end
  end

  def full_survey
    define do
      intro "Six quick questions."
      thank_you "Thanks!"
      next_action label: "Play again", url: "/play"
      allow_anonymous true
      emoji_scale :overall, "How was it?", required: true
      rating :rules, "How clear were the rules?", low_label: "Lost", high_label: "Clear"
      choice :found_us, "How did you find us?", options: ["Email", "A friend", { value: "web", label: "Search" }]
      multi_choice :liked, "What did you enjoy?", options: %w[Board Pace Art]
      short_text :word, "One word?", max_length: 20
      long_text :more, "Anything else?", help: "All welcome."
    end
  end

  # --- the DSL ---------------------------------------------------------------

  def test_defines_and_registers_a_survey_with_all_six_types
    survey = full_survey

    assert_same survey, Studio::Survey.find("first-game")
    assert_equal %w[overall rules found_us liked word more], survey.keys
    assert_equal %i[emoji_scale rating choice multi_choice short_text long_text], survey.questions.map(&:type)
    assert_equal ["overall"], survey.required_keys
    assert survey.allow_anonymous?
    assert_equal({ label: "Play again", url: "/play" }, survey.next_action)
    assert_equal "All welcome.", survey.question(:more).help
  end

  def test_emoji_scale_has_five_faces_with_default_or_custom_labels
    q = full_survey.question(:overall)
    assert_equal 5, q.options.size
    assert_equal Studio::Survey::EMOJI_FACES, q.options.map(&:face)
    assert_equal Studio::Survey::DEFAULT_EMOJI_LABELS, q.options.map(&:label)

    custom = define("x") { emoji_scale :mood, "Mood?", labels: %w[A B C D E] }
    assert_equal %w[A B C D E], custom.question(:mood).options.map(&:label)
  end

  def test_choice_option_values_derive_from_labels_unless_given
    q = full_survey.question(:found_us)
    assert_equal %w[email a_friend web], q.options.map(&:value)
    assert_equal ["Email", "A friend", "Search"], q.options.map(&:label)
  end

  def test_questions_default_to_optional
    refute full_survey.question(:rules).required?
  end

  def test_redefining_a_slug_replaces_it
    define { short_text :a, "A?" }
    define { short_text :b, "B?" }
    assert_equal %w[b], Studio::Survey.find("first-game").keys
    assert_equal 1, Studio::Survey.all.size
  end

  # --- validation --------------------------------------------------------------

  def assert_definition_error(pattern, &block)
    error = assert_raises(Studio::Survey::DefinitionError, &block)
    assert_match pattern, error.message
  end

  def test_rejects_a_bad_slug
    assert_definition_error(/slug/) { Studio::Survey.define("First Game") { title "x"; short_text :a, "A" } }
  end

  def test_rejects_a_missing_title_and_an_empty_survey
    assert_definition_error(/title/) { Studio::Survey.define("a") { short_text :a, "A" } }
    assert_definition_error(/at least one question/) { define }
  end

  def test_rejects_duplicate_and_malformed_keys
    assert_definition_error(/duplicate/) { define { short_text :a, "A"; long_text :a, "B" } }
    assert_definition_error(/key/) { define { short_text :"Bad Key", "A" } }
  end

  def test_rejects_a_blank_label
    assert_definition_error(/label is required/) { define { short_text :a, "  " } }
  end

  def test_choice_needs_two_unique_options
    assert_definition_error(/two options/) { define { choice :a, "A", options: ["Only"] } }
    assert_definition_error(/unique/) { define { choice :a, "A", options: ["Yes", "yes"] } }
  end

  def test_type_specific_options_are_refused_elsewhere
    assert_definition_error(/only for choice/) { define { rating :a, "A", options: %w[x y] } }
    assert_definition_error(/only for emoji_scale/) { define { rating :a, "A", labels: %w[a b c d e] } }
    assert_definition_error(/exactly five/) { define { emoji_scale :a, "A", labels: %w[a b] } }
    assert_definition_error(/only for rating/) { define { emoji_scale :a, "A", low_label: "x" } }
    assert_definition_error(/max_length/) { define { rating :a, "A", max_length: 3 } }
  end

  def test_unknown_keyword_is_an_argument_error
    assert_raises(ArgumentError) { define { rating :a, "A", requird: true } }
  end

  def test_next_action_must_be_a_path_or_http_url
    assert_definition_error(/next_action url/) { define { next_action label: "Go", url: "javascript:alert(1)"; short_text :a, "A" } }
    assert_definition_error(/next_action url/) { define { next_action label: "Go", url: "//evil.test"; short_text :a, "A" } }
    assert define("ok") { next_action label: "Go", url: "https://cyvasse.test/play"; short_text :a, "A" }
  end

  # --- normalization -------------------------------------------------------------

  def test_scale_answers_normalize_to_integers_in_range
    q = full_survey.question(:overall)
    assert_equal [4, nil], q.normalize("4")
    assert_equal "Pick one of the options.", q.normalize("6").last
    assert_equal "Pick one of the options.", q.normalize("great").last
    assert_equal [nil, nil], q.normalize("")
    assert_equal "Good", q.display(4)
  end

  def test_choice_and_multi_choice_accept_only_listed_values
    survey = full_survey
    assert_equal ["web", nil], survey.question(:found_us).normalize("web")
    assert_equal "Pick one of the options.", survey.question(:found_us).normalize("tv").last
    assert_equal "Search", survey.question(:found_us).display("web")

    liked = survey.question(:liked)
    assert_equal [%w[board art], nil], liked.normalize(["art", "board", "art", ""])
    assert_equal [nil, nil], liked.normalize([""])
    assert_equal "Pick from the listed options.", liked.normalize(%w[board nope]).last
    assert_equal %w[Board Art], liked.display(%w[board art])
  end

  def test_text_answers_strip_and_respect_max_length
    q = full_survey.question(:word)
    assert_equal ["Fun", nil], q.normalize("  Fun  ")
    assert_match(/under 20/, q.normalize("x" * 21).last)
    assert_equal 5000, full_survey.question(:more).max_length
  end

  # --- versioning ------------------------------------------------------------------

  def test_version_is_a_digest_that_moves_when_questions_change
    v1 = define { short_text :a, "A?" }.version
    same = define { short_text :a, "A?" }.version
    v2 = define { short_text :a, "A, reworded?" }.version

    assert_equal v1, same
    refute_equal v1, v2
    assert_equal "2026-10", define { version "2026-10"; short_text :a, "A?" }.version
  end

  # --- breakdown ---------------------------------------------------------------------

  def entry(question, value)
    { "value" => value, "label" => question.label, "display" => question.display(value) }
  end

  def test_breakdown_counts_percentages_and_average_over_answerers
    survey = full_survey
    overall = survey.question(:overall)
    rows = [5, 5, 4, 1].map { |v| { answers: { "overall" => entry(overall, v) }, respondent: "a", at: Time.at(0) } }
    rows << { answers: {}, respondent: "anonymous", at: Time.at(0) } # skipped: does not dilute

    result = Studio::Survey::Breakdown.new(survey, rows).results.first
    assert_equal 4, result.answered
    assert_equal [1, 0, 0, 1, 2], result.buckets.map(&:count)
    assert_equal [25, 0, 0, 25, 50], result.buckets.map(&:percent)
    assert_equal 3.75, result.average
  end

  def test_breakdown_keeps_retired_options_under_their_snapshot
    survey = full_survey
    rows = [
      { answers: { "found_us" => { "value" => "tv", "display" => "Television" } }, respondent: "a", at: nil },
      { answers: { "found_us" => { "value" => "email", "display" => "Email" } }, respondent: "b", at: nil }
    ]
    found = Studio::Survey::Breakdown.new(survey, rows).results.find { |r| r.question.key == "found_us" }
    retired = found.buckets.find(&:retired)
    assert_equal "Television", retired.label
    assert_equal 1, retired.count
    assert_equal 50, retired.percent
  end

  def test_multi_choice_percent_is_of_respondents_not_selections
    survey = full_survey
    liked = survey.question(:liked)
    rows = [%w[board art], %w[board]].map { |v| { answers: { "liked" => entry(liked, v) } } }
    result = Studio::Survey::Breakdown.new(survey, rows).results.find { |r| r.question.key == "liked" }
    assert_equal({ "board" => 100, "pace" => 0, "art" => 50 }, result.buckets.to_h { |b| [b.value, b.percent] })
  end

  def test_text_breakdown_lists_newest_first_with_respondent
    survey = full_survey
    rows = [
      { answers: { "more" => { "value" => "old" } }, respondent: "alex", at: Time.at(10) },
      { answers: { "more" => { "value" => "new" } }, respondent: nil, at: Time.at(20) }
    ]
    result = Studio::Survey::Breakdown.new(survey, rows).results.last
    assert_equal %w[new old], result.entries.map(&:text)
    assert_equal %w[anonymous alex], result.entries.map(&:respondent)
  end

  def test_percent_of_zero_is_zero
    assert_equal 0, Studio::Survey::Breakdown.percent(3, 0)
    assert_equal 33, Studio::Survey::Breakdown.percent(1, 3)
  end

  # --- export --------------------------------------------------------------------------

  def test_export_has_a_column_per_key_including_retired_keys
    survey = full_survey
    rows = [{ response_id: 1, status: "completed", respondent: "alex",
              answers: { "liked" => { "value" => %w[board art] }, "gone" => { "value" => "x" } } }]
    csv = Studio::Survey::Export.new(survey, rows).to_csv
    header, line = csv.split("\r\n")

    assert_equal Studio::Survey::Export::META + survey.keys + ["gone"], header.split(",")
    assert_includes line, "board; art"
    assert line.end_with?(",x")
  end

  def test_export_quotes_and_defuses_formula_cells
    assert_equal %("a,b"), Studio::Survey::Export.cell("a,b")
    assert_equal %("say ""hi"""), Studio::Survey::Export.cell(%(say "hi"))
    assert_equal "'=HYPERLINK(1)", Studio::Survey::Export.cell("=HYPERLINK(1)")
    assert_equal "'@x", Studio::Survey::Export.cell("@x")
  end

  def test_export_with_no_definition_still_lists_stored_keys
    csv = Studio::Survey::Export.new(nil, [{ answers: { "b" => { "value" => 1 }, "a" => { "value" => 2 } } }]).to_csv
    assert csv.start_with?((Studio::Survey::Export::META + %w[a b]).join(","))
  end
end
