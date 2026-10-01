# A host app that already carries the APP-SIDE exemption written before the
# engine owned it (hub PR 1792, cyvasse PR 134). It must stay harmless now that
# Studio::LinkPreviewBots exempts preview fetchers itself.
class LinkPreviewPatchedLabController < LinkPreviewLabController
  allow_browser versions: :modern, unless: :link_preview_bot_request?,
                block: -> { render plain: "unsupported browser", status: :not_acceptable }
end
