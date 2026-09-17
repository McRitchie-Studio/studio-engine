# Canonical, single source of truth for the current viewer's session.
#
# It answers two questions, and the halves are deliberately kept apart.
#
# 1. THE SESSION STATE (generic, web2). Which session rendered this page, and is
#    anyone signed in? `state` is :anonymous or :authenticated. `fingerprint`
#    (Studio::SessionFingerprint) names the session without exposing it, and
#    `to_stamp` is the JSON every page carries, so the browser session store
#    (app/assets/javascripts/studio/session.js) can notice when the session
#    changes underneath a page: another tab signed in or out, the session
#    expired, or the server revoked it. STATES lists the whole lifecycle; the
#    server only ever reports the first two, and the client derives the rest.
#    See docs/SESSION_DRIFT.md.
#
#    Nothing in this half knows what an identity IS. A host that binds the
#    session to some other identity (an external account, a device) declares it
#    through `identities:` on the stamp, keyed by the name of the browser
#    identity source that observes it. The engine only compares strings.
#
# 2. THE LEGACY MODE (kept for existing consumers). `mode` is the 3-way value
#    turf-monster's UI branches on:
#      :guest — not logged in
#      :web2  — logged in with a custodial/managed wallet this session (email or
#               Google login, or a Phantom account that did NOT authenticate via
#               a wallet signature this session)
#      :web3  — logged in AND authenticated via a live Phantom wallet signature
#               this session (onchain_session?) — i.e. can sign on-chain txs now
#
#    Mode is decided by the SESSION, not by account identity: a Phantom owner who
#    logs in by email is :web2 for that session. `phantom_linked?` exposes the
#    account-level fact separately, so the UI can still offer "Connect Phantom".
#    `to_h` is that payload, mirrored client-side by the HOST's
#    Alpine.store('session'). Its shape is frozen: consumers hydrate from it.
#    New session vocabulary goes in half 1, never here.
#
# Built per request by Studio::ErrorHandling#wallet_context (the legacy mode
# payload) and by Studio::SessionDrift#studio_session_context (the stamp).
#
# Lifted into studio-engine (was turf-monster app/models). Wallet predicates are
# called through `respond_to?` so an app with wallet sign-in disabled (no
# #phantom_wallet? / #solana_address on User) still gets correct :guest/:web2.
class SessionContext
  MODES = %i[guest web2 web3].freeze

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

  # `onchain_session:` defaults to false so a host with no second sign-in factor
  # can build one without naming it. Existing callers that pass it are unchanged.
  def initialize(user:, onchain_session: false)
    @user = user
    @onchain_session = onchain_session
  end

  # ---- Half 1: session state ------------------------------------------------

  def state
    user ? :authenticated : :anonymous
  end

  def anonymous?
    state == :anonymous
  end

  def authenticated?
    state == :authenticated
  end

  # The session's fingerprint (Studio::SessionFingerprint). The stamp passes its
  # own normalized `identities`, so a page render and the rehydrate endpoint
  # always agree for the same session.
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

  # ---- Half 2: legacy mode --------------------------------------------------

  # The canonical 3-way. Session-based — see class comment.
  def mode
    return :guest unless user
    @onchain_session ? :web3 : :web2
  end

  def guest?
    mode == :guest
  end

  def web2?
    mode == :web2
  end

  def web3?
    mode == :web3
  end

  def logged_in?
    !guest?
  end

  # Account-level fact, independent of `mode`: the account holds a self-custody
  # (Phantom) wallet. A :web2-mode session can still be phantom_linked — that is
  # exactly the "Phantom owner logged in by email" case.
  def phantom_linked?
    (user.respond_to?(:phantom_wallet?) && user.phantom_wallet?) || false
  end

  def user_id
    user&.id
  end

  # Primary wallet address (web3 preferred), or nil when logged out / wallet-less.
  def address
    return Studio.user_wallet_address(user) if defined?(Studio) && Studio.respond_to?(:user_wallet_address)

    return nil unless user.respond_to?(:solana_address)
    user.solana_address
  end

  # Shape consumed by the host's Alpine.store('session'). Kept deliberately
  # cheap — DB/session columns only, never an on-chain RPC call. FROZEN: the
  # session-state half travels in #to_stamp instead.
  def to_h
    {
      loggedIn:      logged_in?,
      mode:          mode,
      phantomLinked: phantom_linked?,
      userId:        user_id,
      address:       address.to_s
    }
  end

  def as_json(*)
    to_h
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
