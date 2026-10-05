# frozen_string_literal: true

require "bundler/setup"
require_relative "../support/survey_host"

# [integration] The public survey flow over HTTP: the page (JS-free form and
# stepper markup), autosave, resume, submit and its validation, the thank-you
# screen, the three attribution paths (anonymous, signed-in, email ref), the
# completion hook, and the access gate for a non-anonymous survey.
class SurveyFlowTest < ActionDispatch::IntegrationTest
  include SurveyHost

  setup do
    SurveyHost.define_surveys!
    Studio::SurveyResponse.delete_all
    User.delete_all
    ErrorLog.delete_all
    @resolver = Studio.survey_ref_resolver
    @hook = Studio.on_survey_completed
    @completed = []
    Studio.on_survey_completed = ->(response) { @completed << response }
  end

  teardown do
    Studio.survey_ref_resolver = @resolver
    Studio.on_survey_completed = @hook
  end

  def complete_answers
    { overall: "5", rules: "4", found_us: "email", liked: ["", "board", "art"], word: "Tense", more: "Loved it" }
  end

  # --- the page --------------------------------------------------------------

  test "the page renders every question as a working form without JavaScript" do
    get "/surveys/first-game"

    assert_response :success
    body = response.body
    assert_includes body, "How was your first game?"
    assert_includes body, %(action="/surveys/first-game")
    assert_equal 5, body.scan('name="answers[overall]"').size, "five emoji faces"
    assert_equal 5, body.scan('name="answers[rules]"').size
    assert_includes body, 'name="answers[liked][]"'
    assert_includes body, "<textarea"
    assert_includes body, 'type="submit"'
    assert_includes body, "data-studio-survey"
    assert_includes body, "prefers-reduced-motion"
    assert_equal 6, body.scan("<fieldset").size, "one screen per question"
    assert_equal 0, Studio::SurveyResponse.count, "a page view never creates a response"
  end

  test "an unknown survey is a 404" do
    get "/surveys/no-such-survey"
    assert_response :not_found
    assert_includes response.body, "Survey not found"
  end

  # Drawn into a FRESH route set: the dummy's routes.rb turns both flags on at
  # the top of every reload, so reloading the app's routes cannot show "off".
  test "the routes are opt-in" do
    draw = lambda do |public_on, admin_on|
      Studio.draw_survey_routes = public_on
      Studio.draw_admin_survey_routes = admin_on
      ActionDispatch::Routing::RouteSet.new.tap { |set| set.draw { Studio.routes(self) } }.named_routes
    end

    off = draw.call(false, false)
    refute off.key?(:studio_survey)
    refute off.key?(:admin_surveys)

    public_only = draw.call(true, false)
    assert public_only.key?(:studio_survey)
    assert public_only.key?(:studio_survey_answer)
    refute public_only.key?(:admin_surveys), "the admin panel is its own opt-in"

    both = draw.call(true, true)
    assert both.key?(:admin_survey_export)
  ensure
    Studio.draw_survey_routes = true
    Studio.draw_admin_survey_routes = true
  end

  # --- autosave and resume ------------------------------------------------------

  test "autosave stores one answer and the page resumes at the next question" do
    get "/surveys/first-game"
    patch "/surveys/first-game/answers/overall", params: { value: "4" }, as: :json

    assert_response :success
    assert_equal true, response.parsed_body["saved"]
    stored = Studio::SurveyResponse.sole
    assert_equal 4, stored.answer_value("overall")
    assert_equal "anonymous", stored.respondent_label

    patch "/surveys/first-game/answers/liked", params: { value: %w[pace art] }
    assert_equal %w[pace art], stored.reload.answer_value("liked")
    assert_equal 1, Studio::SurveyResponse.count, "the same session keeps one response"

    get "/surveys/first-game"
    assert_includes response.body, 'data-resume-index="1"', "resumes at rules, the first unanswered"
    assert_match(/value="4"\s+checked/, response.body, "the saved answer is pre-selected")
  end

  test "autosave and submit pass CSRF with forgery protection and per-form tokens on" do
    forgery = ActionController::Base.allow_forgery_protection
    per_form = ActionController::Base.per_form_csrf_tokens
    ActionController::Base.allow_forgery_protection = true
    ActionController::Base.per_form_csrf_tokens = true
    Studio::SurveysController.allow_forgery_protection = true
    Studio::SurveysController.per_form_csrf_tokens = true

    get "/surveys/first-game"
    page_token = response.body[/data-csrf="([^"]+)"/, 1]
    form_token = response.body[/name="authenticity_token" value="([^"]+)"/, 1]
    assert page_token && form_token

    # Without a token the PATCH must be refused, or this test proves nothing.
    assert_raises(ActionController::InvalidAuthenticityToken) do
      patch "/surveys/first-game/answers/overall", params: { value: "4" }
    end

    patch "/surveys/first-game/answers/overall", params: { value: "4" }, headers: { "X-CSRF-Token" => page_token }
    assert_response :success

    post "/surveys/first-game", params: { authenticity_token: form_token, answers: complete_answers }
    assert_redirected_to "/surveys/first-game/thanks"
  ensure
    ActionController::Base.allow_forgery_protection = forgery
    ActionController::Base.per_form_csrf_tokens = per_form
    Studio::SurveysController.allow_forgery_protection = forgery
    Studio::SurveysController.per_form_csrf_tokens = per_form
  end

  test "autosave refuses an invalid value with a 422 and a message" do
    patch "/surveys/first-game/answers/rules", params: { value: "9" }
    assert_response :unprocessable_entity
    assert_equal "Pick one of the options.", response.parsed_body["error"]
  end

  test "autosave of an unknown question is a 404" do
    patch "/surveys/first-game/answers/nope", params: { value: "1" }
    assert_response :not_found
  end

  # --- submit ---------------------------------------------------------------------

  test "submit completes the response, fires the hook once and thanks the respondent" do
    post "/surveys/first-game", params: { answers: complete_answers }

    assert_redirected_to "/surveys/first-game/thanks"
    stored = Studio::SurveyResponse.sole
    assert stored.completed?
    assert_equal %w[board art], stored.answer_value("liked")
    assert_equal [stored], @completed

    follow_redirect!
    assert_includes response.body, "Thanks — we read every answer."
    assert_includes response.body, %(href="/play")
    assert_includes response.body, "Play again"

    get "/surveys/first-game"
    assert_redirected_to "/surveys/first-game/thanks", "a finished respondent is not asked again"
  end

  test "submit missing a required answer re-renders with the error and stores the rest" do
    post "/surveys/first-game", params: { answers: complete_answers.merge(more: "") }

    assert_response :unprocessable_entity
    assert_includes response.body, "This one is required."
    assert_includes response.body, 'data-resume-index="5"', "the stepper opens on the flagged question"
    stored = Studio::SurveyResponse.sole
    refute stored.completed?
    assert_equal 5, stored.answer_value("overall")
    assert_empty @completed
  end

  test "a raising completion hook is logged and the respondent still lands on thanks" do
    Studio.on_survey_completed = ->(_r) { raise "beacon down" }
    post "/surveys/first-game", params: { answers: complete_answers }

    assert_redirected_to "/surveys/first-game/thanks"
    assert Studio::SurveyResponse.sole.completed?
    assert_equal 1, ErrorLog.count
  end

  test "the thank-you page sends an unfinished visitor back to the survey" do
    get "/surveys/first-game/thanks"
    assert_redirected_to "/surveys/first-game"
  end

  # --- attribution ------------------------------------------------------------------

  test "a signed-in respondent is attributed to current_user" do
    user = User.create!(email: "pat@example.test", username: "pat")
    sign_in user
    post "/surveys/first-game", params: { answers: complete_answers }

    stored = Studio::SurveyResponse.sole
    assert_equal user.id, stored.user_id
    assert_equal "pat", stored.respondent_label
  end

  test "an email arrival is attributed through the app's ref resolver" do
    Studio.survey_ref_resolver = ->(controller) { controller.params[:ref] || controller.session[:email_ref] }
    get "/surveys/first-game", params: { ref: "em_abc123" }
    patch "/surveys/first-game/answers/overall", params: { value: "5", ref: "em_abc123" }

    assert_equal "em_abc123", Studio::SurveyResponse.sole.email_ref
    assert_nil Studio::SurveyResponse.sole.user_id
  end

  test "a raising ref resolver is logged and treated as no ref" do
    Studio.survey_ref_resolver = ->(_c) { raise "bad ref" }
    patch "/surveys/first-game/answers/overall", params: { value: "5" }

    assert_response :success
    assert_nil Studio::SurveyResponse.sole.email_ref
    assert_operator ErrorLog.count, :>=, 1
  end

  test "the user agent is stored as its class" do
    patch "/surveys/first-game/answers/overall", params: { value: "5" },
                                                 headers: { "User-Agent" => "Mozilla/5.0 (iPhone) Mobile/15E148" }
    assert_equal "mobile", Studio::SurveyResponse.sole.user_agent_class
  end

  # --- access ------------------------------------------------------------------------

  test "a survey without allow_anonymous asks a stranger to sign in" do
    get "/surveys/members-only"
    assert_response :unauthorized
    assert_includes response.body, "Sign in to answer this survey."

    patch "/surveys/members-only/answers/score", params: { value: "3" }
    assert_response :unauthorized
    assert_equal 0, Studio::SurveyResponse.count
  end

  test "a survey without allow_anonymous opens to a signed-in user or an email ref" do
    Studio.survey_ref_resolver = ->(controller) { controller.params[:ref] }
    get "/surveys/members-only", params: { ref: "em_1" }
    assert_response :success

    sign_in User.create!(email: "a@example.test")
    get "/surveys/members-only"
    assert_response :success
  end
end
