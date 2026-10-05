# frozen_string_literal: true

module Studio
  # The public survey pages (docs/SURVEYS.md). Drawn only when
  # Studio.draw_survey_routes is on.
  #
  #   GET   /surveys/:slug               the survey: one question per screen with JS,
  #                                      a single form without it
  #   PATCH /surveys/:slug/answers/:key  autosave one answer (JSON)
  #   POST  /surveys/:slug               submit: store every answer, complete, thank
  #   GET   /surveys/:slug/thanks        the thank-you screen and next action
  #
  # A response row is created on the FIRST ANSWER, not on page view, so a link
  # preview bot or a bounce never counts as "started".
  class SurveysController < ::ApplicationController
    skip_before_action :require_authentication, raise: false

    before_action :load_survey
    before_action :require_table
    before_action :require_respondent

    def show
      @response = locate_response
      return redirect_to(studio_survey_thanks_path(@survey.slug), status: :see_other) if @response&.completed?

      @errors = {}
      render_survey
    end

    def answer
      question = @survey.question(params[:key])
      return render(json: { error: "unknown question" }, status: :not_found) unless question

      response = open_response!
      return render(json: { error: "already complete" }, status: :conflict) unless response

      ok, error = rescue_survey_write(response) { response.record_answer(question, params[:value]) }
      if ok
        render json: { saved: true, key: question.key, answered: response.answers.keys & @survey.keys }
      else
        render json: { saved: false, error: error }, status: :unprocessable_entity
      end
    end

    def submit
      response = open_response!
      return redirect_to(studio_survey_thanks_path(@survey.slug), status: :see_other) unless response

      submitted = submitted_answers
      @errors = {}
      Studio::SurveyResponse.transaction do
        @survey.questions.each do |question|
          next unless submitted.key?(question.key)

          ok, error = response.record_answer(question, submitted[question.key])
          @errors[question.key] = error unless ok
        end
      end
      response.missing_required(@survey).each { |key| @errors[key] ||= "This one is required." }

      if @errors.empty? && response.complete!(@survey)
        run_completed_hook(response)
        redirect_to studio_survey_thanks_path(@survey.slug), status: :see_other
      elsif response.completed?
        # A racing submit completed it first; that one fired the hook.
        redirect_to studio_survey_thanks_path(@survey.slug), status: :see_other
      else
        @response = response
        render_survey(status: :unprocessable_entity)
      end
    end

    def thanks
      @response = locate_response
      redirect_to(studio_survey_path(@survey.slug), status: :see_other) unless @response&.completed?
    end

    private

    def load_survey
      @survey = Studio.survey(params[:slug])
      render :not_found, status: :not_found unless @survey
    end

    def require_table
      return if Studio::SurveyResponse.table_ready?

      raise Studio::SurveyResponse::MissingTable,
            "studio_survey_responses is not installed — run bin/rails studio_engine:install:migrations && bin/rails db:migrate"
    end

    # Signed in, arrived by an attributed email link, or an anonymous survey.
    def require_respondent
      return if @survey.allow_anonymous? || survey_user || survey_ref.present?

      render :sign_in_required, status: :unauthorized
    end

    def render_survey(status: :ok)
      @resume_key = @errors.keys.first || @response&.resume_key(@survey)
      @resume_index = @resume_key ? @survey.keys.index(@resume_key) : nil
      render :show, status: status
    end

    def survey_user
      return @survey_user if defined?(@survey_user)

      @survey_user = respond_to?(:current_user, true) ? current_user : nil
    end

    def survey_ref
      return @survey_ref if defined?(@survey_ref)

      @survey_ref = begin
        Studio.survey_ref_resolver&.call(self).to_s.strip.presence
      rescue StandardError => e
        log_survey_error(e)
        nil
      end
    end

    def token_key = "studio_survey_#{@survey.slug}"

    def session_token
      session[token_key] ||= SecureRandom.urlsafe_base64(24)
    end

    def locate_response
      Studio::SurveyResponse.locate(@survey, user: survey_user, token: session[token_key])
    end

    # The visitor's open response, created on demand; nil if theirs is complete.
    def open_response!
      existing = locate_response
      return nil if existing&.completed?

      response = existing || Studio::SurveyResponse.open_for!(
        @survey, user: survey_user, token: session_token, email_ref: survey_ref, user_agent: request.user_agent
      )
      response.update!(email_ref: survey_ref.first(255)) if response.email_ref.blank? && survey_ref.present?
      response
    end

    def submitted_answers
      raw = params[:answers]
      return {} unless raw.respond_to?(:permit)

      permitted = @survey.questions.map { |q| q.multi? ? { q.key => [] } : q.key }
      raw.permit(*permitted).to_h
    end

    def rescue_survey_write(target)
      yield
    rescue ActiveRecord::ActiveRecordError => e
      log_survey_error(e, target: target)
      [false, "Couldn't save that answer. Please try again."]
    end

    def run_completed_hook(response)
      Studio.on_survey_completed&.call(response)
    rescue StandardError => e
      log_survey_error(e, target: response)
    end

    def log_survey_error(error, target: nil)
      log = defined?(::ErrorLog) && ::ErrorLog.respond_to?(:capture!) ? ::ErrorLog.capture!(error) : nil
      log.update(target: target) if log && target && log.respond_to?(:target=)
      Rails.logger.error("[studio-survey] #{error.class}: #{error.message}")
    rescue StandardError
      Rails.logger.error("[studio-survey] #{error.class}: #{error.message}")
    end
  end
end
