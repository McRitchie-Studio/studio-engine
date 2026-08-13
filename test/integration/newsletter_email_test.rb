# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"
require "digest"
require "uri"

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

  # --- the engine puts no branding of its own in a host's newsletter --------
  #
  # THE BUG THESE EXIST FOR. This entry seeded logo: "emails/logo-horizontal.png"
  # — the white McRITCHIE STUDIO wordmark — and Studio::EmailCatalog.register
  # merges on `logo.presence`, so a host registering this email to relabel it or
  # to attach a preview inherited the wordmark WITHOUT NAMING IT. Its branded
  # newsletter would then have gone out under Studio's mark. turf-monster was
  # already bitten by the same mechanism on magic_link.
  #
  # WHY THESE ASSERT RESOLUTION AND NOT SPELLING. A rendered src looks identical
  # whether the host owns the file or the gem does, and that indistinguishability
  # IS the bug: turf named "emails/logo-horizontal.png", shipped no such file,
  # and Sprockets quietly served the engine's copy. A test reading the src string
  # would have called that correct. So each <img> is taken back to a FILE on the
  # engine's own asset load path — the same directories a consumer's pipeline
  # searches, because a Rails engine contributes them.
  #
  # WHY THE ALT TEXT IS NOT EVIDENCE. Studio::Banner sets logo_alt from
  # Studio.app_name, so it always agrees with the HOST and never with the pixels.
  # turf's read "Turf Monster" over the Studio wordmark for weeks.
  ENGINE_ASSET_DIRS = Studio::Engine.paths["app/assets"].existent.freeze

  # The file the engine would serve for a rendered URL, or nil when the engine
  # ships nothing by that name.
  def engine_file_behind(url)
    logical = URI.parse(url.to_s).path.to_s.delete_prefix("/")
    return nil if logical.empty?

    ENGINE_ASSET_DIRS.map { |dir| File.join(dir, logical) }.find { |path| File.file?(path) }
  end

  # An asset this gem ships, ASSERTED to exist rather than assumed.
  #
  # Silence is the failure mode all through this path:
  # Studio::EmailCatalog#asset_path rescues StandardError to nil,
  # absolute_asset_url does the same, and _layered_banner.html.erb gates every
  # background path on `background_url.present?`. An upstream rename therefore
  # raises nothing and the email quietly ships a flat colour box. A guard built
  # on "we found no wordmark" would go quiet with it.
  def engine_asset(logical)
    path = File.join(Studio::Engine.root, "app/assets/images", logical)
    assert File.file?(path), "#{logical} must ship in the gem, or the guards below prove nothing"
    path
  end

  # POSITIVE CONTROL for every absence asserted below: an email whose banner
  # failed to render carries no wordmark either, and would pass them all.
  test "the banner still draws the newsletter's own artwork from the gem" do
    cell = Nokogiri::HTML(html(name: "Mason")).css("td[background]").first

    refute_nil cell, "the layered banner did not render — the absence guards below would pass on an empty email"
    assert_equal engine_asset("emails/newsletter-subscribed-background.gif"),
                 engine_file_behind(cell["background"]),
                 "the background must resolve to the newsletter's own artwork, not another email's"
  end

  # THE GUARD. Artwork riding the gem is the point of the seed — a new app sends
  # good-looking mail on day one. A WORDMARK riding the gem is somebody else's
  # identity in this app's inbox, and the line is drawn there.
  test "the newsletter sends no image the engine owns" do
    wordmark = Digest::SHA256.file(engine_asset("emails/logo-horizontal.png")).hexdigest
    refute_nil Nokogiri::HTML(html(name: "Mason")).css("td[background]").first,
      "the banner did not render, so finding no engine image proves nothing"

    Nokogiri::HTML(html(name: "Mason")).css("img").each do |img|
      file = engine_file_behind(img["src"])
      next if file.nil?

      # By BYTES, so renaming the wordmark and seeding the new name is caught
      # too — the property is that these pixels never reach a host's inbox.
      refute_equal wordmark, Digest::SHA256.file(file).hexdigest,
        "the McRitchie Studio wordmark is in this email (alt=#{img["alt"].inspect}, which names the HOST and proves nothing)"
      flunk "the engine put its own #{File.basename(file)} in a host's newsletter"
    end
  end

  # ACCEPTANCE, stated as the consumer sees it: a host registers this email the
  # ordinary way — relabelling it, attaching its own preview — and names no logo.
  # Before the fix that host inherited the Studio wordmark and had to pass
  # logo: "" to get rid of it, which the next maintainer would tidy away.
  test "a host registering this email inherits no Studio mark" do
    Studio::EmailCatalog.register("newsletter_subscribed",
                                  label: "Welcome to the list",
                                  description: "Our own newsletter welcome.")

    assert_nil Studio::EmailCatalog.entry("newsletter_subscribed").logo,
      "omitting logo: inherits the seed, so the seed must carry no mark"
    assert_nil Studio::EmailCatalog.resolved_logo_url("newsletter_subscribed")

    document = Nokogiri::HTML(html(name: "Mason"))
    refute_nil document.css("td[background]").first, "the host's banner did not render"
    assert_empty document.css("img").filter_map { |img| engine_file_behind(img["src"]) },
      "a host that named no logo is sending one the engine owns"
  ensure
    Studio::EmailCatalog.reset!
  end

  # The other half, or the guard above would also pass on an engine that had
  # simply lost the ability to draw a logo at all.
  test "a host that names its own mark still gets one" do
    Studio::EmailCatalog.register("newsletter_subscribed", logo: "emails/our-own-mark.png")

    sources = Nokogiri::HTML(html(name: "Mason")).css("img").map { |img| img["src"].to_s }

    assert sources.any? { |src| src.end_with?("/emails/our-own-mark.png") },
      "an app that asked for its own logo must get it: #{sources.inspect}"
    assert_empty sources.filter_map { |src| engine_file_behind(src) },
      "the host named its own file, so nothing here may resolve out of the gem"
  ensure
    Studio::EmailCatalog.reset!
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

  # --- it can be sent from a marketing address ------------------------------

  # WHY THIS IS NOT COSMETIC. This is the only MARKETING email the engine sends;
  # everything else is transactional, sign-in links included. A host that keeps
  # a separate marketing from-address does it so that complaints and
  # unsubscribes against a newsletter never accrue to the address someone needs
  # to get back into their account. turf-monster keeps exactly that separation
  # (marketing_from), so without this parameter adopting this mailer would have
  # cost it — a deliverability regression arriving disguised as an adoption.
  test "a host can send it from its own marketing address" do
    message = mail(from: "news@marketing.example.test")

    assert_equal [ "news@marketing.example.test" ], message.from
  end

  # The default must be untouched: every app already sending this email keeps
  # sending it from wherever it was.
  # Asserts the PROPERTY, not a re-derivation of where the default lives: the
  # engine resolves it through a per-message lambda on ApplicationMailer, so
  # there is no static value to compare against — and a test that recomputed the
  # lambda would pass even if the mailer stopped consulting it.
  test "omitting the address leaves the host's default from in place" do
    default = mail.from.to_a

    refute_empty default,
      "a host that never asks for a marketing address must be unaffected"
    refute_includes default, "news@marketing.example.test",
      "the override must not leak into a send that did not ask for it"
  end

  # THE TRAP THIS GUARDS. `mail(from: nil)` does NOT fall back to the default —
  # ActionMailer treats the explicit nil as a set header and sends with NO From
  # at all, which most receivers reject outright. Verified against ActionMailer
  # 8.1 before this was written, which is why the header hash is built
  # conditionally rather than always passing the parameter through.
  test "an explicitly blank address falls back rather than sending with no From" do
    refute_empty mail(from: nil).from.to_a,
      "an email with no From is rejected, not merely unbranded"
    refute_empty mail(from: "").from.to_a
  end

  # --- it stays the recipient's email, not a template -----------------------

  test "it tells the reader which address it was sent to" do
    assert_includes html, RECIPIENT,
      "someone with several addresses cannot act on 'you subscribed' without knowing which"
  end
end
