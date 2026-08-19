# frozen_string_literal: true

module Studio
  # Where the visitor appears to be, resolved once per session and available to
  # every controller and view that includes this concern.
  #
  #   include Studio::GeoDetection
  #
  # That one line gives an app: IP -> region detection with a session cache and a
  # self-healing retry window, the `geo_state` / `geo_country` / `geo_blocked?`
  # helpers the shared badge renders from, an admin simulation override, and
  # `require_geo_allowed` — a before_action an app can hang on whichever surfaces
  # it wants LOCKED.
  #
  # LOCKING IS DELIBERATELY LOOSE. The engine ships the gate and the policy; each
  # app decides what it protects, because "which actions are geo-restricted" is a
  # product and legal question, not a framework one:
  #
  #   before_action :require_geo_allowed, only: %i[create withdraw]
  #
  # Detection itself is registered here as a before_action, because a badge that
  # renders on every page needs a location on every page. A controller that must
  # not pay for it (webhooks, health checks) skips it the ordinary way:
  #
  #   skip_before_action :detect_geo_state
  #
  # SESSION KEYS are the plain names an app already has in production
  # (:geo_state, :geo_country, :geo_ip, :geo_detected_at, :geo_override) so an
  # app adopting this concern keeps every live visitor's resolved location
  # instead of re-geocoding the whole internet on deploy day.
  module GeoDetection
    extend ActiveSupport::Concern

    included do
      before_action :detect_geo_state

      if respond_to?(:helper_method)
        helper_method :geo_state, :geo_subdivision, :geo_country, :geo_region_token,
                      :geo_blocked?, :geo_override_active?
      end
    end

    # Resolve the visitor's region, at most once per freshness window.
    #
    # Failure is SWALLOWED by design: a geocoding provider being down must not
    # 500 the page. It is logged, and the attempt is stamped so a provider that
    # is timing out on every request is retried on the retry window rather than
    # on every single request.
    def detect_geo_state
      return if session[:geo_override].present?

      ip_changed = session[:geo_ip] != request.remote_ip
      stale = Studio::Geo.stale?(
        detected_at: session[:geo_detected_at],
        resolved: session[:geo_state].present?,
        ttl: Studio.geo_ttl,
        retry_ttl: Studio.geo_retry_ttl
      )
      return unless ip_changed || stale

      result = geo_lookup(request.remote_ip)

      # state_code / region_code / region, in that order: providers disagree about
      # which field carries a subdivision, and outside the US the only answer is
      # often the region NAME ("Alberta"). Taking the first present one keeps a
      # foreign visitor placed rather than blank.
      raw = result&.try(:state_code).presence || result&.try(:region_code).presence || result&.try(:region)
      session[:geo_state] = Studio::Geo.normalize_subdivision(raw)
      session[:geo_country] = Studio::Geo.normalize_country(result&.try(:country_code))

      apply_development_region if session[:geo_state].blank?

      session[:geo_ip] = request.remote_ip
      session[:geo_detected_at] = Time.current.to_s
    rescue StandardError => e
      Rails.logger.warn "Geo detection failed: #{e.message}"
      session[:geo_detected_at] = Time.current.to_s
    end

    # Force a fresh lookup on the next detect — what the /geo/check endpoint uses
    # so an operator can re-test their own location without waiting out the TTL.
    def reset_geo_detection!
      session.delete(:geo_detected_at)
      session.delete(:geo_ip)
      session.delete(:geo_state)
      session.delete(:geo_country)
    end

    # The visitor's subdivision code — "WA", or a region name where that is all
    # the provider knows. `geo_state` is the name every existing app calls this;
    # `geo_subdivision` is the same value under the vocabulary the engine uses
    # everywhere else.
    def geo_state
      if session[:geo_override].present?
        _country, subdivision = Studio::Geo.parse_region(session[:geo_override], home_country: Studio.geo_home_country)
        return subdivision
      end

      Studio::Geo.normalize_subdivision(session[:geo_state])
    end
    alias_method :geo_subdivision, :geo_state

    # ISO country code from the same lookup.
    #
    # Defaults to the app's HOME country when undetected, and that default is
    # load-bearing rather than cosmetic: it is what makes an unplaceable visitor
    # fall into the fail-closed branch of the policy instead of sliding through as
    # "somewhere else, therefore fine".
    def geo_country
      if session[:geo_override].present?
        country, _subdivision = Studio::Geo.parse_region(session[:geo_override], home_country: Studio.geo_home_country)
        return country || Studio.geo_home_country
      end

      Studio::Geo.normalize_country(session[:geo_country]) || Studio.geo_home_country
    end

    # "US-WA" — the two halves as one token, for logging and for the admin page.
    def geo_region_token
      Studio::Geo.region_token(geo_country, geo_state)
    end

    # The gate's verdict for this visitor. Delegates the whole policy to
    # Studio::GeoSetting, so an app never re-derives the fail-closed rule — the
    # subtle part — from its own controller.
    def geo_blocked?
      Studio::GeoSetting.blocked?(country: geo_country, subdivision: geo_state)
    end

    def geo_override_active?
      session[:geo_override].present?
    end

    # THE LOCK. Hang it on whatever an app must not serve from a blocked region:
    #
    #   before_action :require_geo_allowed, only: %i[create withdraw]
    #
    # HTML redirects with an explanation, JSON answers 403 with the same words —
    # the copy comes from Studio.geo_blocked_message so each app speaks in its own
    # voice about its own rules.
    def require_geo_allowed
      return unless geo_blocked?

      message = Studio.geo_blocked_message.call(geo_state, geo_country)
      respond_to do |format|
        format.html { redirect_to geo_blocked_redirect_path, alert: message }
        format.json { render json: { error: message }, status: :forbidden }
      end
    end

    private

    def geo_lookup(ip)
      return nil unless defined?(::Geocoder)

      ::Geocoder.search(ip).first
    end

    # Loopback IPs never geocode, so a development session has no region at all
    # and every geo-gated feature fails closed on the developer's own machine.
    # An app sets Studio.geo_development_region ("US-CO") to stand somewhere real
    # while it works. Development only — a test or production environment that
    # cannot place a visitor must SAY so, because that is the case the fail-closed
    # rule exists for.
    def apply_development_region
      return unless Rails.env.development?
      return unless request.local?

      region = Studio.geo_development_region.presence
      return if region.nil?

      country, subdivision = Studio::Geo.parse_region(region, home_country: Studio.geo_home_country)
      session[:geo_state] = subdivision
      session[:geo_country] = country
    end

    def geo_blocked_redirect_path
      target = Studio.geo_blocked_redirect
      target = instance_exec(&target) if target.respond_to?(:call)
      target.presence || main_app_root_path
    end

    # `main_app` is not defined in a non-isolated engine's controllers, and an app
    # can rename its root helper. Resolve defensively so a blocked visitor lands
    # somewhere real rather than on a NoMethodError.
    def main_app_root_path
      return root_path if respond_to?(:root_path)

      "/"
    end
  end
end
