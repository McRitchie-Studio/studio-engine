# frozen_string_literal: true

# The renders test/views/modal_blocks_baseline_test.rb holds byte-identical to
# studio-engine 0.113.0, one per case, each with every local added after 0.113.0
# UNSET. The goldens in test/fixtures/files/modal_blocks_0.113.0 were written by
# rendering these cases under the RELEASED 0.113.0 gem, resolved from a Gemfile
# of its own (`gem "studio-engine", "0.113.0"`), through the same view setup the
# test uses: ActionView::Base over the gem's app/views, extended with
# Studio::Engine.helpers, with profile_newsletter_path stubbed.
#
# Pure data, so the test and the script that wrote the goldens read one list.
module ModalBlocksBaselineCases
  NewsletterUser = Struct.new(:email, :joined_email_list_at, :left_email_list_at, keyword_init: true)

  # name => [partial, locals, block HTML or nil (a block renders it as a layout)]
  CASES = {
    "error_min"            => ["studio/modals/blocks/error_card", { title: "Still processing" }, nil],
    "error_message"        => ["studio/modals/blocks/error_card", { title: "Oops", message: "It failed", icon_emoji: "⚠️" }, nil],
    "error_key"            => ["studio/modals/blocks/error_card", { title: "Oops", message_key: "props.err", cta_reload: true }, nil],
    "error_event"          => ["studio/modals/blocks/error_card", { title: "Oops", cta_event: "retry", cta_label: "Retry",
                                                                    secondary_label: "Close", secondary_event: "close-it" }, nil],
    "success_min"          => ["studio/modals/blocks/success_card", { title: "Done" }, nil],
    "success_full"         => ["studio/modals/blocks/success_card", { title: "Done", message: "All set", large_title: true,
                                                                      icon_emoji: "🎉", cta_label: "Go", cta_event: "go",
                                                                      secondary_label: "Later", secondary_event: "later",
                                                                      confetti: true }, nil],
    "success_key"          => ["studio/modals/blocks/success_card", { title_key: "props.t", message_key: "props.m", cta_label: "Go",
                                                                      cta_href_key: "props.url", tx_signature_key: "props.tx",
                                                                      tx_solana: true }, nil],
    "success_drain"        => ["studio/modals/blocks/success_card", { title: "Done", cta_label: "Go", cta_href_key: "props.url",
                                                                      cta_drain: true, auto_redirect_url_key: "props.url",
                                                                      auto_redirect_seconds: 3 }, nil],
    "success_redirect"     => ["studio/modals/blocks/success_card", { title: "Done", cta_label: "Go", cta_event: "go",
                                                                      auto_redirect_url_key: "props.url",
                                                                      tx_signature_key: "props.tx" }, nil],
    "success_block_below"  => ["studio/modals/blocks/success_card", { title: "Done", message: "All set", cta_label: "Go",
                                                                      cta_event: "go" }, "<b>SLOT</b>"],
    "success_block_above"  => ["studio/modals/blocks/success_card", { title: "Done", message: "All set", cta_label: "Go",
                                                                      cta_event: "go", slot_position: :above_cta }, "<b>SLOT</b>"],
    "birthday_min"         => ["studio/modals/blocks/birthday", { submit_url: "/age" }, nil],
    "birthday_full"        => ["studio/modals/blocks/birthday", { submit_url: "/age", min_age: 18, state: "CA", title: "Age",
                                                                  intro: "Hi", fine_print: "Fine", modal_store: "modals",
                                                                  demo: true }, nil],
    "change_username_min"  => ["studio/modals/blocks/change_username", { current_username: "pat", submit_url: "/u" }, nil],
    "change_username_full" => ["studio/modals/blocks/change_username", { current_username: "pat", submit_url: "/u",
                                                                          finalize_url: "/f", saved_event: "saved",
                                                                          leveling: false, description: "Yours." }, nil],
    "newsletter_email"     => ["studio/profiles/newsletter_modals",
                               { user: NewsletterUser.new(email: "pat@example.com") }, nil],
    "newsletter_no_email"  => ["studio/profiles/newsletter_modals", { user: NewsletterUser.new(email: nil) }, nil]
  }.freeze

  # The render, the same way in the test and in the script that wrote the goldens.
  def self.render(view, partial, locals, block)
    if block
      view.render(layout: partial, locals: locals) { block.html_safe }
    else
      view.render(partial: partial, locals: locals)
    end
  end
end
