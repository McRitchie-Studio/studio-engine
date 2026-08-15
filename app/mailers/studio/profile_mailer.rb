# frozen_string_literal: true

module Studio
  # The two emails an email change sends.
  #
  # NAMESPACED, and that is load-bearing rather than tidiness. `app/mailers` is an
  # autoload path and this engine is not isolated, so a host that defines a
  # top-level `UserMailer` SHADOWS the engine's outright. Two consumers do:
  # mcritchie-studio (which defines no email-change actions, so a bare call would
  # raise NoMethodError) and turf-monster (which defines `email_change_confirmation`
  # and `email_change_notification` ALREADY, with its own signature and its own
  # `confirm_email_change_url` pointing at /account). That second case is the
  # dangerous one: no exception, no warning, and the engine's flow quietly mails a
  # link to turf's route instead of its own.
  #
  # Under `Studio::` nothing shadows it, following Studio::NewsletterMailer.
  #
  # WHY TWO EMAILS, going to two different addresses:
  #
  #   email_change_confirmation → the CURRENT address. It carries the link that
  #     authorizes the swap, so the person who holds the existing inbox is the one
  #     who approves it. Sending it to the NEW address instead would let anyone
  #     who reached a logged-in session move the account to their own inbox.
  #
  #   email_change_notification → the OLD address, AFTER the swap. Out-of-band
  #     notice that the change happened, so an unauthorized change is visible to
  #     the person losing the account rather than silent.
  class ProfileMailer < ApplicationMailer
    layout "branded_mailer"

    # To the OLD address, after the swap landed.
    def email_change_notification(user, old_email, new_email)
      @user      = user
      @app_name  = Studio.app_name
      @old_email = old_email
      @new_email = new_email

      @banner     = Studio::Banner.for(:email_change_notification, name: display_name_for(user))
      @banner_url = Studio::EmailCatalog.resolved_url(:email_change_notification)
      @banner_alt = [@banner&.header, "your #{@app_name} email was changed"].compact.join(" — ")

      mail(to: old_email, subject: Studio::EmailCatalog.subject_for(:email_change_notification, name: display_name_for(user)))
    end

    private

    # The engine's User contract guarantees display_name, but this mailer is also
    # reachable from a host whose model is mid-migration; a name is a nicety and
    # must never be the reason an email fails to send.
    def display_name_for(user)
      return nil unless user.respond_to?(:display_name)

      user.display_name
    rescue StandardError
      nil
    end
  end
end
