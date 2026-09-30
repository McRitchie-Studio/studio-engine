# frozen_string_literal: true

module Studio
  # The public user page's two rules, in one place: which account a /u/:username
  # URL names, and which username a link to an account carries.
  #
  # THE KEY IS `username` AND NOTHING ELSE. It is the one identity field a person
  # chose to show other people. The hub apps' `slug` is keyed on the email, and a
  # lookup by email would tell a stranger whether an address has an account, so
  # neither ever stands in: an app without a username column serves no public
  # pages (every lookup misses, every link helper answers nil) until it adds one.
  #
  # Pure lookups, no request: Studio::PublicUsersController and
  # Studio::PublicUserHelper both call these, so the page and the links to it
  # cannot disagree about what a username is.
  module PublicUser
    COLUMN = "username"

    module_function

    # Whether the host's User model can have a public page at all.
    def supported?(user_class = default_user_class)
      return false if user_class.nil?

      user_class.respond_to?(:column_names) && user_class.column_names.include?(COLUMN)
    rescue StandardError
      false
    end

    # The account a /u/:username URL names, or nil. Case-insensitive: /u/Alex
    # and /u/alex are the same page. An exact match wins first, because an app
    # whose lower(username) index is not unique (cyvasse's) can hold "Alex" and
    # "alex" as two people, and the one who is exactly named should get the page.
    #
    # A host that must hide an account (frozen, merged away, banned) defines
    # `public_profile_visible?` on User; false answers nil, the same miss an
    # unknown username gets, so the page never says why.
    def find(username, user_class: default_user_class)
      name = username.to_s.strip
      return nil if name.empty? || !supported?(user_class)

      user = user_class.find_by(COLUMN => name) ||
             user_class.where(user_class.arel_table[COLUMN].lower.eq(name.downcase)).order(:id).first
      return nil if user.nil?
      return nil if user.respond_to?(:public_profile_visible?) && !user.public_profile_visible?

      user
    end

    # The username a link to this account carries, or nil when it has none.
    # Takes a user, or a username string as given.
    def username_for(user_or_username)
      value = if user_or_username.is_a?(String) || user_or_username.is_a?(Symbol)
                user_or_username.to_s
              elsif user_or_username.respond_to?(COLUMN)
                user_or_username.public_send(COLUMN).to_s
              end
      value&.strip.presence
    end

    def default_user_class
      defined?(::User) ? ::User : nil
    end
  end
end
