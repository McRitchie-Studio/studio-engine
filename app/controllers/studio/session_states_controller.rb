module Studio
  # GET /session/state — the rehydrate endpoint of the session-drift primitive
  # (docs/SESSION_DRIFT.md). Drawn only when the host sets
  # Studio.draw_session_routes; the browser store learns the URL from the page
  # stamp and never guesses it.
  #
  # It answers "what is this browser's session NOW?" with three things:
  #
  #   session — the same stamp a page render carries (Studio::SessionDrift), so
  #             the store compares like with like;
  #   context — the host's client_session_payload, so a host store hydrated from
  #             that payload refreshes from the same response;
  #   csrf    — a fresh authenticity token. Signing in or out resets the Rails
  #             session, which invalidates every token a stale page holds; the
  #             store swaps it into the csrf-token meta. That repairs requests
  #             that read the meta (Turbo, fetch with X-CSRF-Token). It does NOT
  #             rewrite the hidden authenticity_token input of a form already on
  #             the page, so a data-turbo="false" form rendered before the reset
  #             still posts the old token.
  #
  # ANONYMOUS IS AN ANSWER, NOT A FAILURE. The action skips the host's
  # require_authentication: a signed-out browser gets a 200 describing an
  # anonymous session. A host filter that REVOKES a session (verify_session_token
  # answers JSON with a 401) is still honoured, and the store reads that 401 as a
  # revocation.
  #
  # Read-only: no writes, and Cache-Control: no-store so no proxy or browser cache
  # ever answers for a different session.
  class SessionStatesController < ::ApplicationController
    skip_before_action :require_authentication, raise: false

    def show
      rescue_and_log(target: current_user) do
        response.headers["Cache-Control"] = "no-store"
        render json: {
          session: studio_session_stamp,
          context: respond_to?(:client_session_payload, true) ? client_session_payload : nil,
          csrf:    form_authenticity_token
        }
      end
    end
  end
end
