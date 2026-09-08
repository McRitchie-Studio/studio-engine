# frozen_string_literal: true

require "test_helper"

# REQUIRED HERE RATHER THAN FROM test_helper, and the reason is worth keeping.
# lib/studio/js_literal.rb needs action_view for escape_javascript, and action_view
# pulls in rails-html-sanitizer, which defines a NAMESPACE-ONLY `module Rails` — a
# Rails constant with no `.env` on it. This helper's whole point is a pure-Ruby lane
# with no Rails app, and several files in it guard on a bare `defined?(Rails)`; that
# guard reads TRUE against the namespace and then dies on `Rails.env`. Requiring it
# from test_helper turned test/lib/studio/email_catalog_test.rb red for exactly that
# reason. Only this file needs the constant, so only this file loads it.
require_relative "../../../lib/studio/js_literal"

# [unit] Studio::JsLiteral — the string-position repair for a host value spliced
# into a JS-evaluating HTML attribute (lib/studio/js_literal.rb).
#
# THE COVER GAP THIS FILE OPENED FOR. The repair shipped first as four inline
# `escape_javascript("#{local}")` calls in modals/onboarding/_first_name, and the
# review of that change found the interpolation wrapper had NO test anywhere:
# deleting the `"#{}"` left the entire suite green. The production code was
# correct; nothing reached it. So the method has one home now and this file is
# that home's guard.
#
# THERE ARE TWO SEPARATE BEHAVIOURS HERE and they are asserted separately on
# purpose, because a single test that only sends a plain apostrophe passes on a
# method that dropped the wrapper, and a single test that only checks the marking
# passes on a method that stopped escaping:
#
#   1. IT JS-ESCAPES — the quote, apostrophe, backslash, newline and `</` that would
#      otherwise break out of the JS string literal.
#   2. IT RETURNS AN UNSAFE STRING — so ERB still runs its own attribute-escaping
#      half on the way into the double-quoted attribute. This is the half the
#      wrapper exists for, and the half that had no cover.
class Studio::JsLiteralTest < ActiveSupport::TestCase
  # --- behaviour 1: the JS literal half --------------------------------------

  def test_an_apostrophe_cannot_close_the_js_literal
    # The characteristic failure. Bare, this closes `'…'` and the whole attribute
    # expression becomes a SyntaxError — Alpine then mounts a component that renders
    # every element and does nothing.
    assert_equal "We\\'ll need a name", Studio::JsLiteral.in_attribute("We'll need a name")
  end

  def test_a_double_quote_is_escaped_for_the_js_literal
    assert_equal "say \\\"hi\\\"", Studio::JsLiteral.in_attribute('say "hi"')
  end

  def test_a_backslash_is_escaped_before_anything_it_could_swallow
    assert_equal "a\\\\b", Studio::JsLiteral.in_attribute("a\\b")
  end

  def test_a_newline_cannot_terminate_the_statement
    assert_equal 'a\nb', Studio::JsLiteral.in_attribute("a\nb")
  end

  def test_a_closing_script_tag_cannot_end_the_element
    # Not reachable from an attribute, but the same value flows into inline
    # <script> bodies elsewhere in the engine and escape_javascript covers it.
    assert_equal "x<\\/script>y", Studio::JsLiteral.in_attribute("x</script>y")
  end

  def test_nil_becomes_an_empty_string_rather_than_the_word_nil
    # Every caller reaches this with an OPTIONAL local. "nil" arriving as a JS
    # string would be a working component with a wrong value, which is worse than
    # the empty string.
    assert_equal "", Studio::JsLiteral.in_attribute(nil)
  end

  def test_an_ordinary_value_is_returned_byte_for_byte
    # The inertness claim every call site makes: no default anywhere in the engine
    # contains a character either escaper touches, so applying this changed no
    # rendered byte.
    assert_equal "onboarding-step-done", Studio::JsLiteral.in_attribute("onboarding-step-done")
  end

  # --- behaviour 2: the attribute half ---------------------------------------
  #
  # THIS IS THE ONE THE `"#{}"` WRAPPER EXISTS FOR, and the one that had no cover
  # until now. escape_javascript PRESERVES its argument's html_safe marking, so
  # `escape_javascript(safe_value)` answers true to html_safe? — ERB then steps
  # aside and a raw double quote reaches the attribute and closes it early.
  #
  # Deleting the interpolation in lib/studio/js_literal.rb fails exactly these two.

  def test_a_safe_input_does_not_produce_a_safe_output
    result = Studio::JsLiteral.in_attribute('say "hi"'.html_safe)

    assert_not result.html_safe?,
      "a safe return value makes ERB skip its attribute escaping, which is how a " \
      "raw double quote gets out of a double-quoted x-data"
  end

  def test_a_plain_input_also_produces_an_unsafe_output
    # The other side of the same claim: this must not depend on what the caller
    # happened to hand in. Both branches of the input have to leave unsafe.
    assert_not Studio::JsLiteral.in_attribute('say "hi"').html_safe?
  end

  def test_a_safe_input_is_still_js_escaped
    # A safe input must not take a shortcut PAST the escaping either. Without this,
    # a "fix" that simply returned the html_safe value unescaped would pass the
    # marking test above.
    assert_equal "say \\\"hi\\\"", Studio::JsLiteral.in_attribute('say "hi"'.html_safe)
  end

  # --- the boundary this method deliberately does not cross -------------------

  def test_a_dollar_sign_is_escaped_which_is_why_identifiers_must_not_use_this
    # The reason identifier-position locals ($store.<name>) are VALIDATED rather
    # than escaped: escape_javascript mangles a legal JS identifier. A store named
    # dsModals$2 comes back as dsModals\$2, which is a different SyntaxError and
    # the same dead card. Pinned here so the next person who reaches for this
    # method on an identifier finds the reason written down.
    assert_equal "dsModals\\$2", Studio::JsLiteral.in_attribute("dsModals$2")
  end
end
