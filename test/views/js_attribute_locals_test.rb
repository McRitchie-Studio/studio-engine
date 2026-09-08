# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"

# [integration] Host-supplied locals that land inside a JS string literal in a
# JS-evaluating attribute, across the blocks that take one.
#
# WHAT THIS TIER CAN AND CANNOT SEE, stated up front because the distinction is the
# whole reason the browser lane exists beside it. The characteristic failure of
# this defect leaves the response bytes looking correct: a stray quote closes the
# attribute early, Alpine mounts a silent no-op, and every element a substring
# assertion looks for is still in the markup. So a test that greps the output for
# the hostile value passes on a DEAD card.
#
# These tests therefore assert STRUCTURE, never the presence of a string:
#
#   * where the attribute is parseable (x-data, :href), the rendered HTML is parsed
#     and the attribute VALUE is read back. Nokogiri decodes entities exactly as a
#     browser does, so a value that comes back whole is a value that survived both
#     escapers. A broken one comes back truncated at the quote that closed it.
#   * where it is NOT parseable (@click), the attribute region is extracted from
#     the raw markup and asserted to END at its intended terminator. Nokogiri
#     SILENTLY DROPS an `@click` — `@` cannot start an HTML attribute name — so
#     `button["@click"]` reads nil on a correct page and a DOM-level assertion can
#     never fail. (test/integration/entry_confirmed_secondary_render_test.rb
#     documents that trap; this file inherits it.)
#
# The half only a browser can settle — that the card still MOUNTS and the handler
# still FIRES — is e2e/js_attribute_locals.spec.js.
class JsAttributeLocalsTest < ActiveSupport::TestCase
  # A value carrying every character that could leave the nest of contexts: the
  # apostrophe that closes the JS literal, the double quote that closes the HTML
  # attribute, a backslash that could swallow the escape of whatever follows, and
  # a closing script tag.
  HOSTILE = %q{it's a "quote" \ </script>}

  def render_partial(name, **locals)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.extend(Studio::Engine.helpers)
    view.render(partial: name, locals: locals)
  end

  # Read an attribute back the way a BROWSER would — parsed, entities decoded.
  def parsed_attribute(html, selector, name)
    Nokogiri::HTML.fragment(html).at_css(selector)&.[](name)
  end

  # The raw-markup fallback for attributes Nokogiri discards. Returns the text
  # between the opening quote and the FIRST double quote after it — i.e. exactly
  # what the HTML parser will treat as the attribute's value. If escaping was
  # dropped, this stops early and the terminator assertion below fails.
  def raw_attribute(html, name)
    html[/#{Regexp.escape(name)}="([^"]*)"/, 1]
  end

  # --- @click event names: _success_card and _error_card ----------------------
  #
  # cta_event / secondary_event are the widest reach this defect has: _success_card
  # is the most-rendered block in the engine. Both are $dispatch STRING arguments,
  # so escaping is the complete repair — any character is legal in an event name.

  def test_a_hostile_cta_event_does_not_close_the_success_card_handler
    html = render_partial("studio/modals/blocks/success_card",
                          title: "Done", cta_label: "Go", cta_event: HOSTILE)

    handler = raw_attribute(html, "@click")

    assert handler, "the CTA's @click did not render at all"
    assert handler.end_with?("')"),
      "the handler stops at #{handler.inspect} — the attribute closed early, which " \
      "mounts the card as a silent no-op that still renders every element"
    assert_includes handler, "$dispatch('"
  end

  def test_a_hostile_secondary_event_does_not_close_the_success_card_handler
    # ASSERTED SEPARATELY FROM cta_event, not folded into one render. They are two
    # interpolations on two lines: a repair applied to one is silent about the
    # other, and a single card carrying both would go green the moment either was
    # fixed.
    html = render_partial("studio/modals/blocks/success_card",
                          title: "Done", secondary_label: "Later", secondary_event: HOSTILE)

    handler = html[/@click="\$dispatch\('([^"]*)/, 0]

    assert handler&.end_with?("')"), "the secondary handler closed early: #{handler.inspect}"
  end

  def test_a_hostile_cta_event_does_not_close_the_error_card_handler
    html = render_partial("studio/modals/blocks/error_card",
                          title: "Failed", cta_event: HOSTILE)

    handler = raw_attribute(html, "@click")

    assert handler&.end_with?("')"), "the error card's handler closed early: #{handler.inspect}"
  end

  def test_a_hostile_secondary_event_does_not_close_the_error_card_handler
    html = render_partial("studio/modals/blocks/error_card",
                          title: "Failed", secondary_label: "Close", secondary_event: HOSTILE)

    handler = html[/@click="\$dispatch\('([^"]*)/, 0]

    assert handler&.end_with?("')"), "the error card's secondary handler closed early: #{handler.inspect}"
  end

  def test_an_ordinary_event_name_renders_exactly_as_before
    # The inertness claim. No default or in-repo value contains a character either
    # escaper touches, so every shipped card is byte-for-byte what it was.
    html = render_partial("studio/modals/blocks/success_card",
                          title: "Done", cta_label: "Go", cta_event: "entry-confirmed")

    assert_includes html, %q{@click="$dispatch('entry-confirmed')"}
  end

  # --- x-data: _crop_photo ----------------------------------------------------

  def test_a_hostile_crop_store_leaves_the_x_data_parseable
    html = render_partial("studio/modals/crop_photo", store: HOSTILE)

    x_data = parsed_attribute(html, "div[x-data]", "x-data")

    assert x_data, "the crop modal rendered no x-data"
    assert x_data.end_with?("})"),
      "the x-data was cut off at #{x_data.inspect}; the browser would mount nothing"
    # The double quote reached the attribute as an ENTITY and came back decoded,
    # which is the ERB half doing its work — the half the interpolation wrapper in
    # Studio::JsLiteral exists to keep switched on.
    assert_includes x_data, '\\"quote\\"'
  end

  def test_an_ordinary_crop_store_renders_exactly_as_before
    html = render_partial("studio/modals/crop_photo", store: "dsModals")

    assert_includes html, %q{x-data="cropPhotoModal({ store: 'dsModals' })"}
  end

  # --- x-data: _entry_confirmed's clusterParam --------------------------------

  def test_a_hostile_cluster_param_leaves_the_entry_card_x_data_parseable
    html = render_partial("studio/modals/blocks/entry_confirmed",
                          title: "Confirmed", cluster_param: HOSTILE)

    x_data = parsed_attribute(html, "div[x-data]", "x-data")

    assert x_data, "the entry card rendered no x-data"
    assert x_data.end_with?("}"),
      "the x-data closed early at #{x_data.inspect}, taking the props getter with it"
    assert_includes x_data, "get props()",
      "the props getter must survive — every nested block resolves through it"
  end

  # --- :href: _solana_tx_link -------------------------------------------------

  def test_a_hostile_cluster_param_leaves_the_explorer_href_parseable
    html = render_partial("studio/modals/blocks/solana_tx_link",
                          tx_signature_key: "props.txSignature", cluster_param: HOSTILE)

    href = parsed_attribute(html, "a", ":href")

    assert href, "the tx link rendered no :href"
    assert href.end_with?("'"),
      "the :href expression closed early at #{href.inspect}, so the link binds nothing"
    assert_includes href, "explorer.solana.com"
  end

  # --- _birthday_fields: applied, and honestly NOT hostile-testable ------------

  def test_the_birthday_value_is_unchanged_for_every_reachable_input
    # NO HOSTILE CASE HERE, and that is a finding rather than an omission. `value`
    # is built by format("%04d-%02d-%02d", …) from three integer-ish columns, so no
    # host can put a quote through it: format raises on anything that is not
    # numeric. The escaping was applied anyway because the SPLICE is the thing being
    # made safe — the day that formatter is replaced, or the local is fed from
    # somewhere else, the guard is already in the right place. Claiming a
    # hostile-value guard for it would be claiming a test that cannot bite.
    #
    # So what IS asserted is inertness: the attribute a real record produces did not
    # move.
    user = Struct.new(:birth_year, :birth_month, :birth_day).new(1991, 1, 31)
    html = render_partial("studio/profiles/birthday_fields", user: user)

    assert_includes html, %q{x-data="studioBirthdayFields('1991-01-31')"}
  end
end
