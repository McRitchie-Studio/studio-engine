# frozen_string_literal: true

module Studio
  # /profile — the shared account page every Studio app gets.
  #
  # A plain host-inherited controller in the same shape as StyleController and
  # Studio::EmailsController: its view is a bare content wrapper, so it renders
  # inside each host's application layout and picks up that app's navbar, theme
  # and flash. The engine supplies the page; the app supplies the frame.
  #
  # WHY /profile AND NOT /account (2026-08-14, operator's call). turf-monster owns
  # `AccountsController` and the `account_path` helper today. Drawing a shared
  # /account route would raise `Invalid route name, already in use` while turf's
  # own routes.rb loads, which takes down EVERY route in that app — the exact
  # failure that forced draw_admin_emails_routes and draw_onboarding_routes to be
  # opt-in. `profile` is unclaimed in all five consumers, so this page can be
  # drawn by default, which is what makes a brand-new app correct on day one.
  #
  # It also buys the migration path: turf keeps /account working untouched while
  # its rows move to /profile one at a time, and /account is deleted only once it
  # is empty. Two pages briefly coexisting is the point, not an accident.
  #
  # WHAT ROWS RENDER is Studio.profile_sections — see lib/studio/profile_sections.rb.
  # Iteration one ships two: the avatar and the first name.
  class ProfilesController < ::ApplicationController
    # The host's own guard, supplied by Studio::ErrorHandling and format-aware
    # (HTML redirects to login; JSON gets a clean 401 rather than a 406).
    before_action :require_authentication

    # THE shared cap, not a copy of it — see Studio::FIRST_NAME_MAX_LENGTH. The
    # onboarding step writes this same column and reads this same constant, so
    # the two surfaces cannot drift apart.
    MAX_FIRST_NAME = Studio::FIRST_NAME_MAX_LENGTH

    def show
      @profile_sections = Studio.profile_sections_for(view_context)
    end

    # PATCH /profile — the scalar fields. Today that is the first name.
    def update
      return unsupported("name") unless row_rendered?(:first_name)

      value = normalized_first_name

      if value.blank?
        return redirect_to profile_path, alert: "Enter your first name.", status: :see_other
      end

      rescue_and_log(target: current_user) do
        attrs = { first_name: value }
        # Backfill `name` when it is blank so the display-name chain has
        # something better than an email prefix to show. Same rule as the
        # onboarding step, which writes this column from the other direction.
        attrs[:name] = value if current_user.respond_to?(:name) && current_user.name.blank?

        if current_user.update(attrs)
          # Read back rather than trusting the write. A host whose before_save
          # DERIVES first_name from name (turf-monster's set_name_parts does
          # exactly that) would silently discard the value, and a flash saying
          # "Saved" over a discarded write is worse than a plain failure.
          # Reporting what actually persisted keeps the page honest on a host the
          # engine has not met yet.
          persisted = current_user.reload.first_name.to_s

          if persisted == value
            redirect_to profile_path, notice: "Name updated."
          else
            redirect_to profile_path,
                        alert: "This app derives your name from another field — it saved as #{persisted.presence || "blank"}.",
                        status: :see_other
          end
        else
          redirect_to profile_path,
                      alert: current_user.errors.full_messages.to_sentence.presence || "Could not save that name.",
                      status: :see_other
        end
      end
    end

    # PATCH /profile/avatar — the picture, on its own route.
    #
    # SEPARATE FROM #update deliberately: an attachment param submitted empty
    # PURGES the attachment, so a combined form that carried both would delete
    # someone's avatar every time they edited their name. turf-monster learned
    # this and branched inside its own #update; a separate route is the same
    # lesson expressed so the trap cannot be reintroduced.
    def avatar
      return unsupported("profile photo") unless row_rendered?(:avatar)

      file = params.dig(:profile, :avatar)

      if file.blank?
        return redirect_to profile_path, alert: "Choose an image first.", status: :see_other
      end

      unless Studio::ProfileImage.acceptable?(file)
        return redirect_to profile_path, alert: Studio::ProfileImage::MESSAGE, status: :see_other
      end

      rescue_and_log(target: current_user) do
        current_user.avatar.attach(file)
        redirect_to profile_path, notice: "Photo updated."
      end
    end

    # PATCH /profile/email — change the address, from any signed-in session.
    #
    # DIRECT, not out-of-band (operator's call, 2026-08-14). An earlier build
    # mailed a confirmation link to the current address and applied the change
    # only when the holder of that inbox clicked it. That is the stronger flow and
    # it is gone on purpose: the session is now the authority.
    #
    # What that trades away, stated so nobody has to rediscover it: a hijacked
    # session can move the account to another inbox, and the old address no
    # longer gets a veto. Two things are kept BECAUSE the veto is gone —
    #
    #   * the OLD address is mailed after every change (OPSEC-046), so a change
    #     nobody made is visible to the person losing the account, and
    #   * every OTHER session is invalidated (OPSEC-045), so a hijacker holding a
    #     second cookie loses it the moment the address moves.
    #
    # THE GOOGLE EXCEPTION. An account with a linked Google identity cannot
    # change its email here: Google is the authoritative source for that address,
    # and letting the two drift means the next OAuth sign-in either re-links to a
    # stranger's row or fails to find its own. Unlink Google first, then change it.
    def email
      return unsupported("email") unless row_rendered?(:email)

      if Studio::OauthIdentity.google_linked?(current_user)
        return redirect_to profile_path, status: :see_other,
                           alert: "Your email comes from your linked Google account. " \
                                  "Unlink Google first if you want to change it."
      end

      value = params.dig(:profile, :email).to_s.strip
      current = current_user.email.to_s

      return redirect_to profile_path, alert: "Enter an email address.", status: :see_other if value.blank?

      if value.casecmp?(current)
        return redirect_to profile_path, alert: "That is already your email address.", status: :see_other
      end

      rescue_and_log(target: current_user) do
        unless current_user.update(email: value)
          next redirect_to profile_path, status: :see_other,
                           alert: current_user.errors.full_messages.to_sentence.presence ||
                                  "Could not save that address."
        end

        # The new address has not been proved yet; the host's own verification
        # flow picks it up from here.
        current_user.update_columns(email_verified_at: nil) if current_user.respond_to?(:email_verified_at)

        # ROTATE FIRST, MAIL SECOND — the order matters and it was the other way
        # round. Studio::Email.deliver can raise (a host's delivery record is a
        # create! plus perform_later with no rescue at that level), and a mail
        # failure between the write and the rotation would leave the address
        # changed with every other session still live. That is the exact window
        # OPSEC-045 exists to close, so it closes before anything that can throw.
        # turf-monster's own apply_email_change rotates first for the same reason.
        if current_user.respond_to?(:regenerate_session_token!)
          current_user.regenerate_session_token!
          # Re-establish THIS session. Rotating without it signs out the very
          # person who just made the change — correct when the actor arrived from
          # a confirmation link, wrong now that the actor IS the session.
          session[:session_token] = current_user.session_token if current_user.respond_to?(:session_token)
        end

        if current.present?
          Studio::Email.deliver(Studio::ProfileMailer, :email_change_notification,
                                current_user, current, value, to: current, user: current_user)
        end

        redirect_to profile_path, notice: "Email changed to #{value}."
      end
    end

    # DELETE /profile/google — drop the linked Google identity.
    #
    # REFUSES WHEN IT WOULD ORPHAN THE ACCOUNT. turf-monster's version is an
    # unconditional `update!(provider: nil, uid: nil)`; for an account whose only
    # sign-in is Google (no email, so no magic link; no wallet; no password) that
    # locks someone out of their own account behind a button labelled "Unlink".
    # It is safe in turf only because turf's users happen to carry an email —
    # a property of that app's data, not of the code.
    #
    # Studio::OauthIdentity gates on Studio.auth_methods, not merely on the
    # column: an app with an email column that does not offer magic-link sign-in
    # cannot use it to get back in.
    def unlink_google
      return unsupported("Google account") unless row_rendered?(:google)

      unless Studio::OauthIdentity.google_linked?(current_user)
        return redirect_to profile_path, alert: "No Google account is linked.", status: :see_other
      end

      if Studio::OauthIdentity.unlink_orphans_account?(current_user)
        return redirect_to profile_path, status: :see_other,
                           alert: "Google is the only way to sign in to this account. " \
                                  "Add an email address first, then unlink."
      end

      rescue_and_log(target: current_user) do
        current_user.update!(provider: nil, uid: nil)
        redirect_to profile_path, notice: "Google account unlinked."
      end
    end

    private

    # Would the page render this row for this viewer?
    #
    # A HIDDEN ROW IS NOT A GUARD. Studio::ProfileSections drops a row this host
    # cannot serve, so nobody SEES a first-name form in an app without the
    # column — but the endpoint stays open to anyone who posts to it, and
    # rescue_and_log RE-RAISES, so an unguarded write is a 500 plus an ErrorLog
    # row. Three of the five consumers have an avatar attachment and no
    # first_name column right now.
    #
    # ASKED OF THE RESOLVER, not of one of its rules — and that distinction was a
    # real bug, caught in review. This used to call served_by?, which answers only
    # the MODEL gate (`requires:`). Once rows also carried an APP gate (`if:`),
    # the two questions came apart: mcritchie-industries drops the Google row
    # because it offers no Google sign-in, while the endpoint — asking only about
    # columns it does have — stayed open. The comment here claimed they "cannot
    # drift" while they were already drifting.
    #
    # Asking the resolver makes that true rather than asserted: the page and the
    # endpoint run the same code and get the same answer, whatever gates a row
    # grows next.
    def row_rendered?(key)
      profile_rows.any? { |section| section[:key] == key.to_sym }
    end

    # Memoized per request: a host's `if:` may be a lambda doing real work, and a
    # write should not pay for it more than once.
    def profile_rows
      @profile_rows ||= Studio.profile_sections_for(view_context)
    end

    # Land the person back on a page that works rather than on a bare 404. This
    # is unreachable through the UI — the row that posts here is not rendered —
    # so the wording is for whoever is poking at the endpoint directly.
    def unsupported(label)
      redirect_to profile_path,
                  alert: "This app has no #{label} to change.",
                  status: :see_other
    end

    # Collapse runs of whitespace and cap the length. Done here rather than in a
    # model validation because the engine does not own the host's User class.
    def normalized_first_name
      params.dig(:profile, :first_name).to_s.strip.gsub(/\s+/, " ")[0, MAX_FIRST_NAME].to_s
    end
  end
end
