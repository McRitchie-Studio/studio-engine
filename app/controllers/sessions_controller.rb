class SessionsController < ApplicationController
  skip_before_action :require_authentication

  def new
  end

  def create
    user = User.find_by(email: params[:email])
    if user&.authenticate(params[:password])
      set_app_session(user)
      redirect_to root_path, notice: "Welcome back, #{user.display_name}!"
    else
      flash.now[:alert] = "Invalid email or password."
      render :new, status: :unprocessable_entity
    end
  end

  # GET /sso_login — one-click SSO entry point (linked from hub app nav).
  #
  # OPSEC-016: this previously called authenticate_sso_user! directly, mutating
  # the session on a GET. GETs are not CSRF-covered and are prefetchable
  # (browser prefetch, <img>, <link rel=prefetch>), so an XSS on any
  # *.mcritchie.studio subdomain could write session[:sso_email] and a forged
  # GET /sso_login would silently start a session as that user. It now only
  # redirects to the login page — the session mutation happens exclusively via
  # the CSRF-protected POST /sso_continue ("Continue as …" button rendered
  # there when sso_user_available?).
  def sso_login
    return redirect_to root_path if logged_in?

    redirect_to login_path
  end

  # POST /sso_continue — form-based SSO from login page button
  def sso_continue
    return redirect_to login_path unless sso_user_available?

    authenticate_sso_user!
  rescue StandardError => e
    create_error_log(e)
    redirect_to login_path, alert: "Could not continue session. Please log in."
  end

  def destroy
    clear_app_session
    redirect_to login_path, notice: "Logged out."
  end

  private

  def authenticate_sso_user!
    user = User.find_by(email: session[:sso_email])
    unless user
      user = User.new(
        email:    session[:sso_email],
        name:     session[:sso_name],
        provider: session[:sso_provider],
        uid:      session[:sso_uid]
      )
      # Only a host that takes a password gets one: has_secure_password defines
      # `password=` and requires a value on create, so those apps need a random
      # placeholder. A passwordless User has no such writer, and passing
      # `password:` to User.new raised UnknownAttributeError, which sso_continue
      # rescued into a redirect: SSO sign-up failed silently on every passwordless
      # app (/tasks/engine-sso-creates-passwordless-users).
      user.password = SecureRandom.hex(16) if user.respond_to?(:password=)
      Studio.configure_sso_user.call(user)
      rescue_and_log(target: user) do
        user.save!
      end
    end

    set_app_session(user)
    redirect_to root_path, notice: Studio.welcome_message.call(user)
  end
end
