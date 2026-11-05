class RegistrationsController < ApplicationController
  include Studio::MagicLinkIssuing

  skip_before_action :require_authentication

  # Shown when the sign-in link could not be minted or mailed. The same words for
  # every address, known or new, so a failure reveals no more than a success does.
  DELIVERY_FAILED = "We could not send your sign-in email just now. Please try again in a few minutes.".freeze

  def new
    @user = User.new
  end

  # Gated on the same predicate registrations/new renders the password form on,
  # so the form a visitor sees is always the form this action reads.
  #
  # No method-level rescue. One used to catch every StandardError here, log
  # nothing, and render registrations/new; on the passwordless branch @user was
  # never set, so that render raised NoMethodError on nil and the failure that
  # started it was lost. Each branch now owns its failure, and anything it does
  # not expect is logged by rescue_and_log and left to surface.
  def create
    Studio.password_login_available? ? create_with_password : create_passwordless
  end

  private

  # Passwordless apps: there is no create-account-by-form. Logging a user in
  # straight from a signup POST would skip proof of email ownership, so we
  # treat "sign up" as a magic-link request — the create-or-login link (which
  # only fires after the recipient clicks it) does the account creation.
  #
  # A mint or mail failure is logged (rescue_and_log) and answered with the same
  # friendly page for every address. No account exists either way, and this
  # branch never looks one up, so the answer cannot say whether the email is known.
  def create_passwordless
    email = (params.dig(:user, :email) || params[:email]).to_s.strip.downcase
    if email.match?(URI::MailTo::EMAIL_REGEXP)
      begin
        rescue_and_log do
          token = issue_magic_link(email, nil)
          Studio::Email.deliver(UserMailer, :magic_link, email, token, to: email)
        end
      rescue StandardError
        return redirect_to signup_path, alert: DELIVERY_FAILED
      end
    end
    redirect_to login_path, notice: "Check your inbox — we just emailed you a #{Studio::AuthLabels.link_noun(Studio.sign_in_label)}."
  end

  # A validation failure is the visitor's input: re-render the form with its
  # errors and write no ErrorLog row. Anything else is logged and re-raised to
  # the engine's catch-all, never swallowed.
  #
  # No `target:` here. The user is unsaved when the raise lands, and ErrorLog's
  # belongs_to would autosave it while writing the row: the same failing write a
  # second time, inside the logger, masking the error it exists to record.
  def create_with_password
    @user = User.new(user_params)
    rescue_and_log do
      Studio.configure_new_user.call(@user)
      if @user.save
        set_app_session(@user)
        redirect_to root_path, notice: Studio.welcome_message.call(@user)
      else
        render :new, status: :unprocessable_entity
      end
    end
  end

  # A POST with no `user` key builds a blank user, whose validations then
  # re-render the form, rather than a ParameterMissing the form cannot show.
  def user_params
    params.fetch(:user, {}).permit(*Studio.registration_params)
  end
end
