# frozen_string_literal: true

require "test_helper"
require "studio/link_resolution"

# [unit] The magic-link click decision table, cell by cell.
#
# The operator's rules, in his words, and where each is pinned below:
#
#   "when I use a magic link for a second time it breaks my session" →
#       test_a_dead_link_never_touches_the_session (the invariant, swept over
#       every dead cell rather than spot-checked)
#   "if it's for the same user with the active session, just continue without
#    complication ... just treat it as a redirect" →
#       test_own_live_link_continues_without_reauthenticating
#       test_own_dead_link_is_a_silent_redirect
#   "if the magic link isn't active anymore, also don't mess with the current
#    session ... just present a notification message with the details" →
#       test_someone_elses_dead_link_keeps_the_session_and_explains
#   "if the magic link is for a different user, then the frontend should
#    overwrite the session ... unless the link is expired" →
#       test_someone_elses_live_link_takes_over_the_session
class StudioLinkResolutionTest < Minitest::Test
  OWNER   = "owner@example.com"
  OTHER   = "someone-else@example.com"
  DEAD    = %i[used expired unknown].freeze

  def resolve(status:, link_email: OWNER, session_email: nil)
    Studio::LinkResolution.call(status: status, link_email: link_email, session_email: session_email)
  end

  # --- the invariant ---------------------------------------------------------

  # THE rule the rewrite exists for. Swept across every dead cell (three
  # statuses x three seats) rather than spot-checked, because the bug was not
  # one branch getting it wrong — it was every branch funnelling into the same
  # `redirect_to login_path` no matter who was signed in.
  def test_a_dead_link_never_touches_the_session
    seats = [nil, OWNER, OTHER]
    emails = [OWNER, nil]

    DEAD.each do |status|
      seats.each do |seat|
        emails.each do |link_email|
          outcome = resolve(status: status, link_email: link_email, session_email: seat)
          assert_equal :dead, outcome.action,
                       "status=#{status} link=#{link_email.inspect} seat=#{seat.inspect} must not authenticate"
          refute outcome.authenticate?
          refute outcome.continue?
        end
      end
    end
  end

  # A signed-in visitor is never sent to the sign-in page by a dead link. That
  # redirect IS the reported symptom: the cookie survived, but the destination
  # said "logged out", and the visitor believed the destination.
  def test_a_signed_in_visitor_is_never_bounced_to_login
    DEAD.each do |status|
      [OWNER, OTHER, nil].each do |link_email|
        outcome = resolve(status: status, link_email: link_email, session_email: OWNER)
        refute_equal :login, outcome.destination,
                     "status=#{status} link=#{link_email.inspect}: a held session must not land on login"
      end
    end
  end

  # --- the viewer's own link -------------------------------------------------

  def test_own_live_link_continues_without_reauthenticating
    outcome = resolve(status: :claimed, session_email: OWNER)

    assert_equal :continue, outcome.action
    assert_equal :return_to, outcome.destination
    assert outcome.silent?, "a re-click on your own link must say nothing — it is just a redirect"
  end

  def test_own_dead_link_is_a_silent_redirect
    %i[used expired].each do |status|
      outcome = resolve(status: status, session_email: OWNER)

      assert_equal :dead, outcome.action
      assert_equal :return_to, outcome.destination, "land where the link pointed, as a plain link would"
      assert outcome.silent?, "#{status}: no scary alert for your own spent link"
      assert_nil outcome.level
    end
  end

  # Case-and-whitespace differences in an email are the same person. A link
  # minted from a typed-in "  Owner@Example.COM  " must still read as the
  # session's own, or the silent path silently stops applying.
  def test_own_link_matching_ignores_case_and_surrounding_space
    outcome = resolve(status: :used, link_email: "  Owner@Example.COM  ", session_email: OWNER)

    assert outcome.silent?
    assert_equal :return_to, outcome.destination
  end

  # --- somebody else's link --------------------------------------------------

  def test_someone_elses_live_link_takes_over_the_session
    outcome = resolve(status: :claimed, link_email: OTHER, session_email: OWNER)

    assert_equal :authenticate, outcome.action,
                 "a live link is proof of ownership, so it outranks the open session"
    assert_equal :return_to, outcome.destination
  end

  def test_someone_elses_dead_link_keeps_the_session_and_explains
    outcome = resolve(status: :expired, link_email: OTHER, session_email: OWNER)

    assert_equal :dead, outcome.action
    assert_equal :home, outcome.destination,
                 "another user's destination is not ours to follow"
    assert_equal :notice, outcome.level
    assert_includes outcome.message, OTHER, "the notice must name the address the link was for"
    assert_includes outcome.message, "has expired", "...and why it failed"
    assert_includes outcome.message, OWNER, "...and reassure them their own session survived"
  end

  # --- nobody signed in ------------------------------------------------------

  def test_a_live_link_signs_in_a_visitor_with_no_session
    outcome = resolve(status: :claimed, session_email: nil)

    assert_equal :authenticate, outcome.action
    assert_equal :return_to, outcome.destination
  end

  def test_a_dead_link_sends_a_signed_out_visitor_to_login
    outcome = resolve(status: :used, session_email: nil)

    assert_equal :dead, outcome.action
    assert_equal :login, outcome.destination
    assert_equal :alert, outcome.level
    assert_includes outcome.message, "Request a fresh one"
  end

  # --- an unrecognized token -------------------------------------------------

  # A token with no row behind it carries no email. It must NOT read as "your
  # own link" just because nobody is signed in to compare it against — that
  # would make a garbage token silent instead of explained.
  def test_an_unknown_token_is_never_mistaken_for_your_own
    refute Studio::LinkResolution.own_link?(nil, nil)
    refute Studio::LinkResolution.own_link?(nil, OWNER)
    refute Studio::LinkResolution.own_link?(OWNER, nil)
    refute Studio::LinkResolution.own_link?("", "")

    outcome = resolve(status: :unknown, link_email: nil, session_email: OWNER)
    refute outcome.silent?, "an unrecognized token must be explained, not swallowed"
    assert_equal :home, outcome.destination
  end

  def test_an_unknown_token_message_names_no_address
    message = Studio::LinkResolution.dead_message(status: :unknown, link_email: nil)

    assert_includes message, "is no longer valid"
    refute_includes message, " for ", "there is no address to name when the token is unrecognized"
  end

  # --- messages --------------------------------------------------------------

  def test_each_dead_status_says_what_actually_happened
    assert_includes Studio::LinkResolution.dead_message(status: :expired, link_email: OWNER), "has expired"
    assert_includes Studio::LinkResolution.dead_message(status: :used, link_email: OWNER), "was already used"
    assert_includes Studio::LinkResolution.dead_message(status: :unknown, link_email: OWNER), "is no longer valid"
  end

  # --- the contract ----------------------------------------------------------

  def test_an_unrecognized_status_raises_rather_than_guessing
    error = assert_raises(ArgumentError) { resolve(status: :probably_fine) }
    assert_includes error.message, "unknown status"
  end

  # Guards the sweep above: if ACTIONS/STATUSES ever grow a member the table
  # does not handle, the loops would still pass while covering less.
  def test_every_declared_status_resolves_to_a_declared_action
    Studio::LinkResolution::STATUSES.each do |status|
      [nil, OWNER, OTHER].each do |seat|
        outcome = resolve(status: status, session_email: seat)
        assert_includes Studio::LinkResolution::ACTIONS, outcome.action
        assert_includes Studio::LinkResolution::DESTINATIONS, outcome.destination
      end
    end
  end
end
