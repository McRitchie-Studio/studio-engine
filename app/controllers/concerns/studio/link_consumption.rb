# frozen_string_literal: true

module Studio
  # The magic-link click, start to finish — shared by Studio::LinksController
  # and by any app that draws its own token route (turf-monster's contest
  # landing). Two entry points bracket the single-use burn:
  #
  #   preview_magic_link(link) — the GET. NEVER burns. Returns :live for a link
  #       that is still good (the caller renders the scanner-safe interstitial),
  #       and otherwise settles the click here and returns :handled.
  #   consume_magic_link(link) — the POST. The one and only place a token burns.
  #
  # Both route their answer through Studio::LinkResolution, the pure decision
  # table, so "what should this click do" has exactly one owner and the GET and
  # the POST can never disagree about it. The invariant that table enforces:
  # **a dead link never touches the session.**
  #
  # Apps customize by overriding the hooks at the bottom, not by re-deciding:
  # sign_in_existing / sign_up_new (the authenticate path), link_continue (the
  # viewer's own live link), link_dead (no session mutation, ever), plus
  # link_login_path / link_home_path for apps whose sign-in page is not
  # `login_path`.
  #
  # `link` is anything responding to #email, #return_to, #live?, #burn and
  # #dead_status — in practice a Studio::Link, or nil for an unknown token.
  #
  # Relies on the host ApplicationController contract from Studio::ErrorHandling:
  # set_app_session, rescue_and_log, current_user, plus root_path / login_path.
  module LinkConsumption
    extend ActiveSupport::Concern

    private

    # --- entry points ---------------------------------------------------------

    # GET. Inert by construction: email scanners, link-preview fetchers and the
    # Gmail image proxy all issue a GET against an emailed URL, so burning here
    # would spend the token before the human ever clicked. A dead link is
    # settled immediately rather than sent through a spinner that only POSTs to
    # learn the same thing.
    def preview_magic_link(link)
      return :live if link&.live?

      link_dead(resolve_link_click(link, status: dead_status_for(link)), link)
      :handled
    end

    # POST. Burns first — the burn is atomic, so winning it IS the proof the
    # link was live — then acts on what the burn returned.
    def consume_magic_link(link)
      claimed = link.present? && link.burn
      outcome = resolve_link_click(link, status: claimed ? :claimed : dead_status_for(link))

      case outcome.action
      when :authenticate
        user = User.find_by(email: link.email)
        user ? sign_in_existing(user, link) : sign_up_new(link)
      when :continue
        link_continue(link, outcome)
      else
        link_dead(outcome, link)
      end
    end

    def resolve_link_click(link, status:)
      Studio::LinkResolution.call(
        status:        status,
        link_email:    link&.email,
        session_email: current_user&.email
      )
    end

    def dead_status_for(link)
      link.nil? ? :unknown : link.dead_status
    end

    # --- outcomes -------------------------------------------------------------

    def sign_in_existing(user, result)
      set_app_session(user)
      # Clicking the link proves email ownership, so verify any account that
      # reached here without it (e.g. a Google/wallet-only signup).
      verify_email_ownership(user)
      redirect_to(link_destination(:return_to, result), notice: "Signed in. Welcome back!")
    end

    # Build → configure_new_user → save!. No password — email auth is link-only.
    def sign_up_new(result)
      user = User.new(email: result.email)
      Studio.configure_new_user.call(user)
      rescue_and_log(target: user) do
        user.save!
        verify_email_ownership(user)
        set_app_session(user)
        redirect_to(link_destination(:return_to, result), notice: Studio.welcome_message.call(user))
      end
    rescue ActiveRecord::RecordNotUnique
      # Two valid tokens for the same brand-new email consumed near-simultaneously
      # both miss find_by and race to save!; the loser hits the unique index.
      # Benign — the account now exists, so just log the winner in.
      existing = User.find_by(email: result.email)
      return sign_in_existing(existing, result) if existing

      redirect_to link_login_path, alert: "We couldn't finish creating your account. Please try again."
    rescue StandardError => e
      Rails.logger.error("[Studio::LinkConsumption#sign_up_new] signup failed #{e.class}: #{e.message}")
      redirect_to link_login_path, alert: "We couldn't finish creating your account. Please try again."
    end

    # The viewer's own still-live link. The token burns (nobody replays it
    # later) but the session is left exactly as it stands — re-authenticating
    # would buy nothing and would cost a host that rotates the session on
    # sign-in every scrap of state the visitor had built up. From the visitor's
    # side this is indistinguishable from following a plain link, which is the
    # entire point.
    def link_continue(result, _outcome)
      verify_email_ownership(current_user)
      redirect_to link_destination(:return_to, result)
    end

    # A used, expired, or unrecognized link. Touching the session here is the
    # bug this whole concern was written to remove: the visitor's session has
    # nothing to do with the state of a token someone mailed them.
    def link_dead(outcome, result)
      path = link_destination(outcome.destination, result)
      return redirect_to(path) if outcome.silent?

      redirect_to path, outcome.level => outcome.message
    end

    # --- hooks + helpers ------------------------------------------------------

    def link_destination(destination, result)
      case destination
      when :login then link_login_path
      when :home  then link_home_path
      else             safe_path(result&.return_to) || link_home_path
      end
    end

    # Where a visitor with NO session lands when the link is dead. Apps whose
    # sign-in page is not `login_path` (turf-monster: signin_path) override this.
    def link_login_path
      login_path
    end

    # Where a click lands when the link's own destination is not ours to follow.
    def link_home_path
      root_path
    end

    def verify_email_ownership(user)
      return unless user.respond_to?(:email_verified_at) && user.email_verified_at.blank?

      user.update!(email_verified_at: Time.current)
    end

    # Only same-origin absolute paths survive; everything else collapses to nil.
    def safe_path(path)
      p = path.to_s
      p.start_with?("/") && !p.start_with?("//") ? p : nil
    end
  end
end
