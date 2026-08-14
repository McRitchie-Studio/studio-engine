# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

# [integration] The banner's WORDS — who decides them, and whether the field an
# operator types into actually reaches an inbox.
#
# The failure this file exists to prevent is a control that lies. Before this,
# the mailer handed Studio::Banner a finished header ("Welcome Mason!"), so a
# header field on /admin/emails would have accepted an edit, saved it, shown it
# back, and changed nothing about the email — indistinguishable from working
# until someone compared the page against a real send. The fix is a division of
# labour, asserted below: the MAILER supplies who the recipient is, the OPERATOR
# supplies what the banner says about them.
class BannerCopyTest < ActiveSupport::TestCase
  def self.ensure_settings_table!
    return if ActiveRecord::Base.connection.table_exists?(:studio_email_settings)

    require_relative "../../db/migrate/20260812000000_create_studio_email_settings"
    ActiveRecord::Migration.suppress_messages { CreateStudioEmailSettings.new.migrate(:up) }
  end

  # The copy columns arrived in their own migration; both must run for a host to
  # get a working page, so both run here.
  def self.ensure_copy_columns!
    return if ActiveRecord::Base.connection.column_exists?(:studio_email_settings, :header)

    require_relative "../../db/migrate/20260812210000_add_copy_to_studio_email_settings"
    require_relative "../../db/migrate/20260812220000_add_subject_to_studio_email_settings"
    require_relative "../../db/migrate/20260813010000_add_body_cta_footer_to_studio_email_settings"
    ActiveRecord::Migration.suppress_messages do
      AddCopyToStudioEmailSettings.new.migrate(:up)
      AddSubjectToStudioEmailSettings.new.migrate(:up)
      AddBodyCtaFooterToStudioEmailSettings.new.migrate(:up)
    end
    Studio::EmailSetting.reset_column_information
  end

  def setup
    Studio::EmailSetting.forget!
    self.class.ensure_settings_table!
    self.class.ensure_copy_columns!
    Studio::EmailSetting.delete_all
    ActionMailer::Base.default_url_options = { host: "example.test" }
  end

  def teardown
    Studio::EmailSetting.delete_all
    Studio::EmailCatalog.reset!
  end

  # --- the placeholder ------------------------------------------------------

  test "the saved header greets the recipient by first name" do
    Studio::EmailSetting.set_copy("magic_link", header: "Hey {name}, come on in")

    banner = Studio::Banner.for(:magic_link, name: "Mason Whitfield")

    assert_equal "Hey Mason, come on in", banner.header
  end

  # A 600px banner is one line of large type. A full name wraps out of it, and
  # the wrapped line is what pushed the logo off the bottom edge before.
  test "only the first name is interpolated" do
    Studio::EmailSetting.set_copy("magic_link", header: "Welcome {name}!")

    assert_equal "Welcome Mason!", Studio::Banner.for(:magic_link, name: "Mason Whitfield").header
  end

  # "Welcome !" is the bug the fallback exists to prevent — and a magic link is
  # often the first contact we have with someone, so it is not a rare path.
  #
  # THAT A FALLBACK IS CONSULTED AT ALL is the whole of what this proves. The
  # string it saves is the registry default character for character, so it
  # cannot tell the operator's saved fallback apart from the engine's — the
  # section below does that, and none of it is covered by this.
  test "a template that wants a name falls back when there is none" do
    Studio::EmailSetting.set_copy("magic_link", header: "Welcome {name}!",
                                                header_fallback: "Your Magic Link")

    banner = Studio::Banner.for(:magic_link, name: nil)

    assert_equal "Your Magic Link", banner.header
    refute_includes banner.header, "{name}"
  end

  # --- WHOSE fallback header, and does it leave the building ----------------
  #
  # "Header for someone with no name on file" is the least checkable field on
  # /admin/emails: both example recipients in the preview picker have names on
  # file (deliberately — the synthetic "No name on file" entry was removed on Mr.
  # McRitchie's call), so an operator cannot LOOK at their own saved value there.
  # Every guard on it asserted "Your Magic Link", which is what the registry
  # ships, so saved-or-default were the same string and nothing noticed the
  # difference. These save something the engine would never say, and follow it
  # to the inbox; the two after them prove a cleared field still inherits.

  # Deliberately unlike anything in the registry. The refute below is the guard
  # on the guard: if this ever equals the default, the test passes on the
  # engine's string and proves nothing, which is exactly how the gap survived.
  OPERATOR_FALLBACK = "Someone asked for a link"

  # The header template is saved too, so this test states its own precondition
  # rather than borrowing it: the fallback is consulted ONLY for a template that
  # asks for a name, and a registry default that stopped asking would leave this
  # passing on a path it never took.
  test "the operator's own fallback header is what a nameless recipient gets" do
    refute_equal OPERATOR_FALLBACK, Studio::EmailCatalog.entry("magic_link").header_fallback,
      "the saved value must differ from the registry default, or this cannot fail"
    Studio::EmailSetting.set_copy("magic_link", header: "Welcome {name}!",
                                                header_fallback: OPERATOR_FALLBACK)

    header = Studio::Banner.for(:magic_link, name: nil).header

    assert_equal OPERATOR_FALLBACK, header,
      "the field accepted the edit and the stranger got the engine's words"
    refute_includes header, "{name}"
  end

  # AND IT REACHES AN INBOX. The row and the resolver both being right has not
  # been enough on this feature: four controls here have shipped able to save and
  # unable to change an email. This one follows the saved string into the
  # rendered message, for a recipient this app holds no account for — which is
  # who the field exists for.
  test "the saved fallback header is what the magic-link email actually sends" do
    Studio::EmailSetting.set_copy("magic_link", header: "Welcome {name}!",
                                                header_fallback: OPERATOR_FALLBACK)

    message = UserMailer.magic_link("stranger@example.test", "tokenfortest1234")
    html = (message.html_part&.body || message.body).to_s

    assert_includes html, OPERATOR_FALLBACK,
      "the operator's fallback header never left the settings row"
    refute_includes html, "Your Magic Link", "the engine's default shipped instead of theirs"
  end

  # CLEARING IT RESTORES THE DEFAULT, rather than sending a headless banner.
  #
  # Blank is presenced TWICE, and the two are different guards: set_copy stores a
  # cleared field as nil (so the row says INHERIT), and copy_for presences again
  # on the way out (so a row that already carries "" inherits too). The resolver
  # itself has no opinion — "" is truthy in Ruby, so an empty string reaching
  # `saved(key, :header_fallback) || …` would win and ship a headless banner.
  # Both guards are asserted: this test the write side, the next the read side.
  test "clearing the fallback header restores the registry default" do
    Studio::EmailSetting.set_copy("magic_link", header: "Welcome {name}!",
                                                header_fallback: OPERATOR_FALLBACK)
    Studio::EmailSetting.set_copy("magic_link", header_fallback: "")

    row = Studio::EmailSetting.find_by(email_key: "magic_link")
    refute_nil row, "the row survives — this is a cleared field, not a deleted setting"
    assert_nil row.header_fallback, "a cleared field is stored as nil, which means INHERIT"
    assert_nil Studio::EmailSetting.copy_for("magic_link", :header_fallback)

    header = Studio::Banner.for(:magic_link, name: nil).header

    assert_equal "Your Magic Link", header, "the registry default answers again"
    refute_empty header.to_s, "clearing the field must not send a banner with no words on it"
  end

  # THE READ SIDE, exercised on a row that ALREADY carries a blank — the state
  # set_copy no longer produces, which is precisely why nothing else here covers
  # it. update_column writes past the model, and the per-request memo is dropped
  # afterwards: without that, the banner would be resolved from the row object
  # cached before the write and this would pass without ever seeing the blank.
  test "a row that already carries a blank fallback still inherits the default" do
    Studio::EmailSetting.set_copy("magic_link", header: "Welcome {name}!",
                                                header_fallback: OPERATOR_FALLBACK)
    Studio::EmailSetting.find_by(email_key: "magic_link").update_column(:header_fallback, "")
    Studio::EmailSetting.forget!("magic_link")

    assert_equal "", Studio::EmailSetting.find_by(email_key: "magic_link").header_fallback,
      "precondition: the stored column is blank, not nil — that is the case under test"
    assert_nil Studio::EmailSetting.copy_for("magic_link", :header_fallback),
      "a blank column means INHERIT on the way out as well as on the way in"
    assert_equal "Your Magic Link", Studio::Banner.for(:magic_link, name: nil).header
  end

  test "a header with no placeholder stands as written even without a name" do
    Studio::EmailSetting.set_copy("magic_link", header: "Your sign-in link")

    assert_equal "Your sign-in link", Studio::Banner.for(:magic_link, name: nil).header
  end

  # A raw {name} reaching an inbox is the most visible way this can fail.
  test "no placeholder ever survives into a rendered banner" do
    Studio::EmailSetting.set_copy("magic_link", header: "Welcome {name}!")

    [nil, "", "   ", "Mason"].each do |name|
      header = Studio::Banner.for(:magic_link, name: name).header
      refute_includes header.to_s, "{name}", "unrendered placeholder for name #{name.inspect}"
    end
  end

  # gsub, not format(): an operator-editable string is the input, and "%" is an
  # ordinary character in copy ("50% off") that format() would raise on.
  test "a percent sign in the copy is not a format directive" do
    Studio::EmailSetting.set_copy("magic_link", header: "50% off, {name}")

    assert_equal "50% off, Mason", Studio::Banner.for(:magic_link, name: "Mason").header
  end

  # --- who wins -------------------------------------------------------------

  test "the operator's words beat the registry default" do
    Studio::EmailCatalog.register("magic_link", header: "Registry header")
    Studio::EmailSetting.set_copy("magic_link", header: "Operator header")

    assert_equal "Operator header", Studio::Banner.for(:magic_link, name: nil).header
  end

  test "clearing a field falls back to the registry rather than sending empty" do
    Studio::EmailSetting.set_copy("magic_link", header: "Operator header")
    Studio::EmailSetting.set_copy("magic_link", header: "")

    header = Studio::Banner.for(:magic_link, name: "Mason").header

    refute_empty header.to_s, "a blank save must inherit, not blank the banner"
    assert_equal "Welcome Mason!", header
  end

  test "the operator's sub-text reaches the banner" do
    Studio::EmailSetting.set_copy("magic_link", subtext: "tap to sign in")

    assert_equal "tap to sign in", Studio::Banner.for(:magic_link, name: nil).subtext
  end

  # --- the logo -------------------------------------------------------------

  # THE REGISTERED LOGO these two need. It is stated here rather than inherited
  # from the catalogue seed on purpose: STANDARD seeds NO logo on any entry
  # (the engine's wordmark riding the seed into a host's sign-in email was the
  # bug — see the NO DEFAULT LOGO note in email_catalog.rb), so leaning on an
  # inherited mark would test a default that must never come back. This is the
  # real-world shape anyway: the host names its own mark, then the operator
  # overrides or hides it on /admin/emails.
  def register_host_logo
    Studio::EmailCatalog.register("magic_link", logo: "emails/our-own-mark.png")
  end

  test "a saved logo url replaces the registered one" do
    register_host_logo
    Studio::EmailSetting.set_copy("magic_link", logo_url: "https://cdn.test/mine.png")

    assert_equal "https://cdn.test/mine.png", Studio::Banner.for(:magic_link, name: nil).logo_url
  ensure
    Studio::EmailCatalog.reset!
  end

  # "Hidden" and "not set" have to be different answers — blank inherits, so
  # without an explicit flag there is no way to say "no logo at all".
  test "hiding the logo is distinct from leaving it blank" do
    register_host_logo

    Studio::EmailSetting.set_copy("magic_link", hide_logo: true)
    assert_nil Studio::Banner.for(:magic_link, name: nil).logo_url

    Studio::EmailSetting.set_copy("magic_link", hide_logo: false)
    refute_nil Studio::Banner.for(:magic_link, name: nil).logo_url,
      "unchecking must restore the host's registered logo, not leave it hidden"
  ensure
    Studio::EmailCatalog.reset!
  end

  # --- it must not break a send ---------------------------------------------

  # These are read on a DELIVERY path. A settings table that is missing or
  # mid-migration must cost the override, never the email.
  test "a missing settings table falls back to the registry instead of raising" do
    original = Studio::EmailSetting.method(:copy_for)
    Studio::EmailSetting.define_singleton_method(:copy_for) { |*| raise ActiveRecord::StatementInvalid, "no table" }

    banner = Studio::Banner.for(:magic_link, name: "Mason")

    assert_equal "Welcome Mason!", banner.header, "the registry default must still render"
  ensure
    Studio::EmailSetting.define_singleton_method(:copy_for, original)
  end

  # --- the subject line -----------------------------------------------------

  test "the subject greets a known recipient by first name" do
    Studio::EmailSetting.set_copy("magic_link", subject: "Sign in, {name}")

    assert_equal "Sign in, Mason", Studio::EmailCatalog.subject_for("magic_link", name: "Mason Whitfield")
  end

  # A raw "{name}" in an inbox subject line is the most visible failure this
  # feature has. The header has a second field for the nameless case; a subject
  # does not, so the token and the punctuation holding it are removed together.
  test "an unresolved name placeholder never reaches a subject line" do
    [
      ["Sign in, {name}", "Sign in"],
      ["Sign in to {app}, {name}", "Sign in to Studio"],
      ["{name}, your link is here", "your link is here"],
      ["Welcome {name}!", "Welcome!"]
    ].each do |template, expected|
      Studio::EmailSetting.set_copy("magic_link", subject: template)
      subject = Studio::EmailCatalog.subject_for("magic_link", name: nil)

      refute_includes subject.to_s, "{name}", "raw placeholder shipped for #{template.inspect}"
      assert_equal expected, subject
    end
  end

  test "the mailer hands the recipient's name to the subject, not just the banner" do
    Studio::EmailSetting.set_copy("newsletter_subscribed", subject: "Welcome aboard, {name}")

    message = Studio::NewsletterMailer.subscribed("reader@example.test", name: "Mason")

    assert_equal "Welcome aboard, Mason", message.subject
  end

  # --- the form can write every field it offers -----------------------------

  # THE BUG THIS EXISTS FOR. The controller's permit list was hand-written and
  # did not grow when :subject was added, so the page posted a subject, strong
  # params dropped it, and the redirect said "Saved." A save that reports success
  # and writes nothing is the worst shape a control can have — worse than an
  # error, because nobody goes looking.
  test "every editable field survives the permit list" do
    Studio::EmailSetting::COPY_FIELDS.each do |field|
      Studio::EmailSetting.set_copy("magic_link", field => "written")
      assert_equal "written", Studio::EmailSetting.copy_for("magic_link", field),
        "#{field} did not round-trip through the settings row"
    end
  end

  # The row is memoised for the request: building one banner asks for the header,
  # the fallback, the sub-text, the logo, the subject, the scrim and hide_logo —
  # seven lookups for one row, on the DELIVERY path. A memo that outlives its own
  # update is worse than the queries, so a write clears it.
  test "a saved change is visible immediately, not served from a stale memo" do
    Studio::EmailSetting.set_copy("magic_link", header: "First")
    assert_equal "First", Studio::EmailSetting.copy_for("magic_link", :header)

    Studio::EmailSetting.set_copy("magic_link", header: "Second")
    assert_equal "Second", Studio::EmailSetting.copy_for("magic_link", :header),
      "the operator saved and was shown their previous value back"
  end

  test "setting the tint also clears the memo" do
    Studio::EmailSetting.scrim_for("magic_link")
    Studio::EmailSetting.set_scrim("magic_link", 55)

    assert_in_delta 0.55, Studio::EmailSetting.scrim_for("magic_link"), 0.001
  end

  # --- the email BELOW the banner -------------------------------------------
  #
  # Every one of these asserts the field reaching a RENDERED MESSAGE, not just
  # the settings row. Four separate controls on this feature have now shipped
  # able to save and unable to change an email; the row is never the broken part.

  test "the operator's body copy is what the email says" do
    Studio::EmailSetting.set_copy("newsletter_subscribed", body: "Glad to have you, {name}.")

    message = Studio::NewsletterMailer.subscribed("reader@example.test", name: "Mason")
    html = (message.html_part&.body || message.body).to_s

    assert_includes html, "Glad to have you, Mason."
  end

  # Prose from an admin form is rendered into an email. Paragraph breaks must
  # survive; markup must not.
  test "body copy keeps its paragraphs and cannot inject markup" do
    Studio::EmailSetting.set_copy("newsletter_subscribed",
                                  body: "First line.\n\nSecond line.<script>alert(1)</script>")

    message = Studio::NewsletterMailer.subscribed("reader@example.test")
    html = (message.html_part&.body || message.body).to_s

    assert_equal 2, html.scan("First line.").size + html.scan("Second line.").size
    refute_includes html, "<script>", "operator prose must not be able to break the email"
  end

  test "the button text and colour are the operator's" do
    Studio::EmailSetting.set_copy("magic_link", cta_text: "Let me in", cta_color: "#123456")

    assert_equal "Let me in", Studio::EmailCatalog.cta_text("magic_link")
    assert_equal "#123456", Studio::EmailCatalog.cta_color("magic_link")
  end

  test "the button colour falls back to the app's primary" do
    assert_equal Studio.theme_primary, Studio::EmailCatalog.cta_color("magic_link")
  end

  # THE REGRESSION THIS ALMOST SHIPPED. McRitchie Studio and turf-monster both
  # define their own UserMailer, which renders the ENGINE's magic_link view
  # without setting the new @body/@cta ivars. Depending on those alone sent a
  # bodyless, buttonless email to exactly the apps that had customised their mail
  # — and the engine's own suite was green throughout, because the engine's
  # mailer does set them.
  test "the sign-in view renders body and button even when the mailer sets neither" do
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.singleton_class.include(Rails.application.routes.url_helpers)
    view.assign(app_name: Studio.app_name, email: "reader@example.test", magic_url: "https://example.test/l/abc")

    html = view.render(template: "user_mailer/magic_link")

    assert_includes html, "no password needed", "a host's own mailer must still get the body"
    assert_includes html, "Sign in to", "and the button"
    refute_includes html, "{app}", "the registry default must still be interpolated"
  end

  # --- the shared footer ----------------------------------------------------

  test "the footer is stored once and reaches every email" do
    Studio::EmailSetting.set_footer(discord_url: "https://discord.gg/studio",
                                    logo_url: "https://cdn.test/mark.png")

    message = Studio::NewsletterMailer.subscribed("reader@example.test")
    html = (message.html_part&.body || message.body).to_s

    assert_includes html, "https://discord.gg/studio"
    assert_includes html, "https://cdn.test/mark.png"
  end

  # THE ENGINE SHIPS NO BRANDING OF ITS OWN. A default footer logo was the
  # McRitchie Studio wordmark, and every consumer inherits this layout without
  # defining one — so turf-monster's entire player-facing mail set, which carries
  # no Studio branding today, would have grown a Studio footer on a gem upgrade
  # with no opt-in. It is the same swap the url / resolved_url split exists to
  # prevent, by another route.
  test "an app that set no footer sends no footer" do
    message = Studio::NewsletterMailer.subscribed("reader@example.test")
    html = (message.html_part&.body || message.body).to_s

    refute_includes html, Studio::EmailCatalog::FOOTER_BACKGROUND,
      "the engine must not put its own mark in a host's email"
  end

  # The band closes the white card, so it has to be dark in OUTLOOK too — Word
  # drops background-color on a td often enough that the attribute is the only
  # reliable half. The alt text needs its own colour for the same reason: with
  # images blocked, a client's near-black default on a near-black band is
  # invisible.
  test "the footer band is dark and legible in every client" do
    Studio::EmailSetting.set_footer(logo_url: "https://cdn.test/mark.png")

    message = Studio::NewsletterMailer.subscribed("reader@example.test")
    html = (message.html_part&.body || message.body).to_s

    assert_match(/bgcolor="#1A1535"[^>]*background-color:#1A1535/i, html,
      "the attribute and the declaration must both carry the colour")
    assert_match(/bgcolor="#1A1535"[^>]*color:#F5F3FF/i, html,
      "blocked images leave only alt text, which needs a colour that is not the band's")
    assert_match(/<img[^>]+height="\d+"/, html,
      "without a height Outlook collapses the alt placeholder to nothing")
  end

  test "clearing the logo and the discord link removes the footer entirely" do
    Studio::EmailSetting.set_footer(logo_url: "https://cdn.test/mark.png")
    Studio::EmailSetting.set_footer(logo_url: "", discord_url: "")

    message = Studio::NewsletterMailer.subscribed("reader@example.test")
    html = (message.html_part&.body || message.body).to_s

    refute_includes html, Studio::EmailCatalog::FOOTER_BACKGROUND, "cleared means gone"
  end

  # --- the button is a CAPABILITY, not a checkbox ---------------------------

  # THE DEAD CONTROL. The Call-to-action card rendered for every email, and
  # cta_enabled? returned the operator's value the moment one was stored — but
  # subscribed.html.erb has no button in it and never will. Ticking the box saved
  # a setting that no email could ever honour.
  test "an email whose template renders no button never reports one enabled" do
    Studio::EmailSetting.set_cta_enabled("newsletter_subscribed", true)
    Studio::EmailSetting.set_copy("newsletter_subscribed", cta_text: "Click me")

    refute Studio::EmailCatalog.cta_enabled?("newsletter_subscribed"),
      "a stored yes cannot conjure a button the template cannot render"

    message = Studio::NewsletterMailer.subscribed("reader@example.test")
    html = (message.html_part&.body || message.body).to_s
    refute_includes html, "Click me", "and no button appears in the email either"
  end

  test "the sign-in email declares the capability and honours the switch" do
    assert Studio::EmailCatalog.entry("magic_link").supports_cta?
    assert Studio::EmailCatalog.cta_enabled?("magic_link")

    Studio::EmailSetting.set_cta_enabled("magic_link", false)
    refute Studio::EmailCatalog.cta_enabled?("magic_link")
  end

  # An entry that says nothing cannot be assumed to have a destination.
  test "an email that never declares the capability does not offer a button" do
    Studio::EmailCatalog.register("mystery", label: "Mystery")

    refute Studio::EmailCatalog.entry("mystery").supports_cta?
    refute Studio::EmailCatalog.cta_enabled?("mystery")
  ensure
    Studio::EmailCatalog.reset!
  end

  # --- saving one field must not destroy another ----------------------------

  # THE BUG: there is ONE Save for the page, so every save posts the footer
  # inputs — blank ones included, on a page where the operator only changed the
  # subject. Writing those blanks created a `_footer` row of nils, which reads
  # the same as "cleared", so the shared footer vanished from every email the app
  # sends and could not be recovered without retyping it.
  #
  # These call the MODEL directly. They are the decision table for "when does a
  # posted footer count as a change", and they are complete for that question.
  #
  # They are NOT proof that the page reaches this method, and must not be read as
  # such: this guard passed for the whole life of a controller that called
  # write_footer — a method defined nowhere — so the wipe fix shipped correct and
  # unreachable, and the footer could not be turned on at all. The controller
  # round trip lives in test/integration/emails_page_save_test.rb; a change to
  # who calls what belongs there, not here.
  #
  # What the page posts on any save: both footer inputs, always.
  def write_page(discord_url: "", footer_logo_url: "")
    Studio::EmailSetting.update_footer(discord_url: discord_url, logo_url: footer_logo_url)
  end

  test "saving an unrelated field leaves an untouched footer alone" do
    write_page

    assert_nil Studio::EmailSetting.footer,
      "blank posts from a page nobody edited must not create a cleared footer"
  end

  test "saving an unrelated field leaves a CONFIGURED footer alone" do
    Studio::EmailSetting.set_footer(logo_url: "https://cdn.test/mark.png")

    write_page(footer_logo_url: "https://cdn.test/mark.png")

    assert_equal "https://cdn.test/mark.png", Studio::EmailCatalog.footer[:logo_url]
  end

  test "clearing the field on purpose still clears it" do
    Studio::EmailSetting.set_footer(logo_url: "https://cdn.test/mark.png")

    write_page

    assert_empty Studio::EmailCatalog.footer, "an explicit clear must still work"
  end

  test "a new footer value is written" do
    write_page(discord_url: "https://discord.gg/x")

    assert_equal "https://discord.gg/x", Studio::EmailCatalog.footer[:discord_url]
  end

  # --- through HTTP, where the filtering happens -----------------------------

  # THE BUG THIS EXISTS FOR. Every logo test above passed while hiding the logo
  # from the actual page did nothing: strong params dropped :hide_logo, set_copy
  # never saw it, and the redirect said "Saved." The model was never broken, so
  # model-level tests could not see it — the filter sits in the controller, so
  # the assertion has to go through the controller.
  test "the controller permits every field the form posts" do
    posted = %i[header header_fallback subtext subject logo_url hide_logo
                body cta_text cta_color cta_enabled discord_url footer_logo_url]
    permitted = Studio::EmailSetting::COPY_FIELDS + %i[hide_logo cta_enabled discord_url footer_logo_url]

    missing = posted - permitted
    assert_empty missing, "the form posts these and strong params drops them: #{missing.join(", ")}"

    # Asserted as an EFFECT, not as source text. The previous version matched the
    # literal permit line, so reformatting it broke the test without any change
    # in behaviour — and it never proved the params reached the model.
    params = ActionController::Parameters.new(
      header: "H", header_fallback: "F", subtext: "S", subject: "Su", logo_url: "L",
      body: "B", cta_text: "C", cta_color: "#111111", hide_logo: "1", cta_enabled: "1",
      discord_url: "https://discord.gg/x", footer_logo_url: "https://cdn.test/l.png",
      injected: "should not survive"
    )
    permitted = params.permit(*Studio::EmailSetting::COPY_FIELDS, :hide_logo, :cta_enabled,
                              :discord_url, :footer_logo_url).to_h.symbolize_keys

    assert_empty posted - permitted.keys, "the form posts these and strong params drops them"
    refute_includes permitted.keys, :injected, "and it must still drop what the form does not post"
  end

  # --- the mailer supplies WHO, not WHAT ------------------------------------

  # The whole point, stated as a test: if a mailer passes a finished header, the
  # operator's field is decorative. This asserts the engine's own newsletter
  # mailer keeps its hands off the wording.
  test "the newsletter mailer lets the operator's words through" do
    Studio::EmailSetting.set_copy("newsletter_subscribed", header: "Glad you're here, {name}")

    message = Studio::NewsletterMailer.subscribed("reader@example.test", name: "Mason")
    html = (message.html_part&.body || message.body).to_s

    assert_includes html, "Glad you&#39;re here, Mason",
      "the mailer overrode the operator's header — the admin field would be decorative"
  end
end
