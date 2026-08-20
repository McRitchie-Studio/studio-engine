# The one thing a host app has that the engine's suites cannot fake: a signed-in
# session. Test-app only — it lives beside the lab pages, in an app that ships in
# no gem (spec.files has never included test/).
class GeoLabSessionsController < ActionController::Base
  def create
    session[Studio.session_key] = params[:user_id]
    render plain: "signed in"
  end
end
