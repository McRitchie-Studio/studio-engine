module Studio
  module AdminModels
    extend ActiveSupport::Concern

    PER_PAGE = 25
    TEAM_SORTS = {
      "team" => "LOWER(teams.name)",
      "sport" => "LOWER(COALESCE(teams.sport, ''))",
      "league" => "LOWER(COALESCE(teams.league, ''))"
    }.freeze
    SHARED_TABLE_KEYS = %w[teams arenas].freeze
    SESSIONS_CONFIG = { label: "Sessions", description: "Signed-in sessions, most recent first" }.freeze

    included do
      before_action :set_model_config, only: :show
      helper Studio::AdminModelsTableHelper
      helper_method :admin_model_configs, :team_sort_url, :team_sort_indicator, :team_sport_emoji,
                    :team_record_json, :admin_models_table_partial
    end

    # The first tab. Each model has its own tab and page (#show); this page is that
    # first one, so /admin/models always shows a table.
    def index
      @key = admin_model_configs.keys.first.to_s
      @config = admin_model_configs.fetch(@key)
      @scope = admin_model_scope(@key)
      show
    end

    def show
      @page = [params[:page].to_i, 1].max
      @total_count = @scope.count
      @total_pages = [(@total_count.to_f / PER_PAGE).ceil, 1].max
      @records = @scope.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)

      render "studio/admin_models/show"
    end

    private

    def set_model_config
      @key = params[:key].to_s
      @config = admin_model_configs.fetch(@key) { raise ActiveRecord::RecordNotFound }
      @scope = admin_model_scope(@key)
    end

    # The host's models, with the engine's standard ones after its Users tab. A host
    # adds a model by adding it to MODELS and answering it in #admin_model_scope_for.
    def admin_model_configs
      configs = self.class::MODELS.to_a
      return configs.to_h unless Studio::UserSession.available?

      at = (configs.index { |key, _| key.to_s == "users" } || -1) + 1
      configs.insert(at, ["sessions", SESSIONS_CONFIG]).to_h
    end

    def admin_model_scope(key)
      return Studio::UserSession.includes(:user).recent if key.to_s == "sessions"

      admin_model_scope_for(key)
    end

    def admin_model_scope_for(_key)
      raise NotImplementedError, "#{self.class.name} must implement #admin_model_scope_for"
    end

    def team_sort_key
      TEAM_SORTS.key?(params[:sort].to_s) ? params[:sort].to_s : "team"
    end

    def team_sort_direction
      params[:direction].to_s == "desc" ? "desc" : "asc"
    end

    def team_sort_order
      direction = team_sort_direction == "desc" ? "DESC" : "ASC"
      expression = TEAM_SORTS.fetch(team_sort_key)
      Arel.sql("#{expression} #{direction}, LOWER(teams.name) ASC")
    end

    def team_sort_url(key)
      query = request.query_parameters.merge(
        "sort" => key,
        "direction" => team_sort_key == key && team_sort_direction == "asc" ? "desc" : "asc"
      )
      query.delete("page")

      "#{request.path}?#{query.to_query}"
    end

    def team_sort_indicator(key)
      return "" unless team_sort_key == key

      team_sort_direction
    end

    def team_sport_emoji(team)
      case team.sport.to_s
      when "football" then "🏈"
      when "soccer" then "⚽"
      when "basketball" then "🏀"
      when "baseball" then "⚾"
      when "hockey" then "🏒"
      else "•"
      end
    end

    def team_record_json(team)
      payload = team.attributes.merge("mascot" => team.mascot)
      payload["home_arena"] = team.home_arena&.attributes if team.respond_to?(:home_arena)

      JSON.pretty_generate(payload)
    end

    def admin_models_table_partial(key)
      return "studio/admin_models/sessions_table" if key.to_s == "sessions"

      shared_table_keys = if self.class.const_defined?(:SHARED_TABLE_KEYS, false)
        self.class::SHARED_TABLE_KEYS
      else
        SHARED_TABLE_KEYS
      end

      if shared_table_keys.map(&:to_s).include?(key.to_s)
        "studio/admin_models/#{key}_table"
      else
        "admin/models/#{key}_table"
      end
    end
  end
end
