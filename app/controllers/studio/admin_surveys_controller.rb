# frozen_string_literal: true

module Studio
  # The survey results panel (docs/SURVEYS.md). Admin-only, drawn only when
  # Studio.draw_admin_survey_routes is on.
  #
  #   GET /admin/surveys                every survey: started, completed, rate
  #   GET /admin/surveys/:slug          per-question breakdown, filterable
  #   GET /admin/surveys/:slug/export   the same filtered responses as CSV
  #
  # A slug with stored responses but no definition left in app code still lists
  # and exports (its breakdown needs the definition, so its page says so).
  class AdminSurveysController < ::ApplicationController
    before_action :require_admin
    before_action :require_table

    def index
      started = Studio::SurveyResponse.group(:survey_slug).count
      completed = Studio::SurveyResponse.completed.group(:survey_slug).count
      slugs = (Studio.surveys.map(&:slug) + started.keys).uniq.sort
      @rows = slugs.map do |slug|
        s = started.fetch(slug, 0)
        c = completed.fetch(slug, 0)
        { slug: slug, survey: Studio.survey(slug), started: s, completed: c,
          rate: Studio::Survey::Breakdown.percent(c, s) }
      end
    end

    def show
      @slug = params[:slug].to_s
      @survey = Studio.survey(@slug)
      @filters = filters
      scope = filtered_scope
      @started = scope.count
      @completed = scope.completed.count
      return unless @survey

      @breakdown = Studio::Survey::Breakdown.new(@survey, breakdown_rows(scope))
    end

    def export
      slug = params[:slug].to_s
      survey = Studio.survey(slug)
      @filters = filters
      @slug = slug
      rows = filtered_scope.includes(:user).order(:id).map do |r|
        { response_id: r.id, survey_version: r.survey_version, status: r.completed? ? "completed" : "in_progress",
          started_at: r.started_at, completed_at: r.completed_at, respondent: r.respondent_label,
          user_id: r.user_id, email_ref: r.email_ref, user_agent_class: r.user_agent_class, answers: r.answers }
      end
      csv = Studio::Survey::Export.new(survey, rows).to_csv
      send_data csv, type: "text/csv; charset=utf-8",
                     filename: "survey-#{slug.parameterize}-#{Time.current.strftime("%Y%m%d")}.csv"
    end

    private

    def require_table
      return if Studio::SurveyResponse.table_ready?

      raise Studio::SurveyResponse::MissingTable,
            "studio_survey_responses is not installed — run bin/rails studio_engine:install:migrations && bin/rails db:migrate"
    end

    def filters
      {
        from: parse_date(params[:from]),
        to: parse_date(params[:to]),
        completed: params[:completed] == "1"
      }
    end

    def parse_date(value)
      Date.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # Dates filter on started_at, inclusive of both whole days.
    def filtered_scope
      scope = Studio::SurveyResponse.for_survey(@slug)
      scope = scope.where(started_at: @filters[:from].beginning_of_day..) if @filters[:from]
      scope = scope.where(started_at: ..@filters[:to].end_of_day) if @filters[:to]
      scope = scope.completed if @filters[:completed]
      scope
    end

    def breakdown_rows(scope)
      scope.includes(:user).order(:id).map do |r|
        { answers: r.answers, respondent: r.respondent_label, at: r.completed_at || r.updated_at }
      end
    end
  end
end
