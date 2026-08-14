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

    private

    # Collapse runs of whitespace and cap the length. Done here rather than in a
    # model validation because the engine does not own the host's User class.
    def normalized_first_name
      params.dig(:profile, :first_name).to_s.strip.gsub(/\s+/, " ")[0, MAX_FIRST_NAME].to_s
    end
  end
end
