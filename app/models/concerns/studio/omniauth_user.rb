# frozen_string_literal: true

require "securerandom"

module Studio
  # The engine's default Google find-or-create (docs/USER_CONTRACT.md, "Google
  # sign-in"), so an app signs people in with Google before it writes a line of
  # its own User code.
  #
  # OmniauthCallbacksController calls Studio::OmniauthUser.resolve(User, ...),
  # which uses the host's own User.from_omniauth when the class answers it and
  # this module's find_or_create otherwise. A host that wants the default under
  # its own name includes the concern; a host that defines `def
  # self.from_omniauth` in the class body overrides it either way, because a
  # method on the class itself is found before one from an extended module.
  #
  # The default, in order:
  #
  #   1. the account already holding this Google id (provider + uid);
  #   2. else the account holding the address, compared case-insensitively, but
  #      only when Google verified the address: an unverified match answers
  #      :email_not_verified, since it proves nothing about who holds the
  #      mailbox;
  #   3. else a new account, address downcased.
  #
  # THE SLUG COLLISION (Carl, 2026-10-29, on voicebox). The documented example
  # created a second "Mia" whose name_slug was "mia" again; the unique slug index
  # raised RecordNotUnique, the rescue looked for the address and the uid, found
  # nobody, and sign-in failed. So the create checks the slug first, and a slug
  # that is blank or already held becomes user-<id> (settled by Sluggable after
  # the insert). A collision that survives that, with nobody to find, is logged
  # with ErrorLog.capture! and answers nil, which the controller turns into a
  # "use another method" redirect rather than a 500.
  module OmniauthUser
    extend ActiveSupport::Concern

    class_methods do
      def from_omniauth(auth, email_verified: false)
        Studio::OmniauthUser.find_or_create(self, auth, email_verified: email_verified)
      end
    end

    class << self
      def resolve(model, auth, email_verified: false)
        if model.respond_to?(:from_omniauth)
          model.from_omniauth(auth, email_verified: email_verified)
        else
          find_or_create(model, auth, email_verified: email_verified)
        end
      end

      def find_or_create(model, auth, email_verified: false)
        provider = read(auth, "provider")
        uid = read(auth, "uid")
        return nil if provider.nil? || uid.nil?

        user = model.find_by(provider: provider, uid: uid)
        return user if user

        email = normalize_email(read(auth, "info", "email"))
        if email && (existing = find_by_email(model, email))
          return :email_not_verified unless email_verified

          existing.update!(provider: provider, uid: uid)
          return existing
        end

        attributes = { provider: provider, uid: uid, email: email, name: read(auth, "info", "name") }
        create_with_free_slug(model, attributes)
      end

      def normalize_email(value)
        email = value.to_s.strip.downcase
        email.empty? ? nil : email
      end

      def find_by_email(model, email)
        return nil unless column?(model, "email")

        model.where(model.arel_table[:email].lower.eq(email)).first
      end

      private

      def create_with_free_slug(model, attributes)
        assignable = attributes.select { |key, value| !value.nil? && column?(model, key.to_s) }
        last_error = nil

        [false, true].each do |force_fallback|
          record = model.new(assignable)
          install_fallback_slug(record) if force_fallback || slug_needs_fallback?(model, record)
          begin
            model.transaction(requires_new: true) { record.save! }
            return record
          rescue ActiveRecord::RecordNotUnique => e
            last_error = e
            # A concurrent sign-in made the row first: that row is the answer.
            found = (assignable[:email] && find_by_email(model, assignable[:email])) ||
                    model.find_by(provider: assignable[:provider], uid: assignable[:uid])
            return found if found
          end
        end

        log_unmatched_collision(last_error)
        nil
      end

      def slug_needs_fallback?(model, record)
        return false unless column?(model, "slug") && record.respond_to?(:name_slug, true)

        candidate = begin
          record.send(:name_slug).to_s
        rescue StandardError
          ""
        end
        candidate.strip.empty? || model.unscoped.where(slug: candidate).exists?
      end

      # user-<token> before the insert, user-<id> once the id exists: Sluggable
      # writes the first in before_save and settles the second after_create.
      def install_fallback_slug(record)
        token = SecureRandom.hex(4)
        record.define_singleton_method(:name_slug) { id ? "user-#{id}" : "user-#{token}" }
      end

      def log_unmatched_collision(error)
        return unless error

        Rails.logger.warn("[omniauth] Google sign-in collided with nobody to find: #{error.class}: #{error.message.to_s[0, 300]}")
        ErrorLog.capture!(error) if defined?(::ErrorLog) && ::ErrorLog.respond_to?(:capture!)
      rescue StandardError => e
        Rails.logger.warn("[omniauth] could not log the collision: #{e.class}")
      end

      def column?(model, name)
        model.respond_to?(:attribute_names) && model.attribute_names.include?(name)
      end

      def read(auth, *path)
        value = path.reduce(auth) do |node, key|
          break nil if node.nil?

          node.respond_to?(:[]) ? (node[key] || (node[key.to_sym] if node.is_a?(Hash))) : nil
        end
        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
