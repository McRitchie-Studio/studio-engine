class RegistrationsController < ApplicationController
  include Studio::MagicLinkIssuing

  skip_before_action :require_authentication

  def new
    @user = User.new
  end

  def create
    # Passwordless apps: there is no create-account-by-form. Logging a user in
    # straight from a signup POST would skip proof of email ownership, so we
    # treat "sign up" as a magic-link request — the create-or-login link (which
    # only fires after the recipient clicks it) does the account creation.
    unless Studio.auth_method?(:password)
      email = (params.dig(:user, :email) || params[:email]).to_s.strip.downcase
      if email.match?(URI::MailTo::EMAIL_REGEXP)
        token = issue_magic_link(email, nil)
        Studio::Email.deliver(UserMailer, :magic_link, email, token, to: email)
      end
      return redirect_to login_path, notice: "Check your inbox — we just emailed you a sign-in link."
    end

    @user = User.new(user_params)
    Studio.configure_new_user.call(@user)
    rescue_and_log(target: @user) do
      @user.save!
      set_app_session(@user)
      redirect_to root_path, notice: Studio.welcome_message.call(@user)
    end
  rescue StandardError => e
    render :new, status: :unprocessable_entity
  end

  private

  def user_params
    params.require(:user).permit(*Studio.registration_params)
  end
end
