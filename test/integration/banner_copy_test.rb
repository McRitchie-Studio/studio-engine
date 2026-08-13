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
    ActiveRecord::Migration.suppress_messages do
      AddCopyToStudioEmailSettings.new.migrate(:up)
      AddSubjectToStudioEmailSettings.new.migrate(:up)
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
  test "a template that wants a name falls back when there is none" do
    Studio::EmailSetting.set_copy("magic_link", header: "Welcome {name}!",
                                                header_fallback: "Your Magic Link")

    banner = Studio::Banner.for(:magic_link, name: nil)

    assert_equal "Your Magic Link", banner.header
    refute_includes banner.header, "{name}"
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

  test "a saved logo url replaces the inherited one" do
    Studio::EmailSetting.set_copy("magic_link", logo_url: "https://cdn.test/mine.png")

    assert_equal "https://cdn.test/mine.png", Studio::Banner.for(:magic_link, name: nil).logo_url
  end

  # "Hidden" and "not set" have to be different answers — blank inherits, so
  # without an explicit flag there is no way to say "no logo at all".
  test "hiding the logo is distinct from leaving it blank" do
    Studio::EmailSetting.set_copy("magic_link", hide_logo: true)
    assert_nil Studio::Banner.for(:magic_link, name: nil).logo_url

    Studio::EmailSetting.set_copy("magic_link", hide_logo: false)
    refute_nil Studio::Banner.for(:magic_link, name: nil).logo_url,
      "unchecking must restore the inherited logo, not leave it hidden"
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

  # --- through HTTP, where the filtering happens -----------------------------

  # THE BUG THIS EXISTS FOR. Every logo test above passed while hiding the logo
  # from the actual page did nothing: strong params dropped :hide_logo, set_copy
  # never saw it, and the redirect said "Saved." The model was never broken, so
  # model-level tests could not see it — the filter sits in the controller, so
  # the assertion has to go through the controller.
  test "the controller permits every field the form posts" do
    posted = %i[header header_fallback subtext subject logo_url hide_logo]
    permitted = Studio::EmailSetting::COPY_FIELDS + [:hide_logo]

    missing = posted - permitted
    assert_empty missing, "the form posts these and strong params drops them: #{missing.join(", ")}"

    source = File.read(File.expand_path("../../app/controllers/studio/emails_controller.rb", __dir__))
    assert_includes source, "params.permit(*Studio::EmailSetting::COPY_FIELDS, :hide_logo)",
      "hide_logo is not a COPY_FIELD, so deriving the list from COPY_FIELDS alone silently drops it"
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
