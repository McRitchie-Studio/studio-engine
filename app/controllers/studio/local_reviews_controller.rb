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
  class LocalReviewsController < ApplicationController
    include Studio::MagicLinkIssuing

    skip_before_action :require_authentication, raise: false

    before_action :require_local_development!

    def show
      email = Studio::LinkToken.normalize_email(params[:email])
      return redirect_to(login_path, alert: MISSING_EMAIL) unless email.match?(URI::MailTo::EMAIL_REGEXP)

      # return_to is passed through raw: BOTH stores sanitize it to a same-origin
      # path on the way in (Studio::Link.create_magic_link and MagicLink.generate
      # each call Studio::LinkToken.sanitize_path). Re-sanitizing here would be a
      # second spelling of a rule that already has one owner — and a mutation run
      # confirmed it guards nothing the store does not already guard.
      token = issue_magic_link(email, params[:return_to])
      redirect_to magic_link_url_for(token), allow_other_host: false
    end

    private

    MISSING_EMAIL = "Add ?email=<your address> to mint a local review link."

    def require_local_development!
      head :not_found unless Studio.local_tool_enabled?(request_local: request.local?)
    end
  end
end
