# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/object/try"
require_relative "../../../app/models/concerns/studio/user_profile"

# [unit] Studio::UserProfile — the display-name and avatar helpers every consumer
# had written for itself, now written once.
#
# THE WHOLE POINT IS TOLERANCE. The three apps' users tables genuinely disagree:
# mcritchie-industries has eight columns (no first_name, no username, no wallet),
# turf-monster has forty. The engine's components/_avatar partial calls all three
# of these methods on every signed-in render in every app, so a chain that
# assumed a column would take a hub app's entire navbar down.
#
# Each test below builds a model shaped like a REAL app rather than a convenient
# one, because "works on a model with every field" is exactly the assumption that
# breaks mcritchie-industries.
class UserProfileTest < Minitest::Test
  # Shaped like mcritchie-industries: name, email, id. Nothing else.
  class ThinUser
    include Studio::UserProfile
    attr_accessor :name, :email
    def initialize(name: nil, email: nil) = (@name, @email = name, email)
    def id = 7
  end

  # Shaped like mcritchie-studio: adds first_name and a wallet.
  class HubUser
    include Studio::UserProfile
    attr_accessor :name, :email, :first_name, :truncated_solana
    def initialize(**attrs) = attrs.each { |k, v| public_send("#{k}=", v) }
    def id = 8
  end

  # Shaped like turf-monster: adds a username, which leads the chain.
  class TurfUser
    include Studio::UserProfile
    attr_accessor :name, :email, :first_name, :username, :truncated_solana
    def initialize(**attrs) = attrs.each { |k, v| public_send("#{k}=", v) }
    def id = 9
  end

  # --- tolerance: the reason this concern is shaped the way it is --------------

  # REGRESSION GUARD. mcritchie-industries' model answers none of username,
  # first_name or truncated_solana. Every one of these methods runs on every
  # signed-in render there (components/_avatar), so a NoMethodError here is a
  # dead navbar in a live app, not a test failure.
  def test_a_thin_model_walks_the_whole_chain_without_raising
    user = ThinUser.new(name: nil, email: nil)

    assert_equal "anon", user.display_name
    assert_equal "?",    user.avatar_initials
    assert_includes Studio::UserProfile::AVATAR_COLORS, user.avatar_color
  end

  def test_a_thin_model_still_uses_what_it_does_have
    assert_equal "Ada Lovelace", ThinUser.new(name: "Ada Lovelace").display_name
    assert_equal "Ada",          ThinUser.new(email: "ada@example.com").display_name
  end

  # --- the merged chain -------------------------------------------------------

  def test_username_leads_where_it_exists
    user = TurfUser.new(username: "turfking", name: "Pat Smith", email: "pat@example.com")

    assert_equal "turfking", user.display_name
  end

  def test_name_beats_first_name
    user = HubUser.new(name: "Pat Smith", first_name: "Pat", email: "pat@example.com")

    assert_equal "Pat Smith", user.display_name
  end

  def test_first_name_is_used_when_name_is_blank
    # The reason first_name is in the chain at all: /profile now lets someone set
    # this field, and a name they just typed should be the name they see.
    user = HubUser.new(name: "", first_name: "Pat", email: "pat@example.com")

    assert_equal "Pat", user.display_name
  end

  def test_email_prefix_is_capitalized
    # mcritchie-studio and turf-monster both capitalized; mcritchie-industries did
    # not. The standard capitalizes, and MI's adoption task owns that change.
    assert_equal "Pat", HubUser.new(email: "pat@example.com").display_name
  end

  def test_wallet_is_the_last_identity_before_the_fallback
    user = HubUser.new(truncated_solana: "7ZDJ…9Tcr")

    assert_equal "7ZDJ…9Tcr", user.display_name
  end

  def test_the_fallback_is_anon
    assert_equal "anon", HubUser.new.display_name
  end

  # --- initials ---------------------------------------------------------------

  # Deliberately NOT derived from display_name: that chain ends in a wallet
  # address or the literal word "anon", so deriving would stamp "7" or "A" on
  # every anonymous account. A neutral mark is the honest answer.
  def test_initials_do_not_fall_through_to_the_wallet_or_the_word_anon
    assert_equal "?", HubUser.new(truncated_solana: "7ZDJ…9Tcr").avatar_initials
    assert_equal "?", HubUser.new.avatar_initials
  end

  def test_initials_come_from_the_identity_fields
    assert_equal "T", TurfUser.new(username: "turfking", name: "Pat").avatar_initials
    assert_equal "P", HubUser.new(name: "pat smith").avatar_initials
    assert_equal "P", HubUser.new(first_name: "pat").avatar_initials
    assert_equal "P", HubUser.new(email: "pat@example.com").avatar_initials
  end

  # --- colour -----------------------------------------------------------------

  def test_colour_is_stable_for_the_same_identity
    a = HubUser.new(name: "Pat Smith")
    b = HubUser.new(name: "Pat Smith")

    assert_equal a.avatar_color, b.avatar_color
  end

  def test_colour_is_always_from_the_house_palette
    [ThinUser.new, HubUser.new(name: "Pat"), TurfUser.new(username: "x")].each do |user|
      assert_includes Studio::UserProfile::AVATAR_COLORS, user.avatar_color
    end
  end

  def test_colour_falls_back_to_the_id_for_an_identity_less_account
    # Must not raise on Digest::MD5.hexdigest(nil).
    assert_includes Studio::UserProfile::AVATAR_COLORS, ThinUser.new.avatar_color
  end

  # --- the override seam ------------------------------------------------------

  # Standardizing the DEFAULT is the goal; forbidding an app from having an
  # opinion is not. These are plain instance methods from an included module, so
  # a host defining its own in the class body wins outright.
  def test_a_host_can_override_any_of_them
    klass = Class.new do
      include Studio::UserProfile
      def name = "Pat Smith"
      def display_name = "THE HOST'S ANSWER"
      def id = 1
    end

    assert_equal "THE HOST'S ANSWER", klass.new.display_name
    assert_equal "P", klass.new.avatar_initials, "the un-overridden ones still work"
  end

  # --- the palette itself -----------------------------------------------------

  def test_the_palette_matches_what_the_apps_already_shipped
    # All three consumers carried this exact array, which is the clearest
    # possible signal it belonged in the engine. Changing it recolours every
    # existing avatar in every app, so it changes deliberately or not at all.
    assert_equal %w[#EF4444 #F97316 #EAB308 #22C55E #06B6D4 #3B82F6 #8B5CF6 #EC4899],
                 Studio::UserProfile::AVATAR_COLORS
  end
end
