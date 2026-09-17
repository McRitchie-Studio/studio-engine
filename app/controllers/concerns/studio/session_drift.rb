module Studio
  # The server half of the session-drift primitive (docs/SESSION_DRIFT.md).
  #
  # Every page carries a STAMP: the session's state, its fingerprint, when it was
  # issued and when it lapses, where to rehydrate it, and the identities the host
  # has bound it to. The browser store (app/assets/javascripts/studio/session.js)
  # reads the stamp, watches for drift, and rehydrates through
  # Studio::SessionStatesController when the host draws that route.
  #
  # Included BY Studio::ErrorHandling, so every consumer that includes that
  # concern has the stamp on every page with no wiring of its own. It adds
  # helper methods only; it registers no filter and changes no response.
  #
  # THE HOST'S TWO HOOKS
  #
  #   studio_session_identities — { source name => bound identity }. Baseline {}.
  #     A host that binds its session to an identity the engine knows nothing
  #     about (an external account, a device) overrides this, and a browser
  #     identity source registered under the same name observes it. The engine
  #     compares the two strings and never interprets them.
  #
  #   client_session_payload (Studio::ErrorHandling) — the host's own page payload.
  #     The rehydrate endpoint returns it as `context` beside the stamp, so a host
  #     store hydrated from it can be refreshed from the same response.
  module SessionDrift
    extend ActiveSupport::Concern

    included do
      helper_method :studio_session_state, :studio_session_stamp, :studio_session_page_stamp,
                    :studio_session_identities, :studio_session_rehydrate_url
    end

    private

    # The request's Studio::SessionState, built from the viewer alone: the state
    # and the fingerprint depend on nothing else.
    def studio_session_state
      @studio_session_state ||= Studio::SessionState.new(current_user)
    end

    # The stamp for this request. Raises like any other controller code; the
    # rehydrate endpoint relies on that so a failure reaches the error handler.
    def studio_session_stamp
      studio_session_state.to_stamp(
        rehydrate_url: studio_session_rehydrate_url,
        expires_at:    studio_session_expires_at,
        identities:    studio_session_identities
      )
    end

    # The stamp as the PAGE renders it. A page must never fail because its
    # session decoration did, so in production a failure is logged to ErrorLog
    # and the page renders without a stamp — the browser store then stays
    # dormant, which is exactly how every page behaved before this existed.
    # Development and test re-raise, mirroring handle_unexpected_error, so a
    # broken stamp fails a consumer's suite instead of hiding in it.
    def studio_session_page_stamp
      studio_session_stamp
    rescue StandardError => e
      raise if defined?(::Rails) && ::Rails.respond_to?(:env) && (::Rails.env.development? || ::Rails.env.test?)

      begin
        ErrorLog.capture!(e)
      rescue StandardError
        nil
      end
      nil
    end

    # Host hook — see the module comment. Baseline: no bound identities.
    def studio_session_identities
      {}
    end

    # Where the browser store rehydrates, or nil when the host has not drawn the
    # route (Studio.draw_session_routes). Without it the store still detects
    # drift; it just cannot repair the page in place.
    def studio_session_rehydrate_url
      return nil unless Studio.draw_session_routes
      return nil unless respond_to?(:studio_session_state_path, true)

      studio_session_state_path
    end

    # When this session lapses, if the session store says. Rails' cookie store
    # re-issues the cookie on every response, so a session with `expire_after`
    # lapses that long after THIS response — which is what the stamp records.
    # nil (the Rails default: a browser-session cookie) means no expiry source.
    def studio_session_expires_at
      return nil unless request.respond_to?(:session_options)

      expire_after = request.session_options[:expire_after]
      return nil unless expire_after.is_a?(Numeric) || expire_after.is_a?(ActiveSupport::Duration)
      return nil unless expire_after.to_i.positive?

      Time.now + expire_after.to_i
    end
  end
end
