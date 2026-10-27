# frozen_string_literal: true

module Studio
  # The session's state, as a page is stamped with it (docs/SESSION_DRIFT.md).
  #
  # It answers one question: which session rendered this page, and is anyone
  # signed in? `state` is :anonymous or :authenticated, `fingerprint`
  # (Studio::SessionFingerprint) names the session without exposing it, and
  # `to_stamp` is the JSON every page carries so the browser store
  # (app/assets/javascripts/studio/session.js) can notice when the session
  # changes underneath a page.
  #
  # It reads the viewer and nothing else. What an identity IS stays outside: a
  # host that binds the session to something beyond the account passes it in as
  # `identities:`, keyed by the name of the browser identity source that observes
  # it, and this class only ever compares strings.
  #
  # Built per request by Studio::SessionDrift#studio_session_state, and exposed on
  # SessionContext through delegators. Pure Ruby, so it unit-tests without Rails.
  class SessionState
    # The session lifecycle, in the order a page can move through it:
    #   anonymous      — nobody is signed in. A first-class state, not an error:
    #                    a pre-auth page is a real page with a real session.
    #   authenticated  — somebody is signed in and the page still describes them.
    #   stale          — the page learned its stamp is out of date (another tab
    #                    changed the session, it expired, the server probe
    #                    disagreed) and a rehydrate is due.
    #   changed        — an identity source observes a different identity than the
    #                    one the session is bound to.
    #   rehydrated     — the page pulled the server's current session in place and
    #                    is signed in (possibly as someone new).
    #   signed_out     — the page was signed in and the server now reports nobody.
    STATES = %i[anonymous authenticated stale changed rehydrated signed_out].freeze

    # The only states a server render can report. The other four exist only in a
    # browser that is comparing an old page against a newer truth.
    SERVER_STATES = %i[anonymous authenticated].freeze

    # Bumped only when a stamp field changes meaning. Additive fields do not bump it.
    STAMP_VERSION = 1

    attr_reader :user

    def initialize(user)
      @user = user
    end

    def state
      user ? :authenticated : :anonymous
    end

    def anonymous?
      state == :anonymous
    end

    def authenticated?
      state == :authenticated
    end

    # The session's fingerprint. The stamp passes its own normalized identities,
    # so a page render and the rehydrate endpoint always agree for one session.
    def fingerprint(identities = {})
      Studio::SessionFingerprint.for(user, identities: identities)
    end

    # The JSON-ready stamp a page carries and the rehydrate endpoint returns.
    #
    #   rehydrate_url — where the browser store refetches this stamp; nil when the
    #                   host does not draw the route, which leaves the store able to
    #                   DETECT drift but not repair it in place.
    #   expires_at    — when this session lapses, if the host's session store says
    #                   so (a Time, or nil). The store's expiry source fires then.
    #   identities    — { source name => bound identity string } for host-declared
    #                   identity sources. Keys and values are stringified; a blank
    #                   value is dropped rather than sent as "" so an unbound source
    #                   stays unbound.
    #   issued_at     — when the server built this stamp. Tabs compare it to decide
    #                   whose truth is newer.
    #
    # Keys are camelCase because the browser reads them; times are epoch
    # milliseconds so no client has to parse a date string.
    def to_stamp(rehydrate_url: nil, expires_at: nil, identities: {}, issued_at: Time.now)
      bound = normalize_identities(identities)
      {
        v:            STAMP_VERSION,
        state:        state.to_s,
        fingerprint:  fingerprint(bound),
        issuedAt:     epoch_ms(issued_at),
        expiresAt:    expires_at && epoch_ms(expires_at),
        rehydrateUrl: rehydrate_url.to_s.empty? ? nil : rehydrate_url.to_s,
        identities:   bound
      }
    end

    private

    def epoch_ms(time)
      (time.to_r * 1000).to_i
    end

    def normalize_identities(identities)
      (identities || {}).each_with_object({}) do |(name, value), out|
        next if value.nil? || value.to_s.empty?

        out[name.to_s] = value.to_s
      end
    end
  end
end
