# frozen_string_literal: true

require "test_helper"
require "studio/newsletter"

# [unit] The newsletter's state rules.
#
# THE WHOLE POINT OF THIS FILE is that "subscribed" is DERIVED from two dates
# rather than stored as a flag, and every interesting case is a pair of dates
# rather than a boolean. A test suite that only checked "joined ⇒ subscribed"
# would miss the rejoin, which is the case the two-column shape exists for.
class NewsletterTest < Minitest::Test
  # Duck-typed on purpose — the module takes anything that answers the readers,
  # which is what lets the unit suite run without a database or a User class.
  Account = Struct.new(:joined_email_list_at, :left_email_list_at, :email, keyword_init: true)

  # A model whose table predates the columns. Every consumer was in this state
  # until the standard-columns rollout, and three still are.
  NoColumns = Struct.new(:email, keyword_init: true)

  def account(**attrs) = Account.new(**{ email: "pat@example.com" }.merge(attrs))

  # --- serves? -----------------------------------------------------------------

  def test_a_model_without_the_columns_is_not_served
    refute Studio::Newsletter.serves?(NoColumns.new(email: "pat@example.com"))
  end

  def test_no_user_is_not_served
    refute Studio::Newsletter.serves?(nil)
  end

  # --- subscribed? -------------------------------------------------------------

  def test_never_joined_is_not_subscribed
    refute Studio::Newsletter.subscribed?(account)
  end

  def test_joined_and_never_left_is_subscribed
    assert Studio::Newsletter.subscribed?(account(joined_email_list_at: Time.at(1_700_000_000)))
  end

  def test_left_after_joining_is_not_subscribed
    subject = account(joined_email_list_at: Time.at(1_700_000_000),
                      left_email_list_at: Time.at(1_700_000_100))

    refute Studio::Newsletter.subscribed?(subject)
  end

  # THE CASE THE TWO-COLUMN SHAPE EXISTS FOR. A rejoin leaves BOTH dates set, and
  # the later one wins. Reading only `left_email_list_at.nil?` — the obvious
  # one-line version — would call every rejoined account unsubscribed forever,
  # and it would do so silently, on accounts that had explicitly opted back in.
  def test_rejoining_after_leaving_is_subscribed_again
    subject = account(left_email_list_at: Time.at(1_700_000_100),
                      joined_email_list_at: Time.at(1_700_000_200))

    assert Studio::Newsletter.subscribed?(subject),
           "a rejoin sets joined AFTER left; the later date is the current state"
  end

  # A model that cannot answer the question is not subscribed — the safe
  # direction, and the one the profile row's `requires:` gate already assumes.
  def test_a_model_without_the_columns_is_not_subscribed
    refute Studio::Newsletter.subscribed?(NoColumns.new(email: "pat@example.com"))
  end

  # --- ever_joined? ------------------------------------------------------------
  #
  # A DIFFERENT QUESTION from subscribed?, and the reason the leave action stamps
  # a date rather than clearing the join. turf-monster pays a once-ever welcome
  # bonus guarded on-chain; if leaving cleared the join, cycling would re-earn it.

  def test_ever_joined_is_true_after_leaving
    subject = account(joined_email_list_at: Time.at(1_700_000_000),
                      left_email_list_at: Time.at(1_700_000_100))

    refute Studio::Newsletter.subscribed?(subject)
    assert Studio::Newsletter.ever_joined?(subject),
           "leaving must not erase the fact of having joined — a once-ever bonus depends on it"
  end

  def test_ever_joined_is_false_for_an_untouched_account
    refute Studio::Newsletter.ever_joined?(account)
  end

  # --- needs_email? ------------------------------------------------------------
  #
  # A wallet-only account has no address, and a newsletter needs somewhere to
  # send. The UI asks rather than failing the submit.

  def test_an_account_with_no_email_needs_one
    assert Studio::Newsletter.needs_email?(account(email: nil))
  end

  def test_a_blank_email_counts_as_none
    assert Studio::Newsletter.needs_email?(account(email: "   ")),
           "whitespace is not an address"
  end

  def test_an_account_with_an_email_does_not
    refute Studio::Newsletter.needs_email?(account)
  end

  # A model with no `email` reader at all — the engine does not require one, and
  # `respond_to?` is the difference between asking for an address and raising.
  def test_a_model_without_an_email_reader_needs_one
    emailless = Struct.new(:joined_email_list_at, :left_email_list_at, keyword_init: true).new

    assert Studio::Newsletter.needs_email?(emailless)
  end
end
