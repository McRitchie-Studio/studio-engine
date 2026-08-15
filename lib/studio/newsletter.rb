# frozen_string_literal: true

# The newsletter subscription's rules. Pure Ruby and duck-typed, like
# Studio::OauthIdentity and Studio::ProfileImage — it loads without Rails, takes
# any object that answers the readers, and the unit suite exercises it without
# booting the dummy app.
#
# TWO TIMESTAMPS, NOT A BOOLEAN, and this is the decision the rest of the file
# follows from. `joined_email_list_at` and `left_email_list_at` are lifted from
# turf-monster, which has run this shape in production, and the pair carries
# three states a boolean cannot:
#
#   never asked   both nil            — distinct from "unsubscribed"
#   subscribed    joined after left   — including a REJOIN, where both are set
#   unsubscribed  left after joined   — and the leave date survives the rejoin
#
# The third row is why turf keeps them: its 25-seed welcome bonus is once-ever,
# guarded on-chain, and "have they EVER joined" is a different question from "are
# they on the list today". A boolean answers neither. None of turf's seed
# machinery belongs in the engine — but the state shape does, because a consumer
# that adopts this and later wants that rule must not have to migrate away from a
# flag first.
module Studio
  module Newsletter
    module_function

    # The columns a host must have for any of this to mean anything. The profile
    # row declares the same pair in `requires:`, so a host without them silently
    # gets no newsletter card rather than a NoMethodError on every page load.
    COLUMNS = %i[joined_email_list_at left_email_list_at].freeze

    def serves?(user)
      return false if user.nil?

      COLUMNS.all? { |column| user.respond_to?(column) }
    end

    # On the list right now.
    #
    # `joined > left` rather than `left.nil?`, because a REJOIN leaves both set
    # and the later date wins. Reading only `left_email_list_at.nil?` would call
    # every rejoined account unsubscribed forever.
    def subscribed?(user)
      return false unless serves?(user)

      joined = user.joined_email_list_at
      return false if joined.nil?

      left = user.left_email_list_at
      left.nil? || joined > left
    end

    # Has this account EVER been on the list? Distinct from `subscribed?`, and the
    # question a once-ever welcome bonus asks. The engine does not pay bonuses; it
    # answers the question so a consumer that does never has to reach past this
    # module into the columns.
    def ever_joined?(user)
      serves?(user) && !user.joined_email_list_at.nil?
    end

    # A newsletter needs somewhere to send. An account with no address on file —
    # a wallet-only sign-in, which turf-monster has plenty of — has to supply one
    # before it can subscribe, so the UI asks rather than failing the submit.
    def needs_email?(user)
      return false unless serves?(user)

      !user.respond_to?(:email) || user.email.to_s.strip.empty?
    end
  end
end
