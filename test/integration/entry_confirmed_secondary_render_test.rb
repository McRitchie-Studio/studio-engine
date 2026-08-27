# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"

# [integration] The secondary action must survive the COMPOSITION, as a working
# button.
#
# Its unit sibling asserts the label and event strings appear in the output. That
# is a substring check: it passes if the words land anywhere at all, including
# inside a comment or an attribute nobody reads. This one parses the rendered HTML
# and asserts the real shape — a <button> element whose click handler dispatches
# the named event — after the value has travelled TWO partials deep
# (_entry_confirmed → its sc_locals hash → _success_card → the button).
#
# That distance is the whole risk: the bug being fixed was a fixed hash in the
# middle of exactly this path, which silently dropped the pair.
class EntryConfirmedSecondaryRenderTest < ActiveSupport::TestCase
  def raw(**locals)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.extend(Studio::Engine.helpers)
    view.render(partial: "studio/modals/blocks/entry_confirmed", locals: locals)
  end

  def card(**locals)
    Nokogiri::HTML.fragment(raw(**locals))
  end

  # ASSERTED ON THE RAW MARKUP, not the parsed tree, and that is not laziness.
  # Nokogiri's HTML parser SILENTLY DROPS an `@click` attribute — `@` is not a
  # valid HTML attribute-name start — so the parsed button comes back carrying
  # only its class, and every Alpine handler in this engine is invisible to a
  # DOM-level assertion. Checking `button["@click"]` looks rigorous and can never
  # fail. The structural assertions below still use the parsed tree, where it is
  # the right tool.
  def test_the_secondary_renders_as_a_button_that_dispatches_the_event
    html = raw(secondary_label: "Dismiss", secondary_event: "tm-modal-close")

    assert_match(%r{<button\s+@click="\$dispatch\('tm-modal-close'\)"[^>]*>\s*Dismiss\s*</button>}m, html,
                 "no <button> reached the rendered card that BOTH carries the secondary label and " \
                 "dispatches the event it was given — a button that renders without its handler is " \
                 "an affordance that only looks like one")
  end

  # The CTA must still be there beside it. A secondary that displaced the primary
  # would pass the assertion above and break the card.
  def test_the_primary_cta_survives_alongside_the_secondary
    doc = card(secondary_label: "Dismiss", secondary_event: "tm-modal-close", cta_label: "Contest Lobby")

    labels = doc.css("button, a").map { |n| n.text.strip }
    assert_includes labels, "Contest Lobby", "the primary CTA vanished when a secondary was added"
    assert_includes labels, "Dismiss"
  end

  # Default unchanged: the callers that never asked for one must render no extra
  # button at all.
  def test_no_secondary_button_renders_by_default
    doc = card
    assert_nil doc.css("button").find { |b| b.text.strip == "Dismiss" }
  end
end
