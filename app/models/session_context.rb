# Canonical, single source of truth for the current viewer's auth + wallet state.
#
# `mode` is the 3-way value the entire UI branches on:
#   :guest — not logged in
#   :web2  — logged in with a custodial/managed wallet this session (email or
#            Google login, or a Phantom account that did NOT authenticate via a
#            wallet signature this session)
#   :web3  — logged in AND authenticated via a live Phantom wallet signature
#            this session (onchain_session?) — i.e. can sign on-chain txs now
#
# Mode is decided by the SESSION, not by account identity: a Phantom owner who
# logs in by email is :web2 for that session. `phantom_linked?` exposes the
# account-level fact separately, so the UI can still offer "Connect Phantom".
#
# Built once per request by ApplicationController#wallet_context, serialised
# into the page, and mirrored client-side by Alpine.store('session').
#
# Lifted into studio-engine (was turf-monster app/models). Wallet predicates are
# called through `respond_to?` so an app with wallet sign-in disabled (no
# #phantom_wallet? / #solana_address on User) still gets correct :guest/:web2.
class SessionContext
  MODES = %i[guest web2 web3].freeze

  attr_reader :user

  # ---- Session state (docs/SESSION_DRIFT.md) --------------------------------
  # The generic session-state primitive, delegated to Studio::SessionState, which
  # reads the viewer and nothing else. This block only exposes it here; the
  # legacy payload below (#to_h) is unchanged and carries none of it.
  STATES        = Studio::SessionState::STATES
  SERVER_STATES = Studio::SessionState::SERVER_STATES

  def session_state
    @session_state ||= Studio::SessionState.new(user)
  end

  def state
    session_state.state
  end

  def anonymous?
    session_state.anonymous?
  end

  def authenticated?
    session_state.authenticated?
  end

  def fingerprint(identities = {})
    session_state.fingerprint(identities)
  end

  def to_stamp(**options)
    session_state.to_stamp(**options)
  end
  # ---- end session state ----------------------------------------------------

  def initialize(user:, onchain_session:)
    @user = user
    @onchain_session = onchain_session
  end

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

  # Shape consumed by the client Alpine.store('session'). Kept deliberately
  # cheap — DB/session columns only, never an on-chain RPC call.
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
end
