# frozen_string_literal: true

module Studio
  # The connect, callback and disconnect actions for any provider a host
  # declared with Studio.define_connection (docs/CONNECTIONS.md). Included by
  # Studio::ConnectionsController; a host includes it in its own admin
  # controller instead when that controller also serves the provider's page
  # (its `show`, with the provider's live read), and names that controller in
  # Studio.draw_connection_routes.
  #
  #   connect     checks the encryption keys and the client, keeps a fresh OAuth
  #               state (and, for an account named before Connect, the checked
  #               account) in the session, and redirects to the provider
  #   callback    checks the state first, then the provider's refusal, its own
  #               callback check and the account; exchanges the code (a code
  #               grant); names the account with the host's describe hook; and
  #               stores Studio::Connection. The account named before Connect
  #               is read from the session, never from the callback's query.
  #   disconnect  revokes the grant at the provider when it has a revoke
  #               endpoint, forgets an in-memory token, deletes the row, and
  #               says whether the provider confirmed
  #
  # No token, and no part of one, is rendered, flashed or logged here. A
  # refused exchange, describe or revoke is kept in the error log
  # (Studio::ErrorHandling#rescue_and_log) as well as said on the page.
  #
  # WHO MAY: the host's admin guard, Studio.connection_admin_guard (a method
  # name on the controller, :require_admin by default, or a callable taking
  # the controller). WHERE IT COMES BACK: return_to, honoured only when it is
  # exactly one of the route's return paths (never an open redirect).
  module ConnectionFlow
    extend ActiveSupport::Concern

    included do
      before_action :require_connection_admin
      # The callback's URL carries a single-use code: no cache keeps the page.
      before_action(only: :callback) { response.headers["Cache-Control"] = "no-store" }
    end

    def connect
      provider = connection_provider
      # An account typed at Connect is accepted only on a CSRF-checked POST,
      # even when a host draws a GET route by hand.
      return head(:method_not_allowed) if provider.account_source == :connect && !request.post?

      back = connection_return_to(params[:return_to])
      return redirect_to(back, alert: connection_encryption_message) unless Studio::Connections.encryption_ready?

      account = nil
      if provider.account_source == :connect
        account = provider.normalize_account(params[provider.account_param]) or
          return redirect_to(back, alert: "That is not a #{provider.label} account. Check what you entered, then press Connect again.")
      end
      url = provider.authorize_url(redirect_uri: connection_callback_url, state: new_connection_state, account:)
      session[connection_session_key(:account)] = account
      session[connection_session_key(:return_to)] = back
      redirect_to url, allow_other_host: true
    rescue Studio::Connections::NotConfigured
      redirect_to back, alert: connection_keys_message
    end

    def callback
      provider = connection_provider
      expected = session.delete(connection_session_key(:state)).to_s
      kept_account = session.delete(connection_session_key(:account))
      back = connection_return_to(session.delete(connection_session_key(:return_to)))
      account = provider.account_source == :connect ? provider.normalize_account(kept_account) : nil
      unless connection_state_matches?(expected) && (provider.account_source != :connect || account)
        return render(plain: "OAuth state mismatch: start the connection again.", status: :bad_request)
      end

      return redirect_to(back, alert: connection_refusal(provider, params[:error].to_s)) if params[:error].present?
      return redirect_to(back, alert: connection_encryption_message) unless Studio::Connections.encryption_ready?

      problem = provider.callback_check&.call(params)
      return redirect_to(back, alert: problem.to_s) if problem.present?

      if provider.account_source == :callback
        account = provider.normalize_account(params[provider.account_param]) or
          return redirect_to(back, alert: "#{provider.label} came back without naming a valid account. Nothing was connected; start again.")
      end

      grant = {}
      if provider.grant == :authorization_code
        grant = rescue_and_log(target: current_user) do
          provider.exchange_code(code: params[:code].to_s, redirect_uri: connection_callback_url, account:)
        end
      end
      described = describe_connection(provider, grant, account)
      account ||= described[:account]
      return redirect_to(back, alert: "#{provider.label} answered, but did not say which account it was. Nothing was connected.") if account.blank?

      connection = rescue_and_log(target: current_user) do
        Studio::Connection.store!(provider, grant, account:, by: connection_actor,
                                                   label: described[:label], metadata: described[:metadata] || {})
      end
      redirect_to back, notice: "#{provider.label} connected: #{connection.label}."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to back, alert: "#{provider.label} answered, but the connection was not saved: #{e.record.errors.full_messages.to_sentence}."
    rescue Studio::Connections::InvalidAccount
      redirect_to back, alert: "#{provider.label} came back without naming a valid account. Nothing was connected; start again."
    rescue Studio::Connections::NotConfigured
      redirect_to back, alert: connection_keys_message
    rescue Studio::Connections::Error => e
      redirect_to back, alert: "#{provider.label} refused to exchange the sign-in code (#{e.message}). Start again: a code works once."
    end

    def disconnect
      provider = connection_provider
      back = connection_return_to(params[:return_to])
      connection = Studio::Connection.for_provider(provider.key).find_by(id: params[:id])
      return redirect_to(back, notice: "That #{provider.label} account was not connected, so nothing changed.", status: :see_other) unless connection

      label = connection.label
      revoked = revoke_connection(provider, connection)
      rescue_and_log(target: current_user) do
        provider.forget!(connection.account_id) if provider.refresh == :memory && connection.readable?
        connection.destroy!
      end
      Rails.logger.info("[studio_connection] disconnect provider=#{provider.key} row=#{connection.id} " \
                        "by=#{connection_actor} at=#{Time.current.utc.iso8601} revoked=#{revoked.inspect}")
      notice = case revoked
               when true then "#{provider.label} disconnected for #{label}: #{provider.label} revoked the grant and the stored connection was deleted here."
               when nil then "#{provider.label} disconnected for #{label}: the stored connection was deleted here. #{provider.revoke_note}"
               else "#{provider.label} disconnected for #{label}: the stored connection was deleted here, but #{provider.label} did not confirm the revoke. #{provider.revoke_note}"
               end
      redirect_to back, notice:, status: :see_other
    end

    private

    # The provider this request is for: the route's `studio_connection` default.
    def connection_provider
      @connection_provider ||= Studio::Connections.fetch(params[:studio_connection])
    end

    def connection_route = Studio::Connections.route(connection_provider.key)

    # A method guard refuses the way a before_action does: it renders or
    # redirects. A callable guard may do the same, or answer: false or nil
    # refuses with 403, so `->(c) { c.current_user&.admin? }` is safe.
    def require_connection_admin
      guard = Studio.connection_admin_guard
      return send(guard) unless guard.respond_to?(:call)

      allowed = guard.call(self)
      head(:forbidden) unless allowed || performed?
    end

    # Who connected it, as connected_by records: the user's slug, else their id.
    def connection_actor
      user = respond_to?(:current_user, true) ? current_user : nil
      return nil unless user

      (user.respond_to?(:slug) && user.slug.presence) || user.id.to_s
    end

    # The host's describe hook: { account:, label:, metadata: } for the account
    # just connected (a whoami, a company name). A provider error there is kept
    # in the error log and the connection stores under the provider's label.
    def describe_connection(provider, grant, account)
      return {} unless provider.describe

      rescue_and_log(target: current_user) do
        provider.describe.call(grant:, account:, provider:).to_h.symbolize_keys
      end
    rescue Studio::Connections::Error
      {}
    end

    # True when the provider took the revoke, nil when it has no revoke
    # endpoint, false when it refused or the row cannot be read.
    def revoke_connection(provider, connection)
      return nil unless provider.revocable?
      return false unless connection.readable?

      rescue_and_log(target: connection) { provider.revoke(connection) }
    rescue Studio::Connections::Error
      false
    end

    def connection_refusal(provider, code)
      return "The sign-in was declined on #{provider.label}. Nothing was connected." if provider.declined_errors.include?(code)

      "#{provider.label} refused the sign-in (#{code[0, 100]}). #{provider.refusal_hint}"
    end

    def connection_keys_message
      "#{connection_provider.label} connections are not set up on this server: #{connection_provider.env_names.join(' and ')} are not set."
    end

    def connection_encryption_message
      "This server cannot store a connection: its encryption keys are not set " \
        "(#{Studio::Connections::ENCRYPTION_ENV.join(', ')}). Nothing was asked of #{connection_provider.label}."
    end

    def connection_return_to(value)
      paths = connection_route.return_paths
      paths.include?(value) ? value : paths.first
    end

    def connection_callback_url = public_send(:"#{connection_route.as}_callback_url")

    def connection_session_key(name) = "studio_connection_#{connection_provider.key}_#{name}"

    def connection_state_matches?(expected)
      params[:state].present? && expected.present? &&
        ActiveSupport::SecurityUtils.secure_compare(params[:state].to_s, expected)
    end

    def new_connection_state
      SecureRandom.hex(16).tap { |state| session[connection_session_key(:state)] = state }
    end
  end
end
