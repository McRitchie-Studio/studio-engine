# A host app's two kinds of page, for the geo suite: one anybody may see, one
# LOCKED to allowed regions.
#
# This is the shape the engine documents — an app includes Studio::GeoDetection
# and hangs `require_geo_allowed` on the surfaces it must not serve from a
# blocked location — so the suite exercises the seam a real app writes rather
# than calling the concern's methods directly.
class GeoLabController < ActionController::Base
  include Studio::GeoDetection

  before_action :require_geo_allowed, only: :locked

  def open
    render plain: [geo_country, geo_state || "??", geo_blocked? ? "BLOCKED" : "ALLOWED"].join(" | ")
  end

  def locked
    render plain: "locked page"
  end
end

# The one thing a host app has that the engine's suites cannot fake: a signed-in
# session. Test-app only — it lives beside the lab pages, in an app that ships in
# no gem (spec.files has never included test/).
class GeoLabSessionsController < ActionController::Base
  def create
    session[Studio.session_key] = params[:user_id]
    render plain: "signed in"
  end
end
