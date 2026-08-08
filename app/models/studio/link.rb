module Studio
  # One table, one /l/<token> entry point, for every short-token link the apps
  # hand out: single-use, expiring **magic_link**s and reusable, non-expiring
  # **referral** links. `kind` selects the behavior; `metadata` (jsonb) carries
  # the kind-specific payload (email, return_to, target, age_attested) OFF the
  # wire so the URL is just the short random token.
  #
  # Generalizes turf-monster's app-local MagicLink model: adds a polymorphic
  # `linkable` owner (the inviting User for referrals; left nil for a magic link
  # to a not-yet-existent email — that email rides in metadata) and the `kind`
  # discriminator. Replaces the engine's stateless MessageVerifier MagicLink
  # service for mcritchie-studio so both apps share one short-token scheme.
  #
  # Like Studio::EmailDelivery, the table lives in each consumer app (copy the
  # reference migration in db/migrate); this model is shipped by the gem.
  class Link < ApplicationRecord
    self.table_name = "studio_links"

    class InvalidToken < StandardError; end

    belongs_to :linkable, polymorphic: true, optional: true

    validates :kind, inclusion: { in: Studio::LinkToken::KINDS }
    validates :token, presence: true, uniqueness: true

    scope :magic_links, -> { where(kind: "magic_link") }
    scope :referrals,   -> { where(kind: "referral") }
    scope :unconsumed,  -> { where(consumed_at: nil) }
    scope :live,        -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }

    class << self
      # --- minting -----------------------------------------------------------

      # A single-use sign-in/sign-up link. The email rides in metadata (not the
      # URL, not a column) per the create-or-login flow — the account may not
      # exist yet. `ttl` defaults to the app's Studio.magic_link_ttl.
      def create_magic_link(email:, return_to: nil, age_attested: false, linkable: nil, ttl: nil)
        ttl ||= Studio.magic_link_ttl
        mint!(
          kind: "magic_link",
          linkable: linkable,
          expires_at: ttl.from_now,
          metadata: {
            "email"        => Studio::LinkToken.normalize_email(email),
            "return_to"    => Studio::LinkToken.sanitize_path(return_to),
            "age_attested" => !!age_attested
          }.compact
        )
      end

      # A user's referral link is stable + reusable, keyed by its landing target
      # so sharing contest A vs B yields distinct (but each stable) links — both
      # crediting the same inviter. `target` is an optional same-origin path the
      # referral redirects to (e.g. a specific contest).
      def referral_for(linkable, target: nil)
        wanted = Studio::LinkToken.sanitize_path(target)
        referrals.where(linkable: linkable).live.detect { |link| link.target == wanted } ||
          mint!(
            kind: "referral",
            linkable: linkable,
            expires_at: nil,
            metadata: { "target" => wanted }.compact
          )
      end

      # Find by token + burn-if-single-use in one call. Raises InvalidToken for
      # unknown / expired / already-used links. Returns the live Link.
      def consume!(token)
        link = find_by(token: token.to_s)
        raise InvalidToken, "unknown link" unless link

        link.consume!
      end

      private

      # create! with a fresh random token, retrying the (astronomically rare)
      # unique-index collision a couple of times before surfacing the error.
      def mint!(attrs)
        3.times do
          return create!(attrs.merge(token: Studio::LinkToken.generate))
        rescue ActiveRecord::RecordNotUnique
          next
        end
        create!(attrs.merge(token: Studio::LinkToken.generate))
      end
    end

    # --- consumption ---------------------------------------------------------

    # Single-use kinds (magic_link) are atomically burned: only the first caller
    # flips consumed_at, so a replay / double-submit loses the race and is
    # rejected. Reusable kinds (referral) only check expiry. Returns self.
    def consume!
      if single_use?
        burned = self.class.unconsumed
                     .where(id: id)
                     .where("expires_at IS NULL OR expires_at > ?", Time.current)
                     .update_all(consumed_at: Time.current)
        raise InvalidToken, "link already used or expired" if burned.zero?

        self.consumed_at = Time.current
      elsif expired?
        raise InvalidToken, "link expired"
      end
      self
    end

    # The non-raising sibling of #consume!, and the one the click flow uses.
    # Returns whether THIS caller won the burn — false for a link that was
    # already used, has expired, or lost the atomic race to a concurrent click.
    #
    # Why a boolean and not the exception: "the link was dead" is not an error
    # here, it is one of the two normal outcomes, and the branch it feeds
    # (Studio::LinkResolution) needs the answer as data. Reloads on a loss so
    # the caller reads the row's settled state (consumed_at / expires_at) rather
    # than the copy it held before the race.
    def burn
      consume!
      true
    rescue InvalidToken
      reload
      false
    end

    # How a failed burn should be described. Only meaningful once #burn has
    # returned false (or on a link that was never burned at all).
    def dead_status
      return :used if single_use? && consumed?
      return :expired if expired?

      # Neither flag is set but the burn did not land: a concurrent click won
      # it between our read and our write. Same story for the reader.
      :used
    end

    def single_use?
      Studio::LinkToken.single_use?(kind)
    end

    def expired?
      expires_at.present? && expires_at <= Time.current
    end

    def consumed?
      consumed_at.present?
    end

    def live?
      !expired? && !(single_use? && consumed?)
    end

    # --- metadata readers (sanitized on the way out) -------------------------

    def email
      metadata && metadata["email"]
    end

    def return_to
      Studio::LinkToken.sanitize_path(metadata && metadata["return_to"])
    end

    def target
      Studio::LinkToken.sanitize_path(metadata && metadata["target"])
    end

    def age_attested
      !!(metadata && metadata["age_attested"])
    end
    alias_method :age_attested?, :age_attested
  end
end
