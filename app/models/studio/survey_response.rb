# frozen_string_literal: true

module Studio
  # One respondent's answers to one Studio::Survey (docs/SURVEYS.md).
  #
  # The survey is app code; this row is the only thing stored. Each answer is a
  # self-describing snapshot — value, question label, type, and the option
  # label(s) chosen — so a response stays readable after its survey changes.
  class SurveyResponse < ApplicationRecord
    self.table_name = "studio_survey_responses"

    class MissingTable < StandardError; end

    belongs_to :user, class_name: "::User", optional: true

    validates :survey_slug, presence: true
    validates :started_at, presence: true

    scope :completed, -> { where.not(completed_at: nil) }
    scope :in_progress, -> { where(completed_at: nil) }
    scope :for_survey, ->(slug) { where(survey_slug: slug.to_s) }

    before_validation { self.started_at ||= Time.current }

    UA_BOT = /bot|crawl|spider|slurp|preview|facebookexternalhit|curl|wget|python|headless/i
    UA_TABLET = /ipad|tablet|kindle|silk|(android(?!.*mobile))/i
    UA_MOBILE = /mobi|iphone|ipod|android|blackberry|opera mini|iemobile/i

    class << self
      def table_ready?
        table_exists?
      rescue ActiveRecord::ActiveRecordError, NameError
        false
      end

      # The coarse device class stored instead of the raw user agent.
      def user_agent_class(user_agent)
        ua = user_agent.to_s
        return "unknown" if ua.strip.empty?
        return "bot" if ua.match?(UA_BOT)
        return "tablet" if ua.match?(UA_TABLET)
        return "mobile" if ua.match?(UA_MOBILE)

        "desktop"
      end

      # The visitor's open response, or their latest completed one: by user
      # first, then by the session token. An anonymous response found by token
      # is claimed by the user who signs in mid-survey, and the claim drops the
      # token: logout keeps the survey session key, so a token on a user's row
      # would hand it to the next person to sign in on that browser.
      def locate(survey, user: nil, token: nil)
        scope = for_survey(survey.slug)
        found = user && scope.where(user_id: user.id).order(completed_at: :desc, id: :desc).find_by(completed_at: nil)
        found ||= token.present? && scope.where(session_token: token, user_id: nil).order(id: :desc).first
        found ||= user && scope.where(user_id: user.id).order(id: :desc).first
        return nil unless found

        found.update!(user_id: user.id, session_token: nil) if user && found.user_id.nil? && found.open?
        found
      end

      # Find the visitor's open response or start one. The partial unique
      # indexes make a double-click race lose to the row that won.
      def open_for!(survey, user: nil, token:, email_ref: nil, user_agent: nil)
        existing = locate(survey, user: user, token: token)
        return existing if existing&.open?

        create!(survey_slug: survey.slug, survey_version: survey.version, user_id: user&.id,
                session_token: (token unless user), email_ref: email_ref.to_s.strip.presence&.first(255),
                user_agent_class: user_agent_class(user_agent), answers: {})
      rescue ActiveRecord::RecordNotUnique
        locate(survey, user: user, token: token) || raise
      end
    end

    def open? = completed_at.nil?
    def completed? = completed_at.present?

    def answer_entry(key) = (answers || {})[key.to_s]
    def answer_value(key) = answer_entry(key)&.dig("value")

    def answered?(question)
      entry = answer_entry(question.key)
      entry.is_a?(Hash) && !question.blank_value?(entry["value"])
    end

    # Stores one answer (or clears it, for a blank). Returns [ok, error]. Never
    # touches a completed response: a finished survey is a record, not a draft.
    def record_answer(question, raw)
      return [false, "This survey is already complete."] if completed?

      value, error = question.normalize(raw)
      return [false, error] if error

      next_answers = (answers || {}).dup
      if value.nil?
        next_answers.delete(question.key)
      else
        next_answers[question.key] = {
          "value" => value, "label" => question.label, "type" => question.type.to_s,
          "display" => question.display(value), "answered_at" => Time.current.utc.iso8601
        }
      end
      self.answers = next_answers
      self.current_key = question.key
      save!
      [true, nil]
    end

    def missing_required(survey)
      survey.questions.select { |q| q.required? && !answered?(q) }.map(&:key)
    end

    # The first unanswered question — where a returning respondent resumes.
    def resume_key(survey)
      survey.questions.find { |q| !answered?(q) }&.key || survey.questions.last.key
    end

    # Completes the response if every required question is answered. Returns
    # true when this call completed it (false if incomplete or already done).
    def complete!(survey)
      return false if completed? || missing_required(survey).any?

      update!(completed_at: Time.current, survey_version: survey.version)
      true
    end

    # "username" for a signed-in respondent, "anonymous" otherwise.
    def respondent_label
      return "anonymous" unless user

      user.try(:username).presence || user.try(:display_name).presence || "user ##{user.id}"
    end
  end
end
