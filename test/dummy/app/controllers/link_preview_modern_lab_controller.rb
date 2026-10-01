# A host app that guards its pages with Rails' `allow_browser versions: :modern`
# — what `rails new` writes into every Rails 8 ApplicationController, and what
# mcritchie.studio and cyvasse.xyz both ship. Apple's LinkPresentation (the
# iMessage unfurler) sends a Safari 9.0.1 User-Agent, which :modern answers with
# a 406, so before studio-engine 0.82.x no link to such an app previewed.
#
# Nothing here exempts preview fetchers: including Studio::LinkPreviewBots must
# do it alone. The block stands in for Rails' default (which renders
# public/406-unsupported-browser.html, a file the dummy does not have); the
# exemption does not depend on which block blocks.
class LinkPreviewModernLabController < LinkPreviewLabController
  allow_browser versions: :modern, block: -> { render plain: "unsupported browser", status: :not_acceptable }

  def submit
    render plain: "submitted"
  end
end
