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
      @profile_sections = Studio.profile_sections_for(view_context, page: :show)
    end

    # GET /profile/edit — the form. Read and edit are separate pages (operator's
    # call, 2026-08-14): /profile is "you at a glance", this is where you change
    # things.
    def edit
      @profile_sections = Studio.profile_sections_for(view_context, page: :edit)
    end

    # PATCH /profile — every editable field, in one request.
    #
    # ONE FORM, ONE SAVE (operator's call). Email used to be its own action, and
    # needed to be only while it was out-of-band; now that it applies directly
    # there is no reason for a second mechanism on the same page. Its side
    # effects stay here rather than moving into the form.
    #
    # Each field is applied only if its ROW would render — the same resolver the
    # page uses — so a host that cannot serve a field cannot have one posted into
    # it either.
    def update
      attrs = {}
      attrs.merge!(name_attributes)     if row_rendered?(:name)
      attrs.merge!(birthday_attributes) if row_rendered?(:birthday)

      # May redirect (the Google lock); if it did, we are done.
      prepare_email_change(attrs) if row_rendered?(:email)
      return if performed?

      if attrs.empty?
        return redirect_to edit_profile_path, alert: "Nothing to save.", status: :see_other
      end

      previous_email = current_user.email.to_s if current_user.respond_to?(:email)

      rescue_and_log(target: current_user) do
        unless current_user.update(attrs)
          next redirect_to edit_profile_path, status: :see_other,
                           alert: current_user.errors.full_messages.to_sentence.presence ||
                                  "Could not save those changes."
        end

        after_email_change(previous_email) if attrs.key?(:email)

        redirect_to profile_path, notice: "Profile updated."
      end
    end

    # PATCH /profile/avatar — the picture, on its own route.
    #
    # SEPARATE FROM #update deliberately: an attachment param submitted empty
    # PURGES the attachment, so a combined form carrying both would delete
    # someone's photo every time they saved a name. A separate route makes that
    # unreachable rather than merely avoided.
    #
    # GUARDED DIFFERENTLY FROM THE FIELD ROWS, and the difference is real: the
    # avatar stopped being a row when it moved into the identity header, so
    # "would its row render?" has no answer for it. The MODEL gate is the right
    # question here — can this host's user hold an attachment at all.
    def avatar
      return unsupported("profile photo") unless avatar_supported?

      file = params.dig(:profile, :avatar)

      if file.blank?
        return redirect_to edit_profile_path, alert: "Choose an image first.", status: :see_other
      end

      unless Studio::ProfileImage.acceptable?(file)
        return redirect_to edit_profile_path, alert: Studio::ProfileImage::MESSAGE, status: :see_other
      end

      rescue_and_log(target: current_user) do
        current_user.avatar.attach(file)
        redirect_to edit_profile_path, notice: "Photo updated."
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

    # POST /profile/newsletter — join the mailing list.
    #
    # DIRECT, no confirmation. Joining is reversible in one click from the same
    # card, so a confirm step would be friction protecting nothing. LEAVING is the
    # one that asks, because a mis-click there is silent until the next send that
    # never arrives.
    #
    # An account with no address on file supplies one here — a wallet-only sign-in
    # has no email, and a newsletter needs somewhere to send. It is written as the
    # account email but NOT marked verified: this proves the person can type an
    # address, not that they hold it, and treating it as verified would turn a
    # mailing-list form into an account-recovery path.
    def subscribe_newsletter
      return unsupported("newsletter") unless row_rendered?(:newsletter)

      if Studio::Newsletter.needs_email?(current_user)
        value = params.dig(:profile, :email).to_s.strip
        unless value.match?(URI::MailTo::EMAIL_REGEXP)
          return redirect_to profile_path, status: :see_other,
                             alert: "Enter an email address to subscribe."
        end
        current_user.email = value
      end

      rescue_and_log(target: current_user) do
        # left_email_list_at is CLEARED rather than left in place. `subscribed?`
        # compares the two dates, so a stale leave date in the future of the join
        # would read as unsubscribed the moment the clock disagreed.
        current_user.update!(joined_email_list_at: Time.current, left_email_list_at: nil)
        redirect_to profile_path, notice: "You're on the list."
      end
    end

    # DELETE /profile/newsletter — leave it.
    #
    # STAMPS A DATE, never clears the join. "Have they ever joined" is a different
    # question from "are they on the list", and a consumer that pays a once-ever
    # welcome bonus (turf-monster does, on-chain) needs the first one to survive
    # every leave and rejoin. Clearing joined_email_list_at here would let someone
    # re-earn it by cycling.
    def unsubscribe_newsletter
      return unsupported("newsletter") unless row_rendered?(:newsletter)

      unless Studio::Newsletter.subscribed?(current_user)
        return redirect_to profile_path, alert: "You're not subscribed.", status: :see_other
      end

      rescue_and_log(target: current_user) do
        current_user.update!(left_email_list_at: Time.current)
        redirect_to profile_path, notice: "You've been unsubscribed."
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

    # The avatar is not a row, so it asks the MODEL gate directly — see #avatar.
    def avatar_supported?
      Studio::ProfileSections.served_by?(current_user, :avatar)
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

    # --- field assembly ---------------------------------------------------------

    def name_attributes
      attrs = {}
      first = normalized_name(params.dig(:profile, :first_name))
      attrs[:first_name] = first if first.present?

      if current_user.respond_to?(:last_name)
        last = normalized_name(params.dig(:profile, :last_name))
        attrs[:last_name] = last if last.present?
      end

      # Backfill `name` when it is blank so the display-name chain has something
      # better than an email prefix to show. Same rule as the onboarding step.
      if attrs[:first_name].present? && current_user.respond_to?(:name) && current_user.name.blank?
        attrs[:name] = [attrs[:first_name], attrs[:last_name]].compact_blank.join(" ")
      end

      attrs
    end

    # ONE date input, THREE integer columns. The split is deliberate upstream —
    # it keeps "how old are they" and "whose birthday is today" both cheap — so
    # the form joins them and this takes them apart again.
    #
    # A blank date CLEARS all three rather than being ignored: someone deleting
    # their birthday means it, and leaving a stale year behind would be the
    # wrong answer to both questions above.
    def birthday_attributes
      raw = params.dig(:profile, :birthday)
      return {} if raw.nil?

      if raw.to_s.strip.blank?
        return { birth_year: nil, birth_month: nil, birth_day: nil }
      end

      date = begin
        Date.iso8601(raw.to_s)
      rescue ArgumentError, TypeError
        nil
      end
      return {} if date.nil? || date > Date.current

      { birth_year: date.year, birth_month: date.month, birth_day: date.day }
    end

    # Adds :email to attrs, or REDIRECTS when the change must be refused — the
    # caller checks performed? rather than a return value.
    def prepare_email_change(attrs)
      value = params.dig(:profile, :email).to_s.strip
      return nil if value.blank?
      return nil if value.casecmp?(current_user.email.to_s)

      # THE GOOGLE EXCEPTION. Google is the authoritative source for a linked
      # account's address; letting the two drift means the next OAuth sign-in
      # either re-links to a stranger's row or cannot find its own. The field is
      # locked in the row and refused here — a disabled input is a courtesy, and
      # anyone can POST.
      if Studio::OauthIdentity.google_linked?(current_user)
        redirect_to edit_profile_path, status: :see_other,
                    alert: "Your email comes from your linked Google account. " \
                           "Unlink Google on your profile first if you want to change it."
        return
      end

      attrs[:email] = value
      nil
    end

    # The two protections kept BECAUSE a direct change leaves the old address no
    # veto: tell it, and invalidate every other session.
    def after_email_change(previous_email)
      current_user.update_columns(email_verified_at: nil) if current_user.respond_to?(:email_verified_at)

      # ROTATE FIRST, MAIL SECOND. Studio::Email.deliver can raise, and a mail
      # failure between the write and the rotation would leave the address
      # changed with every other session still live — the exact window OPSEC-045
      # exists to close, so it closes before anything that can throw.
      # turf-monster's own apply_email_change rotates first for the same reason.
      if current_user.respond_to?(:regenerate_session_token!)
        current_user.regenerate_session_token!
        # Re-establish THIS session. Rotating without it signs out the very
        # person who just made the change.
        session[:session_token] = current_user.session_token if current_user.respond_to?(:session_token)
      end

      return if previous_email.blank?

      Studio::Email.deliver(Studio::ProfileMailer, :email_change_notification,
                            current_user, previous_email, current_user.email,
                            to: previous_email, user: current_user)
    end

    # Collapse runs of whitespace and cap the length. Done here rather than in a
    # model validation because the engine does not own the host's User class.
    def normalized_name(raw)
      raw.to_s.strip.gsub(/\s+/, " ")[0, MAX_FIRST_NAME].to_s
    end
  end
end
