# frozen_string_literal: true

module Studio
  # The engine-owned account contract (database audit 2026-11-07, section 3,
  # "Recommended primitive: Studio::Account"). One copy of the rules nine apps
  # typed by hand:
  #
  #   class User < ApplicationRecord
  #     include Studio::Account
  #     studio_roles %w[viewer admin]   # optional: narrow, never widen
  #
  #     def name_slug = name.to_s.parameterize   # Sluggable's, the host's own
  #   end
  #
  # It gives the host:
  #
  #   * `admin?` (role "admin") and a default `display_name`;
  #   * `normalizes :email`: stripped, downcased, and a blank address stored as
  #     NULL, so "" and " " never collide on the unique index or match a lookup;
  #   * `validates :role, inclusion:` against Studio::Roles, or the host's
  #     narrower list, with the default role filled on create;
  #   * Sluggable and Studio::OmniauthUser (the engine's Google find-or-create,
  #     with its race rescue);
  #   * one safe email lookup, `User.account_for_email(address)` and, for code
  #     that holds a model class rather than including this,
  #     `Studio::Account.find_by_email(User, address)`.
  #
  # THE NAME. The audit named the concern Studio::User. It cannot be: inside
  # `module Studio`, a bare `User` resolves to Studio::User before ::User, and
  # the engine reads the host's User bare in Studio::ErrorHandling#current_user,
  # Studio::LinkConsumption and Studio::LocalReviewsController. A Studio::User
  # constant would hand those the concern instead of the model.
  # test/integration/studio_account_test.rb holds that line.
  #
  # THE LOOKUP RULE (the account-takeover class the hub and Turf fixed on
  # 2026-11-08). `find_by(email: nil)` matches ANY account without an email:
  # every wallet and guest sign-up. So a blank address finds nobody, the match
  # is case-insensitive (`LOWER(email)`), and a lookup that LINKS a Google
  # identity to the account it finds takes Google's verification first.
  module Account
    extend ActiveSupport::Concern

    included do
      include Sluggable
      include Studio::OmniauthUser

      class_attribute :studio_role_list, instance_writer: false, default: Studio::Roles

      normalizes :email, with: ->(address) { Studio::Account.normalize_email(address) }

      before_validation :studio_fill_default_role, on: :create
      validates :role, inclusion: { in: ->(record) { record.class.studio_role_list } },
                       if: -> { has_attribute?(:role) }
    end

    class_methods do
      # Narrows the roles this app accepts. Every one must be in Studio::Roles:
      # a host cannot invent a role the engine does not know.
      def studio_roles(list)
        roles = Array(list).map(&:to_s).uniq
        raise ArgumentError, "studio_roles needs at least one role" if roles.empty?

        unknown = roles - Studio::Roles
        if unknown.any?
          raise ArgumentError, "studio_roles may only narrow Studio::Roles (#{Studio::Roles.join(', ')}); " \
                               "unknown: #{unknown.join(', ')}. Add a role to the engine, for every app."
        end

        self.studio_role_list = roles.freeze
      end

      # The role a new account takes: viewer, or the first of a list without it.
      def studio_default_role
        studio_role_list.include?(Studio::DEFAULT_ROLE) ? Studio::DEFAULT_ROLE : studio_role_list.first
      end

      # The account holding this address, or nil. A blank address finds nobody.
      def account_for_email(address)
        Studio::Account.find_by_email(self, address)
      end
    end

    class << self
      # "  Mia@Example.COM " -> "mia@example.com"; blank -> nil.
      def normalize_email(value)
        email = value.to_s.strip.downcase
        email.empty? ? nil : email
      end

      # The one safe lookup by address, for any model with an `email` column.
      # Blank finds nobody; the compare is LOWER(email), so a row stored before
      # `normalizes` still matches.
      def find_by_email(model, address)
        email = normalize_email(address)
        return nil if email.nil?
        return nil unless model.respond_to?(:attribute_names) && model.attribute_names.include?("email")

        model.where(model.arel_table[:email].lower.eq(email)).first
      end

      # The account a lost race left behind: a concurrent sign-in made the row
      # this one collided with. The Google id always identifies it; the address
      # only when Google verified it, because an unverified address proves
      # nothing about who holds the mailbox. Nobody found: the collision is
      # logged with ErrorLog.capture! and the answer is nil, never a stranger.
      def race_winner(model, provider:, uid:, email: nil, email_verified: false, error: nil)
        found = model.find_by(provider: provider, uid: uid) if provider.present? && uid.present?
        found ||= find_by_email(model, email) if email_verified
        return found if found

        log_unmatched_race(error)
        nil
      end

      private

      def log_unmatched_race(error)
        return unless error

        Rails.logger.warn("[studio account] sign-in collided with nobody to find: #{error.class}: #{error.message.to_s[0, 300]}")
        ErrorLog.capture!(error) if defined?(::ErrorLog) && ::ErrorLog.respond_to?(:capture!)
      rescue StandardError => e
        Rails.logger.warn("[studio account] could not log the collision: #{e.class}")
      end
    end

    def admin?
      role.to_s == "admin"
    end

    def display_name
      try(:name).presence || try(:email).to_s.split("@").first.presence || "User"
    end

    private

    def studio_fill_default_role
      return unless has_attribute?(:role) && role.blank?

      self.role = self.class.studio_default_role
    end
  end
end
