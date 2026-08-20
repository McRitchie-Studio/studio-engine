# frozen_string_literal: true

module Studio
  # The operator's geo choices for THIS app: whether the gate is live, which
  # countries it refuses outright, and which subdivisions of which country.
  #
  # One row per app (keyed by Studio.app_name), exactly like ThemeSetting — the
  # engine's other "this deployment's settings" table. The gate reads this row and
  # the published exclusion page renders THIS row, so the policy a visitor is told
  # about can never drift from the policy that is enforced.
  #
  # STORAGE VOCABULARY: `banned_subdivisions` holds region tokens — "US-WA", not
  # "WA" — because a bare code cannot say whether "CA" is California or Canada.
  # Bare codes are still accepted on the way in (an app migrating years of them
  # has a list of bare codes) and normalized against Studio.geo_home_country
  # before they are written. See Studio::Geo for the full vocabulary.
  #
  # NIL-SAFE THROUGHOUT, because the table is installed by a migration the host
  # runs. An app that has not run it yet must still boot, still serve, and still
  # answer "is this visitor blocked?" — with "no", since an app with no geo row
  # has declared no policy to enforce.
  class GeoSetting < ApplicationRecord
    include Sluggable

    self.table_name = "studio_geo_settings"

    validates :app_name, presence: true, uniqueness: true

    before_validation :normalize_lists

    class << self
      # This app's row, or an unsaved instance carrying the configured defaults.
      # Never nil, so a caller can always ask it a question.
      def current
        return new(default_attributes) unless table_ready?

        find_by(app_name: Studio.app_name) || new(default_attributes)
      end

      # The PUBLISHED exclusion list, as region tokens. Falls back to the
      # configured defaults when no row has been provisioned yet, so a fresh app
      # publishes the same list it enforces from its first request.
      def effective_banned_subdivisions
        setting = current
        list = setting.persisted? ? setting.banned_subdivisions : Studio.geo_default_banned_subdivisions
        normalize_tokens(list)
      end

      def effective_banned_countries
        setting = current
        list = setting.persisted? ? setting.banned_countries : Studio.geo_default_banned_countries
        Array(list).filter_map { |code| Studio::Geo.normalize_country(code) }.uniq.sort
      end

      # The gate is LIVE — a provisioned, enabled row. When false nothing is
      # geo-restricted at all, including the fail-closed branch: that is the
      # operator's kill switch, and it has to mean OFF rather than "off except
      # for the visitors we cannot place".
      def enforcing?
        setting = current
        setting.persisted? && setting.enabled?
      end

      # The verdict for one visitor. Pure policy lives in Studio::Geo; this
      # method's only job is to hand it this app's stored choices.
      def blocked?(country:, subdivision:)
        setting = current
        return false unless setting.persisted? && setting.enabled?

        Studio::Geo.blocked?(
          country: country,
          subdivision: subdivision,
          banned_countries: setting.banned_countries,
          banned_subdivisions: setting.banned_subdivisions,
          home_country: Studio.geo_home_country,
          enforcing: true,
          fail_closed: Studio.geo_fail_closed
        )
      end

      # Bare subdivision codes for one country — what a checkbox grid renders and
      # what a published list prints. "US-WA" -> "WA" for country "US".
      def banned_subdivision_codes(country: Studio.geo_home_country)
        prefix = "#{Studio::Geo.normalize_country(country)}-"
        effective_banned_subdivisions.filter_map { |token| token.delete_prefix(prefix) if token.start_with?(prefix) }
      end

      def default_attributes
        {
          app_name: Studio.app_name,
          enabled: false,
          banned_countries: Array(Studio.geo_default_banned_countries),
          banned_subdivisions: normalize_tokens(Studio.geo_default_banned_subdivisions)
        }
      end

      def normalize_tokens(list)
        Array(list)
          .filter_map { |token| Studio::Geo.normalize_region_token(token, home_country: Studio.geo_home_country) }
          .uniq
          .sort
      end

      def table_ready?
        table_exists?
      rescue ActiveRecord::ActiveRecordError, NameError
        false
      end
    end

    # Bare codes for the grid — the instance half of .banned_subdivision_codes,
    # reading THIS row rather than the effective list.
    def subdivision_codes(country: Studio.geo_home_country)
      prefix = "#{Studio::Geo.normalize_country(country)}-"
      Array(banned_subdivisions).filter_map { |token| token.delete_prefix(prefix) if token.to_s.start_with?(prefix) }
    end

    def name_slug
      "geo-#{app_name.to_s.parameterize}"
    end

    private

    # One vocabulary in the column. Whatever the form posted — bare codes from a
    # US grid, tokens from a country editor, blanks from unchecked boxes — is
    # canonicalised here rather than at each read site, so a later reader never
    # has to guess which form it is holding.
    def normalize_lists
      self.banned_subdivisions = self.class.normalize_tokens(banned_subdivisions)
      self.banned_countries = Array(banned_countries)
        .filter_map { |code| Studio::Geo.normalize_country(code) }
        .uniq
        .sort
      self.app_name = Studio.app_name if app_name.blank?
    end
  end
end
