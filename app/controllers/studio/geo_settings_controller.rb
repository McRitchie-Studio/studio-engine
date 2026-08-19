# frozen_string_literal: true

module Studio
  # /admin/geo — the shared geo manager, plus /geo/check, the probe that reports
  # what the server thinks of THIS visitor.
  #
  # A plain host-inherited controller whose view is a bare content wrapper, like
  # /admin/emails and /admin/style, so it renders inside each host's application
  # layout and picks up that app's navbar and theme.
  #
  # Three things an operator can do here, and each exists because doing it any
  # other way means a deploy:
  #
  #   1. turn the gate on or off — the kill switch;
  #   2. edit the blocked list — countries, and subdivisions of the home country;
  #   3. SIMULATE a blocked location, so the blocked experience can be walked
  #      from a desk without a VPN.
  #
  # Routes are opt-in (Studio.draw_geo_routes) because turf-monster owns these
  # exact helper names until its adoption lands. See Studio.routes.
  class GeoSettingsController < ApplicationController
    # This page ASKS the questions the concern answers — where is this visitor,
    # are they blocked, are they simulating — so it includes the concern rather
    # than assuming the host's ApplicationController did. A host that already
    # includes it loses nothing: Rails' callback chain de-duplicates a repeated
    # `before_action :detect_geo_state`, so detection still runs once.
    include Studio::GeoDetection

    # The probe is PUBLIC — a page's own JavaScript asks it whether this visitor
    # is blocked, and that question has to be answerable before sign-in.
    skip_before_action :require_authentication, only: :check, raise: false
    before_action :require_admin, except: :check

    # GET /geo/check — force a fresh detection and report the verdict.
    #
    # Forcing is the point: an operator moving between networks needs an answer
    # about where they are NOW, not the one cached for the next day. A simulated
    # location is left alone, or the probe would silently cancel the simulation
    # it is supposed to describe.
    def check
      unless geo_override_active?
        reset_geo_detection!
        detect_geo_state
      end

      render json: {
        country: geo_country,
        subdivision: geo_state,
        region: geo_region_token,
        simulated: geo_override_active?,
        blocked: geo_blocked?,
        # The legacy key turf-monster's client already reads. Kept so an app can
        # adopt this endpoint without shipping a JavaScript change on the same day.
        state: geo_state
      }
    end

    def edit
      @geo_setting = Studio::GeoSetting.current
    end

    def update
      @geo_setting = Studio::GeoSetting.current

      @geo_setting.enabled = ActiveModel::Type::Boolean.new.cast(params.dig(:geo_setting, :enabled))
      @geo_setting.banned_subdivisions = submitted_subdivisions
      @geo_setting.banned_countries = submitted_countries
      @geo_setting.save!

      redirect_to admin_geo_path, notice: "Geo settings updated."
    rescue StandardError => e
      redirect_to admin_geo_path, alert: "Failed to update: #{e.message}"
    end

    # POST /admin/geo/toggle — stand in a blocked location, or stop.
    def toggle_override
      if geo_override_active?
        session.delete(:geo_override)
        return redirect_back fallback_location: admin_geo_path, notice: "Geo simulation cleared."
      end

      region = simulated_region
      # Nothing is blocked yet, so there is no blocked experience to walk. Say
      # that plainly instead of pinning the operator to a location that behaves
      # exactly like the one they are already in.
      if region.nil?
        return redirect_back fallback_location: admin_geo_path,
                             alert: "Nothing is blocked yet — add a country or a state first."
      end

      session[:geo_override] = region
      redirect_back fallback_location: admin_geo_path, notice: "Simulating #{region}."
    end

    private

    # The page posts this list three different ways: a checkbox grid posts bare
    # codes one per box ("WA"), a text field posts one comma-separated string
    # ("CA-AB, MX-BC"), and the grid's hidden anchor posts a blank so that
    # unchecking the LAST box still submits an empty list rather than nothing.
    # Split and flatten all three into plain entries here; the model decides what
    # each entry means.
    def submitted_subdivisions
      split_list(params.dig(:geo_setting, :banned_subdivisions))
    end

    def submitted_countries
      split_list(params.dig(:geo_setting, :banned_countries))
    end

    def split_list(raw)
      Array(raw).flat_map { |value| value.to_s.split(/[\s,]+/) }.reject(&:blank?)
    end

    # WHERE the simulator stands. The app's configured choice wins; otherwise the
    # first region this app actually blocks, which is the one worth walking. With
    # no policy at all there is nothing to simulate, so it falls back to the home
    # country's own first blocked subdivision — or, failing that, the home
    # country itself, which at least exercises the resolved-location path.
    def simulated_region
      configured = Studio.geo_simulated_region.presence
      return Studio::Geo.normalize_region_token(configured, home_country: Studio.geo_home_country) if configured

      subdivision = Studio::GeoSetting.effective_banned_subdivisions.first
      return subdivision if subdivision

      country = Studio::GeoSetting.effective_banned_countries.first
      # "CU-" is a country with no subdivision — the shape Studio::Geo reads back
      # as [country, nil], which is exactly what a country-wide block looks like
      # to the policy.
      country ? "#{country}-" : nil
    end
  end
end
