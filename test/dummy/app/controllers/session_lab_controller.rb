# A host app's ordinary pages for the session-drift suite
# (test/integration/session_drift_test.rb).
#
# It includes Studio::ErrorHandling the way every consuming app's
# ApplicationController does, which is what puts the session stamp helpers on its
# views. The page renders the engine's REAL stamp partial by name; sign-in and
# sign-out go through the concern's own set_app_session / clear_app_session, so
# the session the suite inspects is the one a host actually writes.
class SessionLabController < ActionController::Base
  include Studio::ErrorHandling

  skip_before_action :require_authentication

  def show
    render inline: %(<%= render "studio/session_stamp" %>)
  end

  def sign_in
    set_app_session(User.find(params[:user_id]))
    session[:lab_acct] = params[:acct] if params[:acct]
    render plain: "signed in"
  end

  def sign_out
    clear_app_session
    session.delete(:lab_acct)
    render plain: "signed out"
  end

  private

  # The host hook, exercised the way a host overrides it: a binding read from
  # the host's own session.
  def studio_session_identities
    { acct: session[:lab_acct] }
  end
end
