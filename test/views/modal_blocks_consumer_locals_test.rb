# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"

# [unit] The locals the modal blocks gained so a consumer can render the engine
# block instead of keeping its own copy (engine-modal-blocks-carry-consumer).
# turf-monster's test/views/engine_modal_readoption_gaps_test.rb names each gap;
# this file pins what closed it:
#
#   blocks/_birthday         progress_pill: { current:, total: }
#   blocks/_error_card       cta_close, secondary_close, modal_store,
#                            countdown_key, countdown_text, auto_close
#   blocks/_success_card     cta_close, secondary_close, modal_store,
#                            slot_position: :message
#   blocks/_change_username  locked: { title:, subtitle:, cta_label:, cta_href:, dismiss: }
#
# Unset, each renders as 0.113.0 did: test/views/modal_blocks_baseline_test.rb.
#
# READ THROUGH HTML5. `@click` is not an HTML4 attribute name, so Nokogiri's HTML4
# parser drops it and an assertion on it reads nil on a correct page
# (test/views/js_identifier_locals_test.rb carries the measurement).
class ModalBlocksConsumerLocalsTest < ActiveSupport::TestCase
  def view
    v = ActionView::Base.with_empty_template_cache.with_view_paths([File.expand_path("../../app/views", __dir__)])
    v.extend(Studio::Engine.helpers)
    v
  end

  def render(partial, block: nil, **locals)
    html = if block
      view.render(layout: partial, locals: locals) { block.html_safe }
    else
      view.render(partial: partial, locals: locals)
    end
    Nokogiri::HTML5.fragment(html)
  end

  def refusal(partial, **locals)
    view.render(partial: partial, locals: locals)
    nil
  rescue StandardError => e
    e = e.cause while e.cause
    e
  end

  # --- blocks/_birthday: progress_pill -------------------------------------------

  def test_birthday_draws_the_chain_pill_first_inside_the_card
    doc = render("studio/modals/blocks/birthday", submit_url: "/age", progress_pill: { current: 2, total: 3 })
    root = doc.at_css("[x-data^='birthdayModal']")
    first = root.element_children.first

    assert_equal 3, first.css(".rounded-full").size, "a pill of three segments"
    assert_equal 2, first.css(".bg-primary").size, "two of them filled"
    assert_includes first.next_element.to_html, "Your birthday", "the title row comes after the pill"
  end

  def test_birthday_without_a_pill_draws_none
    doc = render("studio/modals/blocks/birthday", submit_url: "/age")
    assert_empty doc.css(".bg-primary.rounded-full"), "no pill segment without progress_pill"
  end

  def test_birthday_refuses_a_pill_it_cannot_draw
    [{ total: 3 }, { current: 2, totl: 3 }, 2, "2 of 3"].each do |bad|
      err = refusal("studio/modals/blocks/birthday", submit_url: "/age", progress_pill: bad)
      assert_instance_of ArgumentError, err, "progress_pill: #{bad.inspect} must raise"
      assert_includes err.message, "progress_pill"
    end
  end

  # --- blocks/_success_card: closing and the message slot -------------------------

  def test_success_cta_close_closes_the_default_store
    button = render("studio/modals/blocks/success_card", title: "Done", cta_label: "Got it", cta_close: true).at_css("button")

    assert_equal "Got it", button.text
    assert_equal "$store.modals.close()", button["@click"]
    assert_equal "button", button["type"]
    assert_includes button["class"], "btn-primary"
  end

  def test_success_close_actions_close_the_host_store
    doc = render("studio/modals/blocks/success_card", title: "Done", cta_label: "Got it", cta_close: true,
                                                      secondary_label: "Later", secondary_close: true,
                                                      modal_store: "profileModals")
    assert_equal ["$store.profileModals.close()"] * 2, doc.css("button").map { |b| b["@click"] }
  end

  def test_success_refuses_two_wirings_for_one_button
    [{ cta_label: "Go", cta_close: true, cta_event: "go" },
     { cta_label: "Go", cta_close: true, cta_href_key: "props.url" },
     { secondary_label: "Later", secondary_close: true, secondary_event: "later" }].each do |locals|
      err = refusal("studio/modals/blocks/success_card", title: "Done", **locals)
      assert_instance_of ArgumentError, err, "#{locals.inspect} must raise"
    end
  end

  def test_success_refuses_a_store_that_is_not_an_identifier
    err = refusal("studio/modals/blocks/success_card", title: "Done", cta_label: "Go", cta_close: true, modal_store: "mo dals")
    assert_instance_of ArgumentError, err
    assert_includes err.message, "modal_store"
  end

  def test_success_message_slot_puts_the_block_where_the_message_was
    doc = render("studio/modals/blocks/success_card",
                 block: %(We sent it to <span class="text-heading font-medium" x-text="props.currentEmail"></span>.),
                 title: "Confirm your email", message: "replaced", slot_position: :message,
                 cta_label: "Got it", cta_close: true)
    slot = doc.at_css("[x-text='props.currentEmail']").parent

    assert_equal "div", slot.name, "a div, so the caller's markup may hold block elements"
    assert_equal %w[text-sm text-secondary mb-4], slot["class"].split
    refute_includes doc.to_html, "replaced", "the block replaces message"
    assert_equal 1, doc.css("[x-text='props.currentEmail']").size, "rendered once, not again below the CTA"
    assert_equal "button", slot.next_element.name, "the message sits above the CTA"
  end

  # --- blocks/_error_card: closing and the countdown -----------------------------

  def test_error_close_actions_close_the_store
    doc = render("studio/modals/blocks/error_card", title: "Easy there", cta_label: "OK", cta_close: true,
                                                    secondary_label: "Dismiss", secondary_close: true)
    assert_equal ["$store.modals.close()"] * 2, doc.css("button").map { |b| b["@click"] }
    assert_equal %w[OK Dismiss], doc.css("button").map { |b| b.text.strip }
  end

  def test_error_refuses_two_wirings_for_one_button
    [{ cta_close: true, cta_reload: true }, { cta_close: true, cta_event: "retry" },
     { secondary_label: "x", secondary_close: true, secondary_event: "y" }].each do |locals|
      assert_instance_of ArgumentError, refusal("studio/modals/blocks/error_card", title: "Oops", **locals),
                         "#{locals.inspect} must raise"
    end
    err = refusal("studio/modals/blocks/error_card", title: "Oops", cta_close: true, modal_store: "modals.x")
    assert_includes err.message, "modal_store"
  end

  def test_error_countdown_binds_the_factory_to_the_seconds_and_the_store
    doc = render("studio/modals/blocks/error_card", title: "Easy there", message_key: "props.message",
                                                    countdown_key: "props.secondsLeft", modal_store: "hostModals",
                                                    secondary_label: "Dismiss", secondary_close: true)
    card = doc.at_css("[role=alert]")

    assert_equal "studioModalCountdown({ seconds: (props.secondsLeft), store: 'hostModals', autoClose: true })", card["x-data"]
    line = card.at_css("[x-show=counting]")
    assert_equal "Try again in .", line.text.squish
    assert line.at_css("[x-text=waitLabel]"), "the wait is bound to the factory's label"
    assert_equal "off", line["aria-live"], "the ticking label is not re-announced each second inside the alert"
    assert_equal "$store.hostModals.close()", card.at_css("button")["@click"]
  end

  def test_error_countdown_takes_its_words_and_can_stay_open
    card = render("studio/modals/blocks/error_card", title: "Hold on", countdown_key: "12",
                                                     countdown_text: "Back in", auto_close: false).at_css("[role=alert]")
    assert_includes card["x-data"], "autoClose: false"
    assert_equal "Back in .", card.at_css("[x-show=counting]").text.squish
  end

  def test_error_countdown_expression_cannot_close_the_attribute
    # countdown_key is an Alpine EXPRESSION by contract and lands as code; what
    # must not happen is a double quote in it ending the ATTRIBUTE, which turns
    # the rest of the expression into markup.
    card = render("studio/modals/blocks/error_card", title: "x", countdown_key: %(props["secondsLeft"])).at_css("[role=alert]")
    assert_equal %(studioModalCountdown({ seconds: (props["secondsLeft"]), store: 'modals', autoClose: true })), card["x-data"]
    assert_equal "text-center py-6", card["class"], "the class attribute survives the quote"
  end

  def test_error_without_a_countdown_binds_no_factory
    card = render("studio/modals/blocks/error_card", title: "x").at_css("[role=alert]")
    assert_nil card["x-data"]
    assert_nil card.at_css("[x-show=counting]")
  end

  # --- blocks/_change_username: locked ------------------------------------------

  def test_locked_with_a_way_forward_links_there_and_offers_dismiss
    doc = render("studio/modals/blocks/change_username", current_username: "pat", submit_url: "/u",
                 locked: { title: "Enter Contest First", subtitle: "Play one contest to unlock it.",
                           cta_label: "Browse Contests", cta_href: "/contests" })
    root = doc.at_css("[data-username-locked]")

    assert_includes root.text, "Enter Contest First"
    assert_includes root.text, "Play one contest to unlock it."
    link = root.at_css("a")
    assert_equal ["/contests", "$store.modals.close()", "Browse Contests"], [link["href"], link["@click"], link.text]
    assert_equal "Dismiss", root.at_css("button").text
    assert_nil doc.at_css("input"), "a locked card offers no input"
  end

  def test_locked_without_a_way_forward_is_one_dismiss_button_on_the_host_store
    doc = render("studio/modals/blocks/change_username", current_username: "pat", submit_url: "/u",
                 modal_store: "hostModals", locked: { title: "Username locked", dismiss: "Close" })
    buttons = doc.css("button")

    assert_equal 1, buttons.size
    assert_equal ["Close", "$store.hostModals.close()"], [buttons.first.text, buttons.first["@click"]]
    assert_includes buttons.first["class"], "btn-outline"
  end

  def test_locked_refuses_what_it_cannot_draw
    [{ subtitle: "no title" }, { title: "x", cta: "typo" }, "locked"].each do |bad|
      err = refusal("studio/modals/blocks/change_username", current_username: "pat", submit_url: "/u", locked: bad)
      assert_instance_of ArgumentError, err, "locked: #{bad.inspect} must raise"
    end
  end
end
