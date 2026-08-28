# Solana / Phantom wallet sign-in (the web3 path).
#
#   GET  /auth/solana/nonce  — issue a one-time nonce for the SIWS message
#   POST /auth/solana/verify — verify the ed25519 signature, log in / sign up
#
# The cryptography lives in the solana-studio gem (Solana::AuthVerifier); the
# Solana::SessionAuth concern adapts it to the Rails session (delete-before-verify
# nonce burn + host binding). On success the session is granted the :onchain flag
# so SessionContext reports :web3 (can sign on-chain txs this session).
#
# Engine GENERIC base. Apps with a richer wallet identity (turf-monster: managed
# wallets, web2/web3 address split, account-linking, referral attribution)
# OVERRIDE this controller; it stays this simple for an app whose wallet is just
# an identity (one `solana_address` column).
class SolanaSessionsController < ApplicationController
  include Solana::SessionAuth
  skip_before_action :require_authentication

  def nonce
    session[:solana_nonce]    = SecureRandom.hex(16)
    session[:solana_nonce_at] = Time.current.to_i
    render json: { nonce: session[:solana_nonce] }
  end

  # Where Phantom redirects back to after a mobile signIn. The page itself does
  # the work — decrypt Phantom's reply with the keypair the deep link stashed in
  # localStorage, rebuild the signed message, and POST it to #verify — so this
  # action only renders it. It must stay UNAUTHENTICATED: the whole point is
  # that nobody is signed in yet.
  def phantom_callback
    render :phantom_callback
  end

  def verify
    pubkey_b58 = verify_solana_signature!(
      message:       params[:message],
      signature_b58: params[:signature],
      pubkey_b58:    params[:pubkey],
      session:       session
    )

    user   = User.from_solana_wallet(pubkey_b58)
    is_new = user.nil?

    if is_new
      user = User.new(solana_address: pubkey_b58)
      Studio.configure_new_user.call(user)
    end

    rescue_and_log(target: user) do
      user.save! if user.new_record?
      set_app_session(user)
      session[:onchain] = true
      render json: { success: true, redirect: root_path, new_user: is_new }
    end
  rescue ::Solana::AuthVerifier::VerificationError => e
    render json: { error: e.message }, status: :unauthorized
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
