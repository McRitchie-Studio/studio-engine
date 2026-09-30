# A host app's pages, for the link-preview suite: one that says nothing about
# its preview, one that overrides it through the engine's ONE override API
# (`link_preview`), and one heavy enough that Apple's LinkPresentation would
# refuse it (over 1 MiB).
#
# The shape the engine documents: the host includes Studio::LinkPreviewBots and
# its layout renders the engine's real head partial, so the suite drives the
# seam a real app has rather than calling the helper directly.
class LinkPreviewLabController < ActionController::Base
  include Studio::LinkPreviewBots

  # The head's asset tags are the HOST's job; borrow the lab's honest stand-ins
  # (E2eLabController::AssetDelivery) rather than writing a second set.
  helper E2eLabController::AssetDelivery

  layout "link_preview_lab"

  def plain; end

  def override; end

  def heavy; end
end
