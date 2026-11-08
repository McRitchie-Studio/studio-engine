# frozen_string_literal: true

module Studio
  # One third-party account a host app has connected over OAuth 2.0, for a
  # provider the host declared with Studio.define_connection
  # (Studio::Connections::Provider). docs/CONNECTIONS.md.
  #
  # One row per provider and account (account_key, unique within a provider).
  # Connecting the same account again replaces its tokens (.store!). No token,
  # and no part of one, is ever shown: every token column is encrypted, filtered
  # from inspect, and read only by the provider's access_token.
  #
  # THE ROW DEPENDS ON THE APP'S ENCRYPTION KEYS: without them a connect refuses
  # before it asks the provider for anything
  # (Studio::Connections.encryption_ready?); with them lost or changed, a stored
  # row is unreadable (#readable? is false), counts as not connected, and
  # connecting again replaces it.
  #
  # ROTATION. #rotate! is called by the provider inside #with_lock, which
  # reloads the row first: a racing caller waits, then spends the NEWEST
  # refresh token, and the answered token is stored before the access token it
  # came with is used.
  class Connection < ApplicationRecord
    self.table_name = "studio_connections"

    encrypts :access_token, :refresh_token, :account_secret
    self.filter_attributes += %i[access_token refresh_token account_secret account_key]

    validates :provider, :account_key, :connected_at, presence: true
    validates :account_key, uniqueness: { scope: :provider }
    validate :holds_what_its_policy_needs

    scope :for_provider, ->(key) { where(provider: key.to_s) }

    class << self
      def encryption_ready? = Studio::Connections.encryption_ready?

      def newest_first = order(connected_at: :desc, id: :desc)

      # Every connection of a provider whose tokens this server can read, newest first.
      def readable(provider) = for_provider(provider).newest_first.select(&:readable?)

      # Stores the account a connect reached. `grant` is the token endpoint's
      # JSON ({} for a client-credentials consent). Raises InvalidAccount for an
      # account that fails the provider's format, and RecordInvalid when the
      # answer lacks what the provider's policy keeps; the message names the
      # field, never a value.
      def store!(provider, grant, account:, by:, label: nil, metadata: {}, now: Time.current)
        provider = Studio::Connections.fetch(provider) unless provider.is_a?(Studio::Connections::Provider)
        account = provider.normalize_account(account) or raise Studio::Connections::InvalidAccount, "not a #{provider.label} account"
        key = provider.account_key_for(account)

        transaction(requires_new: true) do
          connection = find_or_initialize_by(provider: provider.key, account_key: key)
          # A row whose tokens can no longer be read is replaced, not updated.
          unless connection.new_record? || connection.readable?
            where(id: connection.id).delete_all
            connection = new(provider: provider.key, account_key: key)
          end
          keep_access = provider.refresh == :cached
          connection.assign_attributes(
            account_secret: provider.private_account ? account : nil,
            label: label.to_s.strip.presence || provider.label,
            access_token: keep_access ? grant["access_token"].to_s.presence : nil,
            refresh_token: provider.refresh == :memory ? nil : grant["refresh_token"].to_s.presence,
            access_expires_at: keep_access ? Studio::Connections::Provider.expiry(grant, "expires_in", now) : nil,
            refresh_expires_at: Studio::Connections::Provider.expiry(grant, provider.refresh_expires_in_key, now),
            metadata: metadata.to_h.deep_stringify_keys, connected_by: by.to_s.presence, connected_at: now,
            last_refreshed_at: nil
          )
          connection.save!
          connection
        end
      end
    end

    def provider_definition = Studio::Connections.fetch(provider)

    # The account as the provider names it: the decrypted id for a private
    # account, else the key itself.
    def account_id = account_secret.presence || account_key

    # An access token, by the provider's refresh policy. `stale:` is a token the
    # API just refused with a 401 (the :cached policy refreshes it).
    def fresh_access_token(stale: nil) = provider_definition.access_token(self, stale:)

    # Can the stored tokens be decrypted with this app's keys?
    def readable?
      access_token
      refresh_token
      account_secret
      true
    rescue ActiveRecord::Encryption::Errors::Base
      false
    end

    # Is the stored access token good for longer than the provider's margin? A
    # token with no expiry is, until the provider refuses it.
    def access_fresh?(now = Time.current)
      return false if access_token.blank?

      access_expires_at.nil? || access_expires_at > now + provider_definition.refresh_margin
    end

    # Stores what a refresh just answered. Called inside #with_lock by the
    # provider, before the access token is used. A provider whose rotation is
    # :required refuses an answer without a refresh token (storing nothing would
    # lose the account); otherwise a blank one keeps the stored one.
    def rotate!(grant, now: Time.current)
      definition = provider_definition
      answered = grant["refresh_token"].to_s.presence
      if answered.nil? && definition.rotation == :required
        raise Studio::Connections::Error, "#{definition.label} answered a refresh with no refresh token; connect again"
      end

      changes = { refresh_token: answered || refresh_token, last_refreshed_at: now,
                  refresh_expires_at: Studio::Connections::Provider.expiry(grant, definition.refresh_expires_in_key, now) || refresh_expires_at }
      if definition.refresh == :cached
        raise Studio::Connections::Error, "#{definition.label} answered a refresh with no access token" if grant["access_token"].blank?

        changes.merge!(access_token: grant["access_token"], access_expires_at: Studio::Connections::Provider.expiry(grant, "expires_in", now))
      end
      update!(changes)
    end

    private

    def holds_what_its_policy_needs
      definition = Studio::Connections.defined?(provider) ? Studio::Connections.fetch(provider) : nil
      return errors.add(:provider, "is not a defined connection provider") unless definition

      errors.add(:refresh_token, :blank) if definition.refresh == :rotating && refresh_token.blank?
      errors.add(:access_token, :blank) if definition.refresh == :cached && access_token.blank?
      errors.add(:account_secret, :blank) if definition.private_account && account_secret.blank?
    end
  end
end
