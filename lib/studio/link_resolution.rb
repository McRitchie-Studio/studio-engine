# frozen_string_literal: true

require_relative "link_token"

module Studio
  # What a magic-link click should DO — the whole decision as one pure table,
  # free of ActiveRecord and of the controller, so every cell is unit-testable.
  #
  # A click has three inputs: whether this caller BURNED the link (won the
  # single-use race), whose email the link carries, and who is already signed
  # in. Six cells fall out of that, and one invariant runs through them:
  #
  #   **A dead link never touches the session.**
  #
  # Before this table, every dead token — used, expired, or unknown — ended at
  # `redirect_to login_path, alert: "invalid or has expired"`, whatever session
  # the visitor was holding. So clicking your own link a second time dumped you
  # on a sign-in page, which reads as being logged out. It never was: the cookie
  # survived, but the destination said otherwise. Now a dead link is at worst a
  # notice, and at best silent.
  #
  # The table (rows = link state, columns = who is signed in):
  #
  #                | nobody          | the link's own user | somebody else
  #   -------------+-----------------+---------------------+------------------
  #   live (burned)| :authenticate   | :continue           | :authenticate
  #   used/expired | :dead → login   | :dead → return_to   | :dead → home
  #   unknown token| :dead → login   |         —           | :dead → home
  #
  # `:continue` is the cell the operator asked for by name: a second click on
  # your own still-live link must be "no material difference — just a redirect".
  # It burns the token (so nobody replays it later) and deliberately does NOT
  # re-authenticate, because a host that rotates the session on sign-in — as
  # turf-monster does — would otherwise charge a re-click the price of every
  # scrap of session state the visitor had built up.
  module LinkResolution
    # How the click found the link.
    #   :claimed — this caller burned a live link (the only status that authenticates)
    #   :used    — the row exists and was already consumed, or lost the burn race
    #   :expired — the row exists and is past expires_at
    #   :unknown — no row for this token, or the token is not a magic link
    STATUSES = %i[claimed used expired unknown].freeze

    # :authenticate — establish a session for the link's email (sign in or sign up)
    # :continue     — the viewer already IS the link's user: keep the session as
    #                 it stands and land them on the link's destination
    # :dead         — do not touch the session at all
    ACTIONS = %i[authenticate continue dead].freeze

    # Where the click lands.
    #   :return_to — the link's own destination (falling back to home)
    #   :home      — the app root; used when the link belongs to someone else,
    #                so its destination is not ours to follow
    #   :login     — the sign-in page; only ever for a visitor with no session
    DESTINATIONS = %i[return_to home login].freeze

    Outcome = Struct.new(:action, :destination, :message, :level, keyword_init: true) do
      def authenticate?
        action == :authenticate
      end

      def continue?
        action == :continue
      end

      def dead?
        action == :dead
      end

      # A silent outcome shows the visitor nothing — the "no material
      # difference" re-click.
      def silent?
        message.nil?
      end
    end

    module_function

    # @param status [Symbol] one of STATUSES
    # @param link_email [String, nil] the email the link signs in (nil = unknown token)
    # @param session_email [String, nil] the currently signed-in user's email
    # @return [Outcome]
    def call(status:, link_email: nil, session_email: nil)
      raise ArgumentError, "unknown status #{status.inspect}" unless STATUSES.include?(status)

      own = own_link?(link_email, session_email)

      if status == :claimed
        return Outcome.new(action: :continue, destination: :return_to) if own

        # Nobody signed in, or somebody else signed in: both establish a session
        # for the link's email. The second case is the deliberate account switch
        # — a live link is proof of ownership, so it outranks the open session.
        return Outcome.new(action: :authenticate, destination: :return_to)
      end

      # Dead from here down: no branch below may write to the session.
      return Outcome.new(action: :dead, destination: :return_to) if own

      if Studio::LinkToken.normalize_email(session_email).empty?
        Outcome.new(action: :dead, destination: :login, level: :alert,
                    message: dead_message(status: status, link_email: link_email))
      else
        Outcome.new(action: :dead, destination: :home, level: :notice,
                    message: dead_message(status: status, link_email: link_email,
                                          session_email: session_email))
      end
    end

    # Same email, both sides present. A blank on either side is never a match —
    # an unknown token (no email) must not read as "your own link" just because
    # nobody is signed in.
    def own_link?(link_email, session_email)
      link = Studio::LinkToken.normalize_email(link_email)
      seat = Studio::LinkToken.normalize_email(session_email)
      !link.empty? && link == seat
    end

    # The notice a dead link earns. It names the address the link was for and
    # why it failed — the detail that turns "something went wrong" into a
    # decision the reader can act on — and, when a session is open, says so
    # plainly, because the whole point is that nothing was lost.
    def dead_message(status:, link_email: nil, session_email: nil)
      addressee = Studio::LinkToken.normalize_email(link_email)
      who = addressee.empty? ? "" : " for #{addressee}"
      why = case status
            when :expired then "has expired"
            when :used    then "was already used"
            else               "is no longer valid"
            end

      base = "That sign-in link#{who} #{why}."
      seat = Studio::LinkToken.normalize_email(session_email)
      return "#{base} Request a fresh one below." if seat.empty?

      "#{base} You are still signed in as #{seat} — request a fresh link to switch accounts."
    end
  end
end
