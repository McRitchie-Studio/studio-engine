# Landing pages for the integration suites — the "somewhere to be sent" that
# Studio.routes deliberately does not draw (every consuming app owns its own
# root). Deliberately NOT a Studio::ErrorHandling controller: these stand in for
# ordinary public pages a magic link redirects onto.
#
# It renders the flash into the body so a test can assert what the visitor
# actually SEES on landing, rather than poking at session internals. That also
# makes this the request that SWEEPS the flash: ActionDispatch::Flash only
# rewrites the session when something reads the flash during the request, so a
# bare Rack endpoint would carry a stale notice forward forever and every
# "the click said nothing" assertion would be reading the previous page's words.
class PagesController < ActionController::Base
  def show
    render plain: [params[:page], flash[:notice], flash[:alert]].compact.join(" | ")
  end
end
