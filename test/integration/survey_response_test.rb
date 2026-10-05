# frozen_string_literal: true

require "bundler/setup"
require_relative "../support/survey_host"

# [unit] Studio::SurveyResponse against the engine's real migration: answer
# storage with label snapshots, versioning across a definition change,
# autosave/resume, completion, one open response per user and per session,
# and the coarse user-agent class kept instead of the raw header.
class SurveyResponseTest < ActiveSupport::TestCase
  include SurveyHost

  setup do
    SurveyHost.define_surveys!
    Studio::SurveyResponse.delete_all
    User.delete_all
    @user = User.create!(email: "pat@example.test", username: "pat")
  end

  def open!(user: nil, token: "tok-1", **opts)
    Studio::SurveyResponse.open_for!(survey, user: user, token: token, **opts)
  end

  test "an answer is stored with its key, label, type and option snapshot" do
    response = open!
    ok, error = response.record_answer(survey.question(:overall), "4")

    assert ok, error
    entry = response.reload.answers["overall"]
    assert_equal 4, entry["value"]
    assert_equal "How was it?", entry["label"]
    assert_equal "emoji_scale", entry["type"]
    assert_equal "Good", entry["display"]
    assert entry["answered_at"].present?
    assert_equal "overall", response.current_key
  end

  test "an invalid answer is refused and stores nothing" do
    response = open!
    ok, error = response.record_answer(survey.question(:found_us), "tv")

    refute ok
    assert_equal "Pick one of the options.", error
    assert_empty response.reload.answers
  end

  test "a blank answer clears an earlier one (autosave of an emptied field)" do
    response = open!
    response.record_answer(survey.question(:word), "fun")
    response.record_answer(survey.question(:word), "  ")

    refute response.reload.answers.key?("word")
  end

  test "old answers keep the label they were given under after the survey changes" do
    response = open!
    response.record_answer(survey.question(:overall), 5)
    old_version = response.survey_version

    Studio.define_survey "first-game" do
      title "How was your first game?"
      emoji_scale :overall, "Rate your very first game", required: true, labels: %w[1 2 3 4 Superb]
    end
    changed = Studio.survey("first-game")

    refute_equal old_version, changed.version
    entry = response.reload.answers["overall"]
    assert_equal "How was it?", entry["label"], "the stored label is the one the respondent saw"
    assert_equal "Loved it", entry["display"]
  end

  test "resume lands on the first unanswered question" do
    response = open!
    assert_equal "overall", response.resume_key(survey)

    response.record_answer(survey.question(:overall), 3)
    response.record_answer(survey.question(:rules), 4)
    assert_equal "found_us", response.reload.resume_key(survey)
  end

  test "locate finds the same open response by session token, then by user" do
    response = open!(token: "abc")
    assert_equal response, Studio::SurveyResponse.locate(survey, token: "abc")
    assert_nil Studio::SurveyResponse.locate(survey, token: "other")

    mine = open!(user: @user, token: "def")
    assert_equal mine, Studio::SurveyResponse.locate(survey, user: @user, token: nil)
  end

  test "an anonymous response is claimed by the user who signs in mid-survey" do
    response = open!(token: "abc")
    found = Studio::SurveyResponse.locate(survey, user: @user, token: "abc")

    assert_equal response, found
    assert_equal @user.id, response.reload.user_id
  end

  test "open_for! returns the existing open response instead of a second one" do
    first = open!(user: @user)
    second = open!(user: @user, token: "tok-2")

    assert_equal first, second
    assert_equal 1, Studio::SurveyResponse.count
  end

  test "a session token left by a previous user never reaches the next one" do
    claimed = open!(token: "shared")
    Studio::SurveyResponse.locate(survey, user: @user, token: "shared")
    direct = open!(user: @user, token: "shared")
    sam = User.create!(email: "sam@example.test", username: "sam")

    assert_equal claimed, direct
    assert_nil Studio::SurveyResponse.locate(survey, user: sam, token: "shared")
    refute_equal claimed, open!(user: sam, token: "shared")
    assert_nil Studio::SurveyResponse.locate(survey, token: "shared")
  end

  test "the database allows one open response per user and per session" do
    open!(user: @user)
    open!(token: "a")
    assert_raises(ActiveRecord::RecordNotUnique) do
      Studio::SurveyResponse.create!(survey_slug: "first-game", user_id: @user.id, session_token: "b")
    end
    assert_raises(ActiveRecord::RecordNotUnique) do
      Studio::SurveyResponse.create!(survey_slug: "first-game", session_token: "a")
    end
  end

  test "complete! needs every required answer, then stamps completed_at once" do
    response = open!
    response.record_answer(survey.question(:overall), 5)
    refute response.complete!(survey)
    assert_equal ["more"], response.missing_required(survey)

    response.record_answer(survey.question(:more), "Great fun")
    assert response.complete!(survey)
    assert response.completed?
    refute response.complete!(survey), "a second completion is a no-op"
  end

  test "a completed response frees the slot and refuses further answers" do
    response = open!(user: @user)
    response.record_answer(survey.question(:overall), 5)
    response.record_answer(survey.question(:more), "x")
    response.complete!(survey)

    ok, error = response.record_answer(survey.question(:overall), 1)
    refute ok
    assert_match(/already complete/, error)

    again = Studio::SurveyResponse.create!(survey_slug: "first-game", user_id: @user.id, session_token: "new")
    assert again.persisted?, "completed rows fall out of the one-open-response index"
  end

  test "the user agent is stored as a coarse class only" do
    ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Mobile/15E148"
    response = open!(user_agent: ua)

    assert_equal "mobile", response.user_agent_class
    refute_includes response.attributes.values.map(&:to_s), ua
    assert_equal "tablet", Studio::SurveyResponse.user_agent_class("Mozilla/5.0 (iPad; CPU OS 17_0)")
    assert_equal "desktop", Studio::SurveyResponse.user_agent_class("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0)")
    assert_equal "bot", Studio::SurveyResponse.user_agent_class("Slackbot-LinkExpanding 1.0")
    assert_equal "unknown", Studio::SurveyResponse.user_agent_class(nil)
  end

  test "the engine loads config/surveys at boot, and load_definitions! reloads it" do
    assert_includes SurveyHost::BOOT_KEYS, "one_word", "the dummy's config/surveys/first_game.rb was loaded on boot"

    Studio::Survey.reset!
    Studio::Survey.load_definitions!(Rails.root.join(Studio.survey_definitions_path))
    assert Studio.survey("first-game").question(:one_word)
    assert_equal [], Studio::Survey.load_definitions!(Rails.root.join("config/no-such-dir"))
  end

  test "respondent_label is the username, else anonymous" do
    assert_equal "anonymous", open!.respondent_label
    assert_equal "pat", open!(user: @user, token: "u").respondent_label
  end
end
