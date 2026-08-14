# frozen_string_literal: true

require "digest"

module Studio
  # The four things every Studio app's User has had to define for itself: how to
  # name a person on screen, and how to draw them when they have no picture.
  #
  # WHY THIS EXISTS. The engine's own components/_avatar partial calls
  # `display_name`, `avatar_initials` and `avatar_color` — and the engine has
  # never provided any of them. Every consumer wrote its own; mcritchie-industries'
  # user.rb even carries a comment explaining that it must, because the engine's
  # nav renders the partial. Three copies, and by 2026-08-14 they had drifted:
  #
  #   mcritchie-studio      name → email prefix (capitalized) → wallet → "anon"
  #   mcritchie-industries  name → email prefix (raw)                  → "User"
  #   turf-monster          username → name → email prefix (cap) → wallet → "anon"
  #
  # Same intent, three answers, and two different words for the same empty state.
  # That is the drift a concern removes.
  #
  # ON THE MERGED CHAIN. It is turf-monster's — the richest of the three — with
  # `first_name` folded in after `name`, because /profile now lets people set that
  # field and a name someone just typed should be the name they see. Apps missing
  # a link in the chain simply skip it; the chain is respond_to?-guarded end to
  # end, so mcritchie-industries' eight-column users table walks it without
  # raising. One consequence worth stating rather than burying: an MI user with no
  # name now falls back to "anon" instead of "User", and an email-derived name is
  # capitalized. That is MI adopting the house standard, and its adoption task
  # owns the change.
  #
  # EVERY METHOD IS OVERRIDABLE. These are plain instance methods from an included
  # module, so a host that defines its own `display_name` in the class body wins
  # outright. Standardizing the default is the goal; forbidding an app from having
  # an opinion is not.
  module UserProfile
    extend ActiveSupport::Concern

    # The house palette for initial-circle backgrounds. Identical in all three
    # apps today, which is the clearest possible signal it belonged here.
    AVATAR_COLORS = %w[#EF4444 #F97316 #EAB308 #22C55E #06B6D4 #3B82F6 #8B5CF6 #EC4899].freeze

    # What to call this person on screen.
    def display_name
      studio_profile_username.presence ||
        studio_profile_attr(:name).presence ||
        studio_profile_attr(:first_name).presence ||
        studio_profile_email_prefix.presence ||
        studio_profile_wallet.presence ||
        "anon"
    end

    # One character for the initials circle. Deliberately NOT derived from
    # display_name: that chain ends in a wallet address or the word "anon", and
    # "a" for every anonymous account is worse than a neutral mark.
    def avatar_initials
      source = studio_profile_username.presence ||
               studio_profile_attr(:name).presence ||
               studio_profile_attr(:first_name).presence ||
               studio_profile_email_prefix.presence

      # `source[0]`, not ActiveSupport's `String#first`: this module is included
      # into a host model, and nothing here should depend on which core_ext that
      # host happens to have loaded. Plain Ruby costs nothing and cannot vanish.
      source.presence.to_s[0]&.upcase || "?"
    end

    # A stable colour for this account — same person, same circle, every render.
    # Hashed rather than random for exactly that reason, and keyed off identity
    # fields so it survives a display-name change.
    def avatar_color
      key = studio_profile_username.presence ||
            studio_profile_attr(:name).presence ||
            studio_profile_attr(:email).presence ||
            id.to_s

      AVATAR_COLORS[Digest::MD5.hexdigest(key.to_s).hex % AVATAR_COLORS.size]
    end

    private

    # Read an attribute only if this host's model actually has it. The whole
    # tolerance of the chain lives in this one method.
    def studio_profile_attr(attribute)
      return nil unless respond_to?(attribute)

      public_send(attribute)
    end

    # `username` is turf-monster's on-chain handle and does not exist in the hub
    # apps. It leads the chain where it exists because it is what that app's
    # people call each other.
    def studio_profile_username
      studio_profile_attr(:username)
    end

    def studio_profile_email_prefix
      email = studio_profile_attr(:email)
      return nil if email.blank?

      email.to_s.split("@").first.to_s.capitalize
    end

    # Defers to the host's own truncation rather than reformatting an address
    # here — mcritchie-studio and turf-monster both define `truncated_solana`,
    # and turf's has to pick between a web2 and a web3 address to do it.
    def studio_profile_wallet
      studio_profile_attr(:truncated_solana)
    end
  end
end
