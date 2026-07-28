module Studio
  module ErrorHandling
    extend ActiveSupport::Concern

    included do
      # ORDER IS LOAD-BEARING — ActiveSupport::Rescuable resolves handlers with
      # `reverse_each`, so the LAST matching rescue_from registered wins. The
      # catch-all must therefore be declared FIRST and the specific handlers
      # after it, or StandardError shadows every one of them: RecordNotFound
      # rendered "Something went wrong" and wrote an ErrorLog row on every 404,
      # fleet-wide, while handle_not_found sat unreachable. Add new specific
      # handlers BELOW this line, never above it.
      rescue_from StandardError, with: :handle_unexpected_error
      rescue_from ActiveRecord::RecordNotFound, with: :handle_not_found

      before_action :require_authentication

      helper_method :current_user, :logged_in?, :sso_user_available?, :sso_display_name, :sso_source_app, :sso_hub_logo, :admin?,
                    :onchain_session?, :wallet_context, :client_session_payload
    end

    private

    def current_user
      return @current_user if defined?(@current_user)
      @current_user = User.find_by(id: session[Studio.session_key])
    end

    def set_app_session(user)
      # App-specific session (only this app reads this key)
      session[Studio.session_key] = user.id

      # OPSEC-045: bind a rotating per-user token into the cookie. The
      # verify_session_token filter compares it to user.session_token on every
      # request, so a server-side rotation (email change, "log out everywhere")
      # invalidates stolen sessions. Guarded for consumers whose User has no
      # session_token column. Backfills a blank token (legacy rows / fixtures
      # predate the column) so they aren't force-logged-out on the next request.
      if user.respond_to?(:session_token)
        if user.session_token.blank? && user.respond_to?(:update_column)
          user.update_column(:session_token, SecureRandom.hex(32))
        end
        session[:session_token] = user.session_token
      end

      # The on-chain-session flag is a Phantom-wallet-signature privilege.
      # Reset it on every login so a stale flag from an earlier wallet session
      # can't leak into a later email/Google login. SolanaSessionsController#verify
      # re-grants it for genuine wallet auth.
      session.delete(:onchain)

      # Only update shared awareness fields if this app is the source
      # (don't overwrite the other app's sso_source when logging in via sso_continue)
      if session[:sso_source].blank? || session[:sso_source] == Studio.app_name
        session[:sso_email]    = user.email
        session[:sso_name]     = user.try(:name)
        session[:sso_provider] = user.provider
        session[:sso_uid]      = user.uid
        session[:sso_wallet]   = Studio.user_wallet_address(user)
        session[:sso_source]   = Studio.app_name
        session[:sso_logo]     = Studio.sso_logo
      end
    end

    def clear_app_session
      session.delete(Studio.session_key)
      session.delete(:session_token)
      session.delete(:onchain)

      # Clear sso_* fields only if this app is the source
      # (preserve them if the other app set them — they're still logged in there)
      if session[:sso_source] == Studio.app_name
        session.delete(:sso_email)
        session.delete(:sso_name)
        session.delete(:sso_provider)
        session.delete(:sso_uid)
        session.delete(:sso_wallet)
        session.delete(:sso_source)
        session.delete(:sso_logo)
      end
    end

    # Cross-app awareness helpers for login page
    def sso_user_available?
      !logged_in? && session[:sso_email].present? && session[:sso_source] != Studio.app_name
    end

    def sso_display_name
      session[:sso_name].presence || session[:sso_email]&.split("@")&.first&.capitalize || "User"
    end

    def sso_source_app
      session[:sso_source]
    end

    def sso_hub_logo
      session[:sso_logo]
    end

    def logged_in?
      current_user.present?
    end

    # Format-aware: a full-page HTML request gets the login redirect, but an
    # AJAX/Turbo request gets a clean 401 (a blind redirect to the HTML login
    # page makes Rails return 406 Not Acceptable for an `Accept: application/json`
    # request — OPSEC-046). The JS fetch layer turns the 401 into a login modal.
    def require_authentication
      return if logged_in?

      respond_to do |format|
        format.html         { redirect_to login_path }
        format.json         { render json: { error: "unauthenticated" }, status: :unauthorized }
        format.turbo_stream { head :unauthorized }
        format.any          { head :unauthorized }
      end
    end

    # Populates Current.* for the request lifecycle so audit/logging layers can
    # attribute work to the viewer without param threading. Best-effort —
    # never breaks the request path. Apps wire this as a before_action.
    def set_current_context
      Current.user = current_user if logged_in?
    rescue StandardError
      nil
    end

    # OPSEC-045: enforce session-token binding. No-ops for consumers whose User
    # has no session_token. Runs early (apps wire it as a before_action ahead of
    # require_authentication) so a stale session is cleared before current_user
    # is read downstream.
    def verify_session_token
      return unless logged_in?
      return unless current_user.respond_to?(:session_token)

      user_token   = current_user.session_token
      cookie_token = session[:session_token]
      return if user_token.present? && user_token == cookie_token

      Rails.logger.info("[opsec-045] session_token mismatch user_id=#{current_user.id} — forcing re-login")
      @current_user = nil
      clear_app_session
      respond_to do |format|
        format.html { redirect_to login_path, alert: "Your session expired. Please sign in again." }
        format.json { render json: { error: "session expired" }, status: :unauthorized }
        format.any  { head :unauthorized }
      end
    end

    # True when this session authenticated via a live Solana wallet signature
    # (not email/Google). Set by SolanaSessionsController#verify.
    def onchain_session?
      session[:onchain] == true
    end

    # Canonical auth + wallet state for this request — the single source of truth
    # the whole UI branches on (web3 / web2 / guest). Serialised into the page and
    # mirrored client-side by Alpine.store('session'). See SessionContext.
    def wallet_context
      @wallet_context ||= SessionContext.new(user: current_user, onchain_session: onchain_session?)
    end

    # Payload serialised into #session-context for Alpine.store('session').
    # Baseline = identity only (SessionContext stays RPC-free). Apps override to
    # merge on-chain balances/tokens they already preloaded for the request.
    def client_session_payload
      wallet_context.to_h
    end

    def require_admin
      return redirect_to root_path, alert: "Not authorized" unless logged_in? && current_user.admin?
    end

    def admin?
      logged_in? && current_user.admin?
    end

    # Central error logging method — all controller error logging flows through here.
    # Returns the ErrorLog record so callers can attach target/parent context.
    def create_error_log(exception)
      ErrorLog.capture!(exception)
    end

    # Layer 2: Opt-in per-action wrapper with target/parent context.
    # Sets @_error_logged flag so Layer 1 won't double-log.
    def rescue_and_log(target: nil, parent: nil)
      yield
    rescue ActiveRecord::RecordNotFound => e
      raise e
    rescue StandardError => e
      error_log = create_error_log(e)
      if target
        error_log.target = target
        error_log.target_name = target.slug
      end
      if parent
        error_log.parent = parent
        error_log.parent_name = parent.slug
      end
      error_log.save!
      @_error_logged = true
      raise e
    end

    # Layer 1: RecordNotFound — Rails' own 404, never an ErrorLog row.
    #
    # This handler exists for exactly ONE reason: to stop `handle_unexpected_error`
    # from claiming a RecordNotFound and writing an ErrorLog row for it. It
    # deliberately renders NOTHING and re-raises, which hands the exception to
    # `ActionDispatch::PublicExceptions` — the same path an app with no rescue_from
    # at all takes. Registering the handler and re-raising is therefore not a
    # no-op: matching here is what keeps the catch-all's `create_error_log` from
    # running (a raise inside a rescue_from handler propagates out; Rescuable does
    # not re-dispatch it into another handler).
    #
    # Why nothing is rendered here. The method was unreachable from the initial
    # commit until the rescue_from order was fixed (see the note in `included`),
    # so whatever it did had never actually run — consumers have been served
    # Rails' standard 404 all along. Anything rendered here would therefore be a
    # NEW fleet-wide behaviour, not a restoration: an earlier attempt at this fix
    # rendered public/404.html and silently flipped `Accept: */*` clients (curl,
    # uptime monitors, crawlers, link previewers) from `404 text/html` to
    # `404 application/json`, changed the JSON body shape, and dropped the
    # DebugExceptions backtrace in development. Re-raising keeps every one of
    # those intact, along with `public/404.<locale>.html` and any
    # `config.exceptions_app` a host configures.
    #
    # The bug being fixed is the ErrorLog pollution and the "Something went wrong"
    # copy — never the status code, the format, or the body.
    def handle_not_found(exception)
      raise exception
    end

    # Layer 1: Catch-all for unexpected errors — log + friendly response.
    # Skips logging if rescue_and_log already captured it.
    def handle_unexpected_error(exception)
      create_error_log(exception) unless @_error_logged
      raise exception if Rails.env.development? || Rails.env.test?

      respond_to do |format|
        format.html { redirect_to root_path, alert: "Something went wrong." }
        format.json { render json: { error: "Internal server error" }, status: :internal_server_error }
      end
    end
  end
end
