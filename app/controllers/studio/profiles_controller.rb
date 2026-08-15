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

    # The confirm link is sent to the person's OLD inbox and may be opened on a
    # device that is not signed in — so the SIGNED TOKEN is the auth boundary for
    # these two, not the session. Skipping is what makes the flow work on a
    # second device; the token check in each action is what keeps it safe.
    skip_before_action :require_authentication,
                       only: %i[confirm_email_change apply_email_change], raise: false

    # THE shared cap, not a copy of it — see Studio::FIRST_NAME_MAX_LENGTH. The
    # onboarding step writes this same column and reads this same constant, so
    # the two surfaces cannot drift apart.
    MAX_FIRST_NAME = Studio::FIRST_NAME_MAX_LENGTH

    def show
      @profile_sections = Studio.profile_sections_for(view_context)
    end

    # PATCH /profile — the scalar fields. Today that is the first name.
    def update
      return unsupported(:first_name) unless serves?(:first_name)

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
      return unsupported(:avatar) unless serves?(:avatar)

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

    # PATCH /profile/email — ASK to change the address. Never applies it.
    #
    # OUT-OF-BAND BY DESIGN (turf-monster's Lazarus audit #4, lifted whole). The
    # request only mints a token and mails it to the CURRENT address; the change
    # lands when the holder of THAT inbox confirms. A logged-in session is not
    # enough to move an account to someone else's mailbox, which is exactly what
    # a direct write here would allow after a session hijack.
    #
    # The one exception is an account with NO email yet: there is no prior owner
    # to ask, so the first address applies directly and is simply unverified.
    def email
      return unsupported(:email) unless serves?(:email)

      value = params.dig(:profile, :email).to_s.strip
      current = current_user.email.to_s

      return redirect_to profile_path, alert: "Enter an email address.", status: :see_other if value.blank?

      if value.casecmp?(current)
        return redirect_to profile_path, alert: "That is already your email address.", status: :see_other
      end

      rescue_and_log(target: current_user) do
        if current.blank?
          # First address on the account. Nothing to protect, so apply it —
          # unverified, which the host's own verification flow then handles.
          current_user.update(email: value)
          current_user.update_columns(email_verified_at: nil) if current_user.respond_to?(:email_verified_at)
          next redirect_to profile_path, notice: "Email set to #{value}. Check your inbox to verify it."
        end

        token = Studio::EmailChangeToken.generate(
          user_id: current_user.id, current_email: current, new_email: value
        )
        Studio::Email.deliver(Studio::ProfileMailer, :email_change_confirmation,
                              current_user, current, value, token,
                              to: current, user: current_user)

        # A modal, not a flash toast: this is a handoff with two addresses in it —
        # which inbox to open and what will happen — and a one-line toast cannot
        # carry that without being ignored. show.html.erb reads this flash into a
        # JSON tag and opens studio/modals/blocks/email_change_pending.
        flash[:email_change_pending] = { current_email: current, new_email: value }
        redirect_to profile_path
      end
    end

    # GET /profile/email/confirm/:token — RENDER the confirmation. Never mutates.
    #
    # THIS IS THE HALF THAT MUST NOT WRITE. Mail scanners and link prefetchers
    # issue GETs without a human involved, so a GET that applied the change would
    # let a prefetch silently complete an account takeover. The swap is the
    # CSRF-protected POST below.
    #
    # Authentication is the TOKEN, not the session: the link is sent to the old
    # inbox and may be opened on a device that is not signed in.
    def confirm_email_change
      @email_change = Studio::EmailChangeToken.verify(params[:token])
      @email_change_token = params[:token]
      @email_change_user = User.find_by(id: @email_change[:user_id])

      unless Studio::EmailChangeToken.fresh_for?(@email_change, @email_change_user)
        return render_email_change_dead
      end
      # renders studio/profiles/confirm_email_change
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      render_email_change_dead
    end

    # POST /profile/email/confirm/:token — apply it.
    def apply_email_change
      payload = Studio::EmailChangeToken.verify(params[:token])
      user = User.find_by(id: payload[:user_id])

      return render_email_change_dead unless Studio::EmailChangeToken.fresh_for?(payload, user)

      rescue_and_log(target: user) do
        old_email = user.email
        user.update!(email: payload[:new_email])
        user.update_columns(email_verified_at: nil) if user.respond_to?(:email_verified_at)

        # OPSEC-045: rotate the session token so any OTHER live session — a
        # hijacker's, say, which is how an unwanted change gets started — loses
        # access the moment the legitimate owner confirms.
        user.regenerate_session_token! if user.respond_to?(:regenerate_session_token!)

        # OPSEC-046: tell the OLD address it happened. An unauthorised change is
        # then visible to the person losing the account instead of silent.
        Studio::Email.deliver(Studio::ProfileMailer, :email_change_notification,
                              user, old_email, user.email, to: old_email, user: user)

        redirect_to(logged_in? ? profile_path : login_path,
                    notice: "Email changed to #{user.email}.")
      end
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      render_email_change_dead
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
      return unsupported(:google_account) unless serves?(:provider) && serves?(:uid)

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

    # ONE response for every dead-link case — bad signature, malformed token,
    # expired, already used, or superseded by a newer change.
    #
    # Deliberately undifferentiated: the person's next step is identical in all
    # of them (ask for a fresh link), and telling an attacker WHICH way a token
    # failed hands them a probe. 410 Gone rather than 404 — the link was real,
    # it simply is not any more.
    def render_email_change_dead
      render plain: "This email-change link is invalid, expired, or has already been used. " \
                    "Request a fresh one from your profile page.",
             status: :gone
    end

    # Can this host's user model serve this field?
    #
    # A HIDDEN ROW IS NOT A GUARD. Studio::ProfileSections drops a row the host
    # cannot serve, so nobody SEES a first-name form in an app without the
    # column — but the endpoint stays open to anyone who posts to it, and
    # rescue_and_log RE-RAISES, so an unguarded write is a 500 plus an ErrorLog
    # row. That is not hypothetical: three of the five consumers
    # (mcritchie-industries, moms-app, acquisition-studio) have an avatar
    # attachment and no first_name column right now.
    #
    # The endpoint asks the SAME question the row does, through the SAME method,
    # so the two cannot drift into disagreeing about what this app supports.
    def serves?(attribute)
      Studio::ProfileSections.served_by?(current_user, attribute)
    end

    # Land the person back on a page that works rather than on a bare 404. This
    # is unreachable through the UI — the row that posts here is not rendered —
    # so the wording is for whoever is poking at the endpoint directly.
    def unsupported(attribute)
      redirect_to profile_path,
                  alert: "This app has no #{attribute.to_s.tr("_", " ")} to change.",
                  status: :see_other
    end

    # Collapse runs of whitespace and cap the length. Done here rather than in a
    # model validation because the engine does not own the host's User class.
    def normalized_first_name
      params.dig(:profile, :first_name).to_s.strip.gsub(/\s+/, " ")[0, MAX_FIRST_NAME].to_s
    end
  end
end
