# frozen_string_literal: true

module Studio
  # The first-name onboarding step's two writes — capture a name, or record that
  # the account skipped it. Ported from turf-monster (2026-08), where this ran as
  # a local OnboardingController, because the same ask is wanted in every Studio
  # app: McRitchie Studio, McRitchie Industries, and turf-monster all address
  # people by name in email, and all three were going to write this controller.
  #
  # What the ENGINE owns here is ONE STEP. What each HOST still owns is the
  # SEQUENCE around it — turf walks welcome → first name → age → wallet; a hub app
  # may ask nothing else. Hosts declare that through
  # Studio.onboarding_steps_resolver, whose value this returns as `next` so the
  # client keeps walking without a second round trip.
  #
  # A plain host-inherited controller (same shape as StyleController and
  # Studio::EmailsController): it renders no layout of its own, answers JSON only,
  # and picks up the host's authentication from ApplicationController.
  #
  # Routes are OPT-IN via Studio.draw_onboarding_routes — turf-monster owns these
  # helper names until its adoption task deletes the local pair.
  class OnboardingController < ::ApplicationController
    # Both actions are for the freshly signed-in user, so authentication is the
    # host's default require_authentication — no skip_before_action here.

    # The shared cap (Studio::FIRST_NAME_MAX_LENGTH). Kept under the old name
    # here because it is referenced from outside this class; what changed is that
    # it is no longer a SECOND definition of the same number. /profile writes the
    # same column and now reads the same constant.
    MAX_FIRST_NAME = Studio::FIRST_NAME_MAX_LENGTH

    # POST /onboarding/first_name
    #
    # Writes users.first_name, and backfills `name` when it is blank so the
    # display-name chain has something better than an email prefix to show.
    def first_name
      value = params[:first_name].to_s.strip.gsub(/\s+/, " ").first(MAX_FIRST_NAME)

      if value.blank?
        return render json: { ok: false, error: "Enter your first name, or skip for now." },
                      status: :unprocessable_entity
      end

      rescue_and_log(target: current_user) do
        # update_columns, not update!, for THREE reasons — all still true:
        #
        #   1. This runs seconds after signup, on an account that may be
        #      mid-onboarding, and a validation failure elsewhere on the record
        #      (a grandfathered reserved username, say) must not block a name.
        #   2. It steps around any host before_save that DERIVES first_name FROM
        #      name — set_name_parts does exactly that — which would discard the
        #      value we were just handed.
        #   3. THE SLUG. Sluggable's `before_save :set_slug` is UNGATED, and
        #      mcritchie-studio's User#name_slug is built from `name`. A full
        #      save right after this writes `name` would therefore re-point the
        #      slug the account answers on — a URL change, on a column carrying
        #      a unique index, for every signup. That is the constraint this
        #      endpoint has always been protecting; it is not a shortcut.
        #
        # WHAT SKIPPING CALLBACKS USED TO COST. Because set_name_parts never
        # ran, `first_name` got the WHOLE typed value: someone answering "Ada
        # Lovelace" landed first_name="Ada Lovelace", last_name NULL — and it
        # never self-healed, because set_name_parts is gated on `name_changed?`
        # and no later save sees a name change. So the derivation comes to the
        # writer instead: Studio::NameParts is the same rule the callback runs.
        attrs = name_columns(value)
        attrs[:name] = value if current_user.name.blank?
        current_user.update_columns(attrs)

        # The STORED first name, not the typed string — they differ for exactly
        # the case above, and a response that disagreed with the row would be
        # the same bug wearing a different hat.
        render json: { ok: true, first_name: attrs[:first_name], next: remaining_steps }
      end
    end

    # POST /onboarding/skip_first_name
    #
    # Session-scoped, deliberately: skipping means "not now", not "never". A later
    # session can ask again (the field is still blank), which is the whole reason
    # this is not a users column.
    def skip_first_name
      session[Studio::FIRST_NAME_SKIP_SESSION_KEY] = true
      render json: { ok: true, next: remaining_steps }
    end

    private

    # The name halves to write, derived exactly as the host's set_name_parts
    # would derive them from the same string.
    #
    # `last_name` is dropped for a host that has no such column —
    # mcritchie-industries' users table is eight columns wide and update_columns
    # on an absent column raises. Same respond_to? guard /profile already
    # carries for the same reason.
    def name_columns(value)
      parts = Studio::NameParts.from(value)
      parts.delete(:last_name) unless current_user.respond_to?(:last_name)
      parts
    end

    # What is left AFTER this write. The host's resolver decides; the engine's
    # default is "nothing further", which is the right answer for an app whose
    # only onboarding ask is the name.
    def remaining_steps
      resolver = Studio.onboarding_steps_resolver
      return [] unless resolver.respond_to?(:call)

      Array(resolver.call(current_user, session)).map(&:to_s)
    end
  end
end
