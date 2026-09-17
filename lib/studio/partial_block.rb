# frozen_string_literal: true

module Studio
  # The content of the block a CALLER passed to a partial, or nil when it passed
  # none. The engine's slot-taking partials ask this, never `block_given?`.
  #
  # WHY block_given? IS THE WRONG QUESTION IN A PARTIAL. ActionView compiles a
  # template into a method and ALWAYS invokes that method with a block:
  # PartialRenderer passes `{ |*name| view._layout_for(*name, &block) }` whether
  # or not the render that reached the partial carried one. So `block_given?` is
  # true in every partial. A `yield` with no caller block then falls through to
  # `_layout_for`'s other branch, the LAYOUT's content. While the page's own
  # template renders, that is empty. Once the layout renders, it is THE WHOLE
  # PAGE BODY.
  #
  # MEASURED 2026-09-16 (modal-header-yields-whole-page). turf-monster renders
  # the modal host from its layout. The username modal's plain "Saved" card
  # reached blocks/_card_header with a nil subtitle, and the header's
  # `elsif block_given?` yielded the entire page a second time inside a
  # <template>: two copies of the page body on /, /contests and /account for
  # every signed-in user allowed to rename. Nothing painted, nothing raised, and
  # every request returned 200.
  #
  # HOW THIS ANSWERS IT. Rails gives a template no way to ask whether its caller
  # passed a block, so the partial yields and hands the result in:
  #
  #   caller_block = Studio::PartialBlock.content(self, yield)
  #
  # A caller-less yield can only return the layout's content or nothing, so a
  # yield equal to `content_for(:layout)` is that fallback, not a block. A blank
  # yield also reads as no block: an empty slot wrapper is never what a caller
  # meant.
  #
  # THIS FIXES THE PREDICATE; THE BLOCK CONTRACT IS UNCHANGED. A caller that
  # passes a non-blank block renders exactly as before, so no consumer edits a
  # call site. A NEW slot should still prefer a named local that names a partial
  # (solana-studio's wallet picker does), which needs no predicate at all.
  module PartialBlock
    module_function

    # view    — the partial's view context (`self` inside the template).
    # yielded — the partial's own `yield`, evaluated where the partial calls this.
    def content(view, yielded)
      return nil if yielded.blank?
      return nil if yielded == view.content_for(:layout)

      yielded
    end
  end
end
