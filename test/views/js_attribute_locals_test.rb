# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "cgi"
require "nokogiri"

# [integration] Host-supplied locals that land inside a JS string literal in a
# JS-evaluating attribute, across the blocks that take one.
#
# HOW THIS FILE HAS TO ASSERT, and why the obvious two ways are both worthless
# here. Each was written first, watched survive the mutation, and replaced.
#
#   1. "the hostile value appears in the output" — a substring check. It passes on a
#      DEAD card: the characteristic failure leaves every element and every string
#      in the markup, which is the whole reason this defect is hard to see.
#
#   2. "the attribute is not truncated at a stray quote" — a structural check on the
#      RAW markup, and it cannot fail. ERB html-escapes the raw local too: the
#      apostrophe becomes &#39; and the double quote becomes &quot;, so the ATTRIBUTE
#      is well-formed whether or not the JS escaping ran. Measured, not reasoned —
#      the first version of this file asserted exactly that and all four
#      call-site mutants survived it.
#
# The difference lives one layer down, after the HTML parser decodes those entities
# and hands the result to the JS parser:
#
#      repaired   $dispatch('it\'s a \"quote\"')     -> one string, value intact
#      unrepaired $dispatch('it's a "quote"')        -> literal closes at `it`,
#                                                       SyntaxError, dead card
#
# So these tests DECODE the attribute the way a browser does and then read the JS
# string literal the way a JS parser does — honouring backslash escapes and stopping
# at the first UNESCAPED quote — and assert the recovered value equals what the host
# passed. That is a claim no amount of well-formed markup can satisfy on its own.
#
# The half that still needs a browser — that the card MOUNTS and the handler FIRES —
# is e2e/js_attribute_locals.spec.js.
class JsAttributeLocalsTest < ActiveSupport::TestCase
  # Every character that could leave the nest of contexts: the apostrophe that
  # closes the JS literal, the double quote that closes the HTML attribute once ERB
  # has been persuaded to skip its half, a backslash that would swallow the escape
  # of whatever follows if the order were wrong, and a closing script tag.
  HOSTILE = %q{it's a "quote" \ </script>}

  def render_partial(name, **locals)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.extend(Studio::Engine.helpers)
    view.render(partial: name, locals: locals)
  end

  # The attribute VALUE as the browser will hold it: extracted from the raw markup,
  # then entity-decoded.
  #
  # DONE BY HAND RATHER THAN THROUGH NOKOGIRI because Nokogiri SILENTLY DROPS an
  # `@click` — `@` cannot begin an HTML attribute name — so `button["@click"]` reads
  # nil on a perfectly correct page and any DOM-level assertion about an Alpine
  # handler can never fail. (test/integration/entry_confirmed_secondary_render_test.rb
  # records that trap; this file inherits it.) The `[^"]*` is safe precisely BECAUSE
  # ERB entity-escapes every double quote in the value — the property that makes the
  # raw markup useless as evidence is the same property that makes this extraction
  # reliable.
  def decoded_attribute(html, name, occurrence: 0)
    values = html.scan(/#{Regexp.escape(name)}="([^"]*)"/).flatten
    raw = values[occurrence]
    raw && CGI.unescapeHTML(raw)
  end

  # Read the JS string literal that begins right after +opener+, the way a JS parser
  # would. Returns [recovered_value, text_after_the_closing_quote], or [nil, nil]
  # when there is no literal there or it never closes.
  #
  # THIS IS THE ASSERTION ENGINE. On a repaired attribute the literal runs to the
  # intended end and the value round-trips. On an unrepaired one it closes early at
  # the host's own apostrophe, so the value comes back truncated AND the remainder
  # is the rest of the host's string instead of the closing `)`. Both halves are
  # checked, because a truncation that happened to leave `')` behind would otherwise
  # read as a pass.
  def js_literal_after(decoded, opener)
    start = decoded.to_s.index(opener)
    return [nil, nil] unless start

    i = start + opener.length
    quote = decoded[i]
    return [nil, nil] unless ["'", '"'].include?(quote)

    i += 1
    value = +""
    while i < decoded.length
      char = decoded[i]
      if char == "\\"
        value << decoded[i + 1].to_s
        i += 2
      elsif char == quote
        return [value, decoded[(i + 1)..]]
      else
        value << char
        i += 1
      end
    end
    [nil, nil]
  end

  # The whole claim in one place: the host's value is what a JS parser recovers, and
  # the literal ends where the template meant it to.
  def assert_literal_survives(decoded, opener, expected_remainder, message)
    value, remainder = js_literal_after(decoded, opener)

    assert_equal HOSTILE, value,
      "#{message}: a JS parser recovers #{value.inspect} from #{decoded.inspect}"
    assert_equal expected_remainder, remainder,
      "#{message}: the literal closed in the wrong place, so the expression after it is " \
      "#{remainder.inspect} rather than #{expected_remainder.inspect}"
  end

  # --- @click event names: _success_card and _error_card ----------------------
  #
  # cta_event / secondary_event are the widest reach this defect has: _success_card
  # is the most-rendered block in the engine. Both are $dispatch STRING arguments,
  # so escaping is the complete repair — any character is legal in an event name.

  def test_a_hostile_cta_event_survives_the_success_card_handler
    html = render_partial("studio/modals/blocks/success_card",
                          title: "Done", cta_label: "Go", cta_event: HOSTILE)

    assert_literal_survives(decoded_attribute(html, "@click"), "$dispatch(", ")",
                            "the success card's CTA")
  end

  def test_a_hostile_cta_event_survives_the_success_card_DRAIN_handler
    # THE SECOND cta_event SPLICE, in the auto-redirect branch. It is a separate
    # interpolation on a separate line and the plain branch above cannot reach it —
    # the two are mutually exclusive `elsif` arms. Without this the drain button
    # could lose its escaping and every other test here would stay green.
    html = render_partial("studio/modals/blocks/success_card",
                          title: "Done", cta_label: "Go", cta_event: HOSTILE,
                          auto_redirect_url_key: "props.url", cta_drain: true)

    assert_literal_survives(decoded_attribute(html, "@click"), "$dispatch(", ")",
                            "the success card's DRAIN CTA")
  end

  def test_a_hostile_secondary_event_survives_the_success_card_handler
    # DRIVEN ON ITS OWN RENDER, not folded in with cta_event. They are two
    # interpolations on two lines: a repair applied to one is silent about the
    # other, and a card carrying both would go green the moment either was fixed.
    html = render_partial("studio/modals/blocks/success_card",
                          title: "Done", secondary_label: "Later", secondary_event: HOSTILE)

    assert_literal_survives(decoded_attribute(html, "@click"), "$dispatch(", ")",
                            "the success card's secondary action")
  end

  def test_a_hostile_cta_event_survives_the_error_card_handler
    html = render_partial("studio/modals/blocks/error_card",
                          title: "Failed", cta_event: HOSTILE)

    assert_literal_survives(decoded_attribute(html, "@click"), "$dispatch(", ")",
                            "the error card's CTA")
  end

  def test_a_hostile_secondary_event_survives_the_error_card_handler
    html = render_partial("studio/modals/blocks/error_card",
                          title: "Failed", secondary_label: "Close", secondary_event: HOSTILE)

    assert_literal_survives(decoded_attribute(html, "@click"), "$dispatch(", ")",
                            "the error card's secondary action")
  end

  def test_an_ordinary_event_name_renders_exactly_as_before
    # The inertness claim. No default or in-repo value contains a character either
    # escaper touches, so every shipped card is byte-for-byte what it was.
    html = render_partial("studio/modals/blocks/success_card",
                          title: "Done", cta_label: "Go", cta_event: "entry-confirmed")

    assert_includes html, %q{@click="$dispatch('entry-confirmed')"}
  end

  # --- x-data: _crop_photo ----------------------------------------------------

  def test_a_hostile_crop_store_survives_the_modal_x_data
    html = render_partial("studio/modals/crop_photo", store: HOSTILE)

    assert_literal_survives(decoded_attribute(html, "x-data"), "{ store: ", " })",
                            "the crop modal's store name")
  end

  def test_an_ordinary_crop_store_renders_exactly_as_before
    html = render_partial("studio/modals/crop_photo", store: "dsModals")

    assert_includes html, %q{x-data="cropPhotoModal({ store: 'dsModals' })"}
  end

  # --- x-data: _entry_confirmed's clusterParam --------------------------------

  def test_a_hostile_cluster_param_survives_the_entry_card_x_data
    html = render_partial("studio/modals/blocks/entry_confirmed",
                          title: "Confirmed", cluster_param: HOSTILE)

    decoded = decoded_attribute(html, "x-data")

    assert_literal_survives(decoded, "clusterParam: ", " }",
                            "the entry card's cluster query")
    assert_includes decoded, "get props()",
      "the props getter must survive — every nested block resolves through it"
  end

  # --- :href: _solana_tx_link -------------------------------------------------

  def test_a_hostile_cluster_param_survives_the_explorer_href
    html = render_partial("studio/modals/blocks/solana_tx_link",
                          tx_signature_key: "props.txSignature", cluster_param: HOSTILE)

    # The cluster query is the LAST of three concatenated pieces, so the opener is
    # the `+` that joins it rather than a named key.
    assert_literal_survives(decoded_attribute(html, ":href"), ") + ", "",
                            "the explorer link's cluster query")
  end

  # --- _birthday_fields: applied, and honestly NOT hostile-testable ------------

  def test_the_birthday_value_is_unchanged_for_every_reachable_input
    # NO HOSTILE CASE HERE, and that is a finding rather than an omission. `value` is
    # built by format("%04d-%02d-%02d", …) from three integer columns, so no host can
    # put a quote through it — format raises on anything that is not numeric. The
    # escaping was applied anyway because the SPLICE is what is being made safe: the
    # day that formatter changes, or the local is fed from somewhere else, the guard
    # is already in the right place. Claiming a hostile-value guard for it would be
    # claiming a test that cannot bite, so what is asserted instead is inertness —
    # the attribute a real record produces did not move.
    user = Struct.new(:birth_year, :birth_month, :birth_day).new(1991, 1, 31)
    html = render_partial("studio/profiles/birthday_fields", user: user)

    assert_includes html, %q{x-data="studioBirthdayFields('1991-01-31')"}
  end
end
