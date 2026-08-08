module Studio
  # The short-token link entry point — GET/POST /l/<token>, the only magic-link
  # door the engine draws. Dispatches by Studio::Link#kind:
  #
  #   magic_link → scanner-safe confirm interstitial (GET, inert) that auto-POSTs
  #                to #consume, the ONLY place the single-use token is burned +
  #                the recipient is signed in / signed up.
  #   referral   → idempotent: capture attribution into a cookie + redirect to
  #                the link's target (or root). Reusable + safe to prefetch, so
  #                GET does the work (no POST step).
  #
  # Every decision about what a magic-link click DOES lives in
  # Studio::LinkConsumption / Studio::LinkResolution, not here — including the
  # invariant that a dead link leaves the visitor's session untouched.
  #
  # Namespaced (not top-level Links) because mcritchie-studio already owns a
  # public /links linktree (top-level LinksController). Apps needing richer
  # post-consume routing (contest landing, picks rehydration, age-gate) define
  # their own Studio::LinksController and reuse Studio::Link + the
  # Studio::LinkConsumption building blocks.
  class LinksController < ApplicationController
    include Studio::LinkConsumption

    skip_before_action :require_authentication
    layout false, only: :show

    # GET /l/:token
    def show
      response.set_header("Referrer-Policy", "strict-origin")
      @link = Studio::Link.find_by(token: params[:token])

      if @link&.kind == "referral"
        capture_referral(@link)
        return redirect_to(@link.target || root_path)
      end

      # A magic link, or a token with no row behind it. preview_magic_link is
      # inert — it never burns — and settles a dead link itself rather than
      # sending the visitor through a spinner that only POSTs to learn the same.
      @token = params[:token]
      render :confirm if preview_magic_link(@link&.kind == "magic_link" ? @link : nil) == :live
    end

    # POST /l/:token — authoritative magic-link consume. Only magic_link kinds are
    # consumable here; referral links are reusable and handled entirely on GET,
    # so a referral token scoped out below reads as an unknown token.
    def consume
      response.set_header("Referrer-Policy", "strict-origin")
      consume_magic_link(Studio::Link.magic_links.find_by(token: params[:token]))
    end

    private

    # Attribution rides in a cookie the app reads at signup (same :reference
    # cookie the legacy ?ref= capture used). Value = the inviter's stable handle
    # (slug) when available, else the link token. Capped to 64 chars.
    def capture_referral(link)
      inviter = link.linkable
      ref = (inviter.respond_to?(:slug) && inviter.slug.presence) || link.token
      cookies[:reference] = { value: ref.to_s.first(64), expires: 30.days, same_site: :lax }
    end
  end
end
