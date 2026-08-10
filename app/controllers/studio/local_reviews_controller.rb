# frozen_string_literal: true

module Studio
  # GET /_studio/local_review?email=<who>&return_to=<path> — the LOCAL half of
  # the task board's WAITING APPROVAL button.
  #
  # Why it must live here, on the local app. A magic link signs the recipient
  # into the app that MINTED it: the token is a row (or a signed blob) in that
  # app's own store, and Studio::LinkToken.sanitize_path keeps `return_to` a
  # same-origin PATH. So a link minted by the production board can only ever
  # land on production — no matter what host the path belongs to. The board
  # therefore stops minting and REDIRECTS here, to the local server named by the
  # task's local_url, which mints in its own database and lands the operator
  # signed-in on the page under review.
  #
  # It mints for whatever email it is handed, unauthenticated — so it is bound
  # to the same floor as the local email inbox (Studio::LocalEmailsController):
  # never in production, and only for a loopback request. That is the same
  # exposure the inbox already carries, which hands every captured sign-in link
  # to any local reader. It is a development desk convenience; it is not a
  # sign-in path.
  #
  # It also PROVISIONS the account before minting, at Studio.local_review_role
  # (default "admin"). The email the board hands over is the operator's
  # PRODUCTION address, and a fresh worktree database has never seen it — so
  # without this the consume takes Studio::LinkConsumption#sign_up_new, creates
  # him at the default role ("viewer"), and `require_admin` on the page under
  # review redirects him to "/". The sign-in SUCCEEDS and he never sees the
  # page, which is what made the failure so quiet: a seeded admin works, so only
  # the operator's real address ever hit it.
  class LocalReviewsController < ApplicationController
    include Studio::MagicLinkIssuing

    skip_before_action :require_authentication, raise: false

    before_action :require_local_development!

    def show
      email = Studio::LinkToken.normalize_email(params[:email])
      return redirect_to(login_path, alert: MISSING_EMAIL) unless email.match?(URI::MailTo::EMAIL_REGEXP)

      # Provision BEFORE minting, so the consume finds an existing account and
      # takes sign_in_existing rather than sign_up_new-at-the-default-role.
      provision_reviewer(email)

      # return_to is passed through raw: the store sanitizes it to a same-origin
      # path on the way in (Studio::Link.create_magic_link calls
      # Studio::LinkToken.sanitize_path). Re-sanitizing here would be a second
      # spelling of a rule that already has one owner — and a mutation run
      # confirmed it guards nothing the store does not already guard.
      token = issue_magic_link(email, params[:return_to])
      redirect_to magic_link_url_for(token), allow_other_host: false
    end

    private

    MISSING_EMAIL = "Add ?email=<your address> to mint a local review link."

    # Find-or-create the reviewer and ensure Studio.local_review_role, so the
    # page under review actually RENDERS for whoever follows the link.
    #
    # Best-effort by design. Provisioning is an upgrade to the mint, not a
    # precondition of it: a host with an extra User validation must not turn the
    # review button into a 500 — it should still hand back a working sign-in
    # link, exactly as it did before this method existed. So a failure is logged
    # loudly and the mint proceeds. The end-to-end check that the operator
    # actually lands ON the page is the real gate; this is the thing that makes
    # it pass, not the thing that proves it.
    # `User` is referenced bare, with no defined?/const_defined? guard: those do
    # not agree with each other about a Zeitwerk autoload that has not fired
    # yet, and a guard that reads "absent" on a cold boot would skip
    # provisioning silently — the failure mode being fixed. Studio::LinkConsumption
    # already requires every consuming app to have User, so a genuinely missing
    # one is a NameError the rescue below logs like any other host mismatch.
    def provision_reviewer(email)
      user = User.find_by(email: email) || build_reviewer(email)
      role = Studio.local_review_role.presence
      user.role = role if role && user.respond_to?(:role=) && user.role != role
      user.save! if user.new_record? || user.changed?
      user
    rescue StandardError => e
      # No re-raise: see "best-effort" above. Logged at warn because a silent
      # miss here reappears as the exact symptom this endpoint exists to remove
      # — a successful sign-in that lands on the wrong page.
      Rails.logger.warn(
        "[Studio::LocalReviewsController] could not provision #{email}: #{e.class}: #{e.message}"
      )
      nil
    end

    # A brand-new reviewer goes through the host's own new-user hook first, so
    # the account this endpoint creates is shaped like every other account in
    # the app (usernames, defaults, associations) — then the role is stamped on
    # top. Mirrors Studio::LinkConsumption#sign_up_new, which is the path this
    # provisioning is standing in for.
    def build_reviewer(email)
      User.new(email: email).tap { |user| Studio.configure_new_user.call(user) }
    end

    def require_local_development!
      head :not_found unless Studio.local_tool_enabled?(request_local: request.local?)
    end
  end
end
