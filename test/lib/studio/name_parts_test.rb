# frozen_string_literal: true

require "test_helper"

# [unit] Studio::NameParts — the name halves a callback-free writer must produce
# (lib/studio/name_parts.rb).
#
# WHAT THIS FILE IS REALLY ASSERTING: parity with the host callback. Every
# consuming app derives these two columns in a `before_save :set_name_parts`,
# and Studio::OnboardingController deliberately writes with `update_columns`
# (the slug — see that controller). So the engine's derivation and the host's
# callback must agree on EVERY shape of name, or a row lands split differently
# depending on which door it came through.
#
# The reference below is not a second call to the code under test — it is the
# host callback's body, copied from the source of truth so the two can actually
# disagree:
#
#   mcritchie-studio  app/models/user.rb  #set_name_parts
#   turf-monster      app/models/user.rb  #set_name_parts
#
#     parts = name.to_s.strip.split(" ")
#     self.first_name = parts.first
#     self.last_name  = parts.last if parts.size > 1
#
# Byte-identical in both apps as of 2026-09-05.
class StudioNamePartsTest < Minitest::Test
  # A stand-in for a record the host callback has just run against. Starts with
  # halves already on file, because the carry-over rule is only observable on a
  # record that HAS a last name to lose.
  Record = Struct.new(:first_name, :last_name)

  # The host's callback, applied to a record. The reference implementation.
  def callback(record, name)
    parts = name.to_s.strip.split(" ")
    record.first_name = parts.first
    record.last_name = parts.last if parts.size > 1
    record
  end

  # The engine's derivation, applied the way a callback-free writer applies it:
  # assign every key the hash carries, and only those.
  def writer(record, name)
    Studio::NameParts.from(name).each { |column, v| record.send(:"#{column}=", v) }
    record
  end

  NAMES = [
    "Ada Lovelace",           # the bug: a two-word answer to a first-name ask
    "Ada",                    # one word — the ordinary case
    "Ada B. Lovelace",        # three words: first and LAST, middle dropped
    "  Ada   Lovelace  ",     # ragged whitespace, as typed
    "Ada Lovelace-King",      # a hyphenated surname is still one word
    "van Gogh",               # a lowercase particle leads
    "",                       # blank
    "   ",                    # whitespace only
    nil                       # absent
  ].freeze

  def test_it_agrees_with_the_host_callback_on_every_shape_of_name
    NAMES.each do |name|
      expected = callback(Record.new("Existing", "Onfile"), name)
      actual   = writer(Record.new("Existing", "Onfile"), name)

      assert_equal [expected.first_name, expected.last_name],
                   [actual.first_name, actual.last_name],
                   "engine and host callback disagree on #{name.inspect}"
    end
  end

  # The bug this whole task exists for, stated directly rather than only through
  # the parity loop above — so a reader sees the answer, not just that two
  # implementations match.
  def test_a_multi_word_name_splits_into_both_halves
    assert_equal({ first_name: "Ada", last_name: "Lovelace" },
                 Studio::NameParts.from("Ada Lovelace"))
  end

  def test_a_middle_name_is_dropped_not_folded_into_either_half
    assert_equal({ first_name: "Ada", last_name: "Lovelace" },
                 Studio::NameParts.from("Ada B. Lovelace"))
  end

  def test_runs_of_whitespace_do_not_become_empty_words
    assert_equal({ first_name: "Ada", last_name: "Lovelace" },
                 Studio::NameParts.from("  Ada   Lovelace  "))
  end

  # OMITTED, NOT NIL. The distinction is the entire carry-over rule: a hash that
  # carried `last_name: nil` would erase a surname already on file whenever
  # someone answered a first-name prompt with one word.
  def test_a_one_word_name_omits_last_name_rather_than_nulling_it
    parts = Studio::NameParts.from("Ada")

    assert_equal({ first_name: "Ada" }, parts)
    refute parts.key?(:last_name),
           "a nil last_name here would clear a surname the person already set on /profile"
  end

  def test_the_omission_actually_preserves_a_surname_on_file
    record = writer(Record.new("Ada", "Lovelace"), "Grace")

    assert_equal "Grace", record.first_name
    assert_equal "Lovelace", record.last_name,
                 "the host callback leaves it standing, so this must too"
  end

  # A blank name still answers with a first_name key, because a writer assigning
  # the hash must be able to CLEAR a stale first name rather than silently keep
  # it. Matches the callback, which assigns `parts.first` unconditionally.
  def test_a_blank_name_clears_first_name_and_leaves_last_name_alone
    [nil, "", "   "].each do |blank|
      parts = Studio::NameParts.from(blank)

      assert_equal({ first_name: nil }, parts, "on #{blank.inspect}")
    end
  end

  # PURE. It reads no record and touches no database, which is what lets this
  # unit lane exercise it at all and what lets a host callback delegate to it.
  def test_it_is_pure_and_takes_only_a_string
    assert_equal 1, Studio::NameParts.method(:from).arity
    assert_equal({ first_name: "Ada", last_name: "Lovelace" },
                 Studio::NameParts.from("Ada Lovelace"))
    assert_equal({ first_name: "Ada", last_name: "Lovelace" },
                 Studio::NameParts.from("Ada Lovelace"),
                 "twice must answer the same — nothing is memoized or mutated")
  end
end
