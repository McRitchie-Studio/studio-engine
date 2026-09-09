# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

# [unit] Studio::JsIdentifier — the contract a value must meet to be spliced into JS
# identifier position (`$store.<name>.close()`).
#
# THE SIBLING GUARD to test/lib/studio/js_literal_test.rb, and the two are opposites.
# JsLiteral repairs a value by ESCAPING it, and its test asks "did the value survive".
# This one repairs by REFUSING, so its test asks the two questions a refusal owes:
# does it say no to what it must, and — the half that is easy to skip — can it still
# say yes? A guard that refused everything would pass any table of hostile inputs.
class Studio::JsIdentifierTest < ActiveSupport::TestCase
  # Every store name the engine or its consumers actually use, plus the shapes the
  # pattern deliberately admits. `$` and a leading `_` are legal in a JS identifier and
  # a host may reasonably write them; escaping is what would have broken those.
  VALID = [
    "modals",       # the default, and what every consumer app renders today
    "dsModals",     # the living style guide's page-scoped host
    "emailModals",  # the email manager's
    "profileModals",
    "ds_Modals$2",  # the whole admitted alphabet in one value
    "_private",
    "$",
    "a",
    "A0"
  ].freeze

  # Each leaves identifier position by a different door, and NONE is repairable by
  # escaping — that is the property this module exists for.
  INVALID = {
    "" => "an absent-but-present value renders `$store..close()`",
    "mo dals" => "a space ends the name",
    "modals'x" => "an apostrophe — the character that made escaping look like the fix",
    %(modals"x) => "a double quote ends the attribute",
    "modals.foo" => "a dot continues member access instead of ending the name",
    "modals-x" => "subtraction, not a name",
    "2modals" => "a numeric literal followed by a name",
    "modals;alert(1)" => "a statement",
    "modals</script>" => "ends a script body",
    "modals\nx" => "a NEWLINE INSIDE — an unanchored /^…$/ would admit this",
    "x modals" => "trailing junk after a legal-looking start",
    "modals " => "a trailing space, which is invisible in a stack trace",
    "modäls" => "outside ASCII IdentifierName, which is where the pattern is drawn"
  }.freeze

  def test_it_admits_every_name_a_host_would_plausibly_write
    # THE CONTROL for every refusal below. Without it a validator hard-coded to
    # `raise` passes the whole INVALID table.
    VALID.each do |name|
      assert_equal name, Studio::JsIdentifier.validate!(name, local: :modal_store),
                   "#{name.inspect} is a legal JS identifier and must be admitted, unchanged"
    end
  end

  def test_it_refuses_every_value_that_leaves_identifier_position
    INVALID.each do |bad, why|
      err = assert_raises(ArgumentError, "#{bad.inspect} must be refused — #{why}") do
        Studio::JsIdentifier.validate!(bad, local: :modal_store)
      end

      assert_includes err.message, "modal_store",
                      "the refusal has to name the local a host would have to fix"
      assert_includes err.message, bad.inspect,
                      "and show the value it got, so the fix does not need a rerun"
    end
  end

  def test_one_character_flips_the_verdict
    # DISCRIMINATION, not a table. The two assertions above could both pass on a
    # validator keyed to something incidental about the strings in them. These two
    # values differ by exactly one character.
    assert_equal "dsModals", Studio::JsIdentifier.validate!("dsModals", local: :modal_store)
    assert_raises(ArgumentError) { Studio::JsIdentifier.validate!("dsModals!", local: :modal_store) }
  end

  def test_the_message_names_the_caller_s_own_local
    # TWO SPELLINGS IN THE ENGINE — fifteen partials call it `modal_store`, two call it
    # `store` — which is why `local:` is required and has no default. A default would
    # be right fifteen times out of seventeen and send the other two hosts looking for
    # a local they never passed.
    err = assert_raises(ArgumentError) { Studio::JsIdentifier.validate!("mo dals", local: :store) }

    assert_includes err.message, "store must be a JS identifier"
    assert_not_includes err.message, "modal_store"
  end

  def test_it_explains_that_escaping_is_not_the_missing_repair
    # The message is the entire support channel for this failure: a host meets it once,
    # in development, with no other context. Left at "invalid value" the obvious next
    # move is to escape the name — which produces a DIFFERENT SyntaxError and the same
    # dead card, one layer further from the cause.
    err = assert_raises(ArgumentError) { Studio::JsIdentifier.validate!("modals'x", local: :modal_store) }

    assert_includes err.message, "Escaping it would not help"
    assert_includes err.message, "$store.<name>"
  end

  def test_it_hands_back_a_plain_string_that_ERB_will_still_escape
    # LOAD-BEARING, and the reason it is not obvious is that it buys nothing TODAY: a
    # value matching the pattern contains no character ERB escapes, so the identifier
    # reaches the browser byte-identical either way. What the marking would cost is the
    # day the pattern is widened — ERB's escaping is the layer still standing, and a
    # value marked html_safe skips it. So the module deliberately keeps that layer
    # armed, including for a host that hands it a SafeBuffer.
    plain = Studio::JsIdentifier.validate!("dsModals", local: :modal_store)
    assert_not plain.html_safe?, "a validated identifier must not be marked html_safe"

    marked = Studio::JsIdentifier.validate!("dsModals".html_safe, local: :modal_store)
    assert_equal "dsModals", marked
    assert_not marked.html_safe?, "the marking must be stripped, not carried through"
  end

  def test_it_stringifies_before_it_judges
    # A host may pass a Symbol (`modal_store: :dsModals`) or anything else that names
    # itself sensibly. The value that gets SPLICED is `#{value}`, so that is the value
    # the pattern has to be applied to — judging the object instead would refuse a
    # symbol that renders perfectly.
    assert_equal "dsModals", Studio::JsIdentifier.validate!(:dsModals, local: :modal_store)
    assert_raises(ArgumentError) { Studio::JsIdentifier.validate!(nil, local: :modal_store) }
  end

  def test_the_pattern_is_anchored_at_both_ends
    # Asserted against the constant as well as through validate!, because an anchor is
    # the single character most likely to be lost in an edit and the loss is invisible
    # in every ordinary case: /^…$/ matches a line rather than a string, so a value
    # with a newline in it passes while every one-line test stays green.
    assert Studio::JsIdentifier::PATTERN.match?("dsModals")
    assert_not Studio::JsIdentifier::PATTERN.match?("dsModals\nrm -rf /")
    assert_not Studio::JsIdentifier::PATTERN.match?("\ndsModals")
  end
end
