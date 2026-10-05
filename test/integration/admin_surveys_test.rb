# frozen_string_literal: true

require "bundler/setup"
require_relative "../support/survey_host"

# [integration] The admin results panel: the engine's admin gate, the index
# funnel counts, the per-question breakdown math as rendered, the text answer
# list, the date and completed-only filters, and the CSV export.
class AdminSurveysTest < ActionDispatch::IntegrationTest
  include SurveyHost

  setup do
    SurveyHost.define_surveys!
    Studio::SurveyResponse.delete_all
    User.delete_all
    @admin = User.create!(email: "admin@example.test", username: "boss", role: "admin")
    @pat = User.create!(email: "pat@example.test", username: "pat")
  end

  def respond!(answers, user: nil, completed: true, started_at: Time.current)
    response = Studio::SurveyResponse.create!(survey_slug: "first-game", user_id: user&.id,
                                              session_token: SecureRandom.hex(4), started_at: started_at)
    answers.each { |key, value| response.record_answer(survey.question(key), value) }
    response.update!(completed_at: started_at + 60) if completed
    response
  end

  def seed!
    respond!({ overall: 5, found_us: "email", liked: %w[board art], more: "Loved the board" }, user: @pat)
    respond!({ overall: 5, found_us: "email", liked: %w[board], more: "=cmd|calc" })
    respond!({ overall: 2, found_us: "search", more: "Too slow" }, started_at: 10.days.ago)
    respond!({ overall: 1 }, completed: false)
  end

  # --- the gate -----------------------------------------------------------------

  test "a signed-out visitor and a non-admin are turned away" do
    get "/admin/surveys"
    assert_response :redirect

    sign_in @pat
    get "/admin/surveys"
    assert_redirected_to "/"
    get "/admin/surveys/first-game"
    assert_redirected_to "/"
    get "/admin/surveys/first-game/export"
    assert_redirected_to "/"
  end

  # --- index ------------------------------------------------------------------------

  test "the index lists every survey with started, completed and completion rate" do
    seed!
    sign_in @admin
    get "/admin/surveys"

    assert_response :success
    row = response.body[/data-admin-survey-row="first-game".*?<\/tr>/m]
    assert_includes row, %(data-stat="started">4<)
    assert_includes row, %(data-stat="completed">3<)
    assert_includes row, %(data-stat="rate">75%<)
    members = response.body[/data-admin-survey-row="members-only".*?<\/tr>/m]
    assert_includes members, "—", "no responses reads as a dash, not 0%"
  end

  test "a slug with responses but no definition still lists" do
    Studio::SurveyResponse.create!(survey_slug: "retired-survey", session_token: "x", completed_at: Time.current)
    sign_in @admin
    get "/admin/surveys"
    assert_includes response.body, "definition removed"

    get "/admin/surveys/retired-survey"
    assert_response :success
    assert_includes response.body, "definition was removed"
  end

  # --- breakdown -----------------------------------------------------------------------

  test "the breakdown shows distribution percentages over those who answered" do
    seed!
    sign_in @admin
    get "/admin/surveys/first-game"

    assert_response :success
    overall = response.body[/data-survey-question="overall".*?<\/section>/m]
    assert_match(/data-survey-bucket="5".*?data-survey-percent>50%.*?data-survey-count>2</m, overall)
    assert_match(/data-survey-bucket="1".*?data-survey-percent>25%/m, overall)
    assert_includes overall, "data-survey-average>3.25<"

    liked = response.body[/data-survey-question="liked".*?<\/section>/m]
    assert_match(/data-survey-bucket="board".*?data-survey-percent>100%/m, liked, "percent of the two who answered")
    assert_match(/data-survey-bucket="art".*?data-survey-percent>50%/m, liked)
  end

  test "text answers list with the respondent's username or anonymous" do
    seed!
    sign_in @admin
    get "/admin/surveys/first-game"

    more = response.body[/data-survey-question="more".*?<\/section>/m]
    assert_includes more, "Loved the board"
    assert_includes more, "pat ·"
    assert_includes more, "anonymous ·"
    assert_includes more, "data-survey-text-answers"
  end

  test "completed-only and the date range narrow the breakdown" do
    seed!
    sign_in @admin

    get "/admin/surveys/first-game", params: { completed: "1" }
    assert_includes response.body, %(data-stat="started">3<)
    overall = response.body[/data-survey-question="overall".*?<\/section>/m]
    assert_match(/data-survey-bucket="1".*?data-survey-count>0</m, overall, "the open response drops out")

    get "/admin/surveys/first-game", params: { from: 2.days.ago.to_date.iso8601 }
    assert_includes response.body, %(data-stat="started">3<), "the ten-day-old response is outside the range"
    refute_includes response.body, "Too slow"

    get "/admin/surveys/first-game", params: { to: 5.days.ago.to_date.iso8601 }
    assert_includes response.body, %(data-stat="started">1<)
    assert_includes response.body, "Too slow"
  end

  # --- CSV ---------------------------------------------------------------------------------

  test "the CSV export has a row per response and honours the filters" do
    seed!
    sign_in @admin
    get "/admin/surveys/first-game/export", params: { completed: "1" }

    assert_response :success
    assert_equal "text/csv; charset=utf-8", response.media_type + "; charset=utf-8"
    assert_match(/attachment; filename="survey-first-game-\d{8}\.csv"/, response.headers["Content-Disposition"])
    lines = response.body.split("\r\n")
    assert_equal Studio::Survey::Export::META + survey.keys, lines.first.split(",")
    assert_equal 4, lines.size, "header + three completed responses"
    assert(lines.any? { |l| l.include?("board; art") && l.include?(",pat,") })
    assert(lines.any? { |l| l.include?("'=cmd|calc") }, "a formula-shaped answer is defused")
  end
end
