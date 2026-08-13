# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

# [integration] Studio::NewsletterMailer — the "you're on the list" email.
#
# The property that decides whether this primitive is worth shipping is that a
# host GETS it. The engine's top-level UserMailer is shadowed outright by any
# host that defines its own (McRitchie Studio does), so an action added there
# reaches exactly the apps that never customised their mail — the opposite of
# who a shared primitive is for. Namespacing is the fix, and it is asserted
# below rather than assumed.
class NewsletterEmailTest < ActiveSupport::TestCase
  RECIPIENT = "reader@example.test"

  def setup
    @previous_url_options = ActionMailer::Base.default_url_options
    ActionMailer::Base.default_url_options = { host: "example.test" }
  end

  def teardown
    ActionMailer::Base.default_url_options = @previous_url_options
    Studio::EmailCatalog.reset!
  end

  def mail(**options) = Studio::NewsletterMailer.subscribed(RECIPIENT, **options)

  def html(**options)
    message = mail(**options)
    (message.html_part&.body || message.body).to_s
  end

  # --- it survives a host that owns its own UserMailer ----------------------

  # The bug this prevents is silent: put `subscribed` on the engine's UserMailer
  # and it works in the dummy app and in a plain host, then vanishes in
  # McRitchie Studio with a NoMethodError at send time.
  test "the mailer is namespaced so a host's own UserMailer cannot shadow it" do
    assert_equal "Studio::NewsletterMailer", Studio::NewsletterMailer.name
    assert_operator Studio::NewsletterMailer, :<, ActionMailer::Base

    source_path = Studio::NewsletterMailer.instance_method(:subscribed).source_location.first
    assert_includes source_path, "app/mailers/studio/",
      "a top-level mailer is shadowed by the host's file of the same name"
  end

  # --- it addresses a stranger safely ---------------------------------------

  test "it sends to the subscriber with the app in the subject" do
    message = mail

    assert_equal [RECIPIENT], message.to
    assert_includes message.subject, Studio.app_name
  end

  # Read the DECODED text, not the raw HTML: an apostrophe renders as &#39;, so
  # asserting the source for "You're subscribed!" fails on an email that says
  # exactly that.
  def visible_text(**options) = Nokogiri::HTML(html(**options)).text

  # Subscribing is often the FIRST contact — there may be no account and no name.
  test "it greets warmly without a name rather than guessing at one" do
    assert_includes visible_text, "You're subscribed!"
    refute_includes visible_text, "Welcome !"
  end

  test "it uses the first name when one is supplied" do
    body = html(name: "Mason Whitfield")

    assert_includes body, "Welcome Mason!"
    refute_includes body, "Whitfield", "the banner greets by first name; a full name overflows it"
  end

  # --- the banner is the layered one ----------------------------------------

  test "the banner is layered artwork with the greeting live on top" do
    body = html(name: "Mason")

    assert_includes body, "newsletter-subscribed-background",
      "the newsletter's own artwork should render, not another email's"
    assert_includes body, "Welcome Mason!",
      "the greeting must be live HTML — baking it into the image is what layering replaced"
  end

  # Outlook renders through Word, which ignores background-image. Without the VML
  # block the banner is a blank cell there — and Outlook is precisely the client
  # that cannot be spot-checked by looking at Gmail.
  test "the banner reaches outlook" do
    body = html

    assert_includes body, "v:rect", "no VML block — Outlook shows an empty banner"
    assert_includes body, "urn:schemas-microsoft-com:vml"
  end

  test "the banner is layered-native and needs no flat fallback asset" do
    entry = Studio::EmailCatalog.entry("newsletter_subscribed")

    assert_nil entry.default_asset,
      "a baked-in copy of the same picture is a second thing to keep in sync"
    assert_equal "emails/newsletter-subscribed-background.gif", entry.background
  end

  # An inherited email with no preview builder is a row on every host's manager
  # that cannot be looked at — and turf-monster asserts every registered email
  # carries one. The engine can supply this builder because the mailer takes a
  # bare address: no host sample data is involved.
  test "the newsletter ships its own preview builder" do
    entry = Studio::EmailCatalog.entry("newsletter_subscribed")

    assert entry.previewable?, "an inherited email with no preview cannot be viewed on any host"
    assert_includes Studio::EmailCatalog.preview_subject("newsletter_subscribed").to_s,
                    Studio.app_name, "the builder should render a real message"
  end

  # --- the way out ----------------------------------------------------------

  # An unsubscribe link that goes nowhere is worse than none: it spends the
  # reader's trust and then fails them.
  test "no unsubscribe line renders when the host wired no url" do
    body = html

    refute_includes body, "Unsubscribe"
  end

  test "the unsubscribe line renders when the host wired a real url" do
    body = html(unsubscribe_url: "https://example.test/unsubscribe/abc")

    document = Nokogiri::HTML(body)
    link = document.css("a").find { |a| a["href"].to_s.include?("/unsubscribe/") }

    refute_nil link, "an unsubscribe url was supplied but no link rendered"
    assert_includes link["style"].to_s, Studio.theme_primary,
      "actionable text is brand-coloured, matching the sign-in email"
  end

  test "the plain-text part carries the same way out" do
    text = mail(unsubscribe_url: "https://example.test/unsubscribe/abc").text_part&.body.to_s

    refute_empty text, "a bulk email without a text part lands in spam filters harder"
    assert_includes text, "https://example.test/unsubscribe/abc"
  end

  # --- it stays the recipient's email, not a template -----------------------

  test "it tells the reader which address it was sent to" do
    assert_includes html, RECIPIENT,
      "someone with several addresses cannot act on 'you subscribed' without knowing which"
  end
end
