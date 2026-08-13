# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

# [integration] The Save button on /admin/emails/:key, driven through the REAL
# stack — router -> Studio::EmailsController#copy -> copy_params -> the model ->
# the database.
#
# WHY THIS FILE EXISTS. The page has ONE Save button that writes through four
# different model calls, and three separate defects have now reached review on
# that one action. Every one of them was a WIRING failure the model tests could
# not see, because the model was never the broken part:
#
#   1. copy_params did not permit hide_logo, so the checkbox saved nothing.
#   2. #copy called write_footer, a method that exists nowhere. Every save
#      raised, so the operator was told "Couldn't save the banner text", an
#      ErrorLog row landed per save, the tint (written AFTER the raise) never
#      persisted, and the footer — whose only opt-in path is that line —
#      was unreachable in every consuming app.
#   3. before those, the footer wipe: blank inputs from an untouched page
#      writing a row of nils over a configured footer.
#
# The reason all three survived a green suite is that test/dummy ships no
# ApplicationController, so nothing could LOAD Studio::EmailsController — which
# left the controller asserted by matching its own source text with a regex, and
# left banner_copy_test's footer guard calling the model directly while
# describing itself as the controller's write path. A source regex cannot tell a
# method that exists from one that does not, and a model call cannot tell you
# whether the controller ever reaches it.
#
# So this file supplies the host contract a real consuming app provides (the
# same three-line ApplicationController that magic_link_flow_test.rb,
# magic_link_error_logging_test.rb and local_review_endpoint_test.rb already
# stand up) and asserts the EFFECT of a real PATCH: what the operator is told,
# and what is in the database afterwards.
ActionDispatch::IntegrationTest.app = Rails.application

# Engine tables. The engine ships the models; the host app owns the schema.
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  # rescue_and_log writes here before re-raising. Without the table a genuine
  # failure would surface as a confusing NoTable error instead of the real one —
  # and "how many rows landed here" is itself an assertion below.
  create_table :error_logs, force: true do |t|
    t.string   :slug
    t.text     :message
    t.text     :inspect
    t.text     :backtrace
    t.string   :target_type
    t.bigint   :target_id
    t.string   :parent_type
    t.bigint   :parent_id
    t.timestamps
  end
end

require_relative "../../db/migrate/20260812000000_create_studio_email_settings"
require_relative "../../db/migrate/20260812210000_add_copy_to_studio_email_settings"
require_relative "../../db/migrate/20260812220000_add_subject_to_studio_email_settings"
require_relative "../../db/migrate/20260813010000_add_body_cta_footer_to_studio_email_settings"
ActiveRecord::Migration.suppress_messages do
  CreateStudioEmailSettings.new.migrate(:up)
  AddCopyToStudioEmailSettings.new.migrate(:up)
  AddSubjectToStudioEmailSettings.new.migrate(:up)
  AddBodyCtaFooterToStudioEmailSettings.new.migrate(:up)
end
Studio::EmailSetting.reset_column_information

# The engine's User contract is admin? + display_name. A PORO satisfies it; no
# users table is needed, because who the admin is is not what is under test.
class StudioTestAdmin
  def admin? = true
  def display_name = "Admin"
end

# The host contract the engine's controllers inherit. A real consuming app looks
# exactly like this: ApplicationController includes Studio::ErrorHandling and
# supplies current_user (logged_in? is derived from it by the concern).
class ApplicationController < ActionController::Base
  include Studio::ErrorHandling

  def current_user
    @current_user ||= StudioTestAdmin.new
  end
end

class EmailsPageSaveTest < ActionDispatch::IntegrationTest
  KEY = "magic_link"

  def setup
    Studio::EmailSetting.forget!
    Studio::EmailSetting.delete_all
    ErrorLog.delete_all
  end

  def teardown
    Studio::EmailSetting.delete_all
    Studio::EmailCatalog.reset!
  end

  # Exactly what show.html.erb's hidden inputs post on ANY save: every copy
  # field, the CTA toggle, the tint, and BOTH footer inputs — blank ones
  # included, from a page where the operator only touched the subject. Posting
  # the whole form is the point; three of the defects above only appear when a
  # field the operator did not touch rides along.
  def save_page(**overrides)
    patch "/admin/emails/#{KEY}/copy", params: {
      header: "Welcome {name}!",
      header_fallback: "Your Magic Link",
      subtext: "your sign-in link is below",
      logo_url: "",
      subject: "Your {app} sign-in link",
      body: "Tap the button below to sign in.",
      cta_text: "Sign in",
      cta_color: "",
      cta_enabled: "1",
      hide_logo: "",
      discord_url: "",
      footer_logo_url: "",
      scrim_percent: "40"
    }.merge(overrides)
    # The settings cache is per-request-ish; drop it so every assertion below
    # reads the DATABASE rather than the memo the request left behind.
    Studio::EmailSetting.forget!
  end

  # --- the operator is told the truth ---------------------------------------

  # THE SYMPTOM. Every save on this page said it failed. Assert the flash the
  # operator actually reads, not the status code alone — a 303 was returned on
  # the failure path too, so the redirect proves nothing on its own.
  test "an ordinary Save reports success" do
    save_page

    assert_equal 303, response.status
    assert_equal "Saved.", flash[:notice]
    assert_nil flash[:alert], "the page told the operator the save failed"
  end

  # An exception per save is not just a bad message: it fills the host's error
  # log with rows a real incident then has to be found among.
  test "an ordinary Save logs no error" do
    assert_no_difference -> { ErrorLog.count } do
      save_page
    end
  end

  # --- every field on the one-button form actually lands --------------------

  # The tint is written AFTER the footer in #copy, so a raise on the footer line
  # takes it with it. That ordering is exactly why one dead call cost two
  # features, and why this asserts a field on each side of the failing line.
  test "one Save persists every field on the page" do
    save_page(subject: "Your sign-in link", scrim_percent: "40")

    assert_equal "Your sign-in link", Studio::EmailSetting.copy_for(KEY, :subject)
    assert_equal "Tap the button below to sign in.", Studio::EmailSetting.copy_for(KEY, :body)
    # assert_equal, not assert_in_delta: a lost tint reads back as nil, and nil
    # cannot be coerced into a Float — the delta form reports the defect as a
    # TypeError from the assertion instead of as the missing value it is.
    assert_equal 0.4, Studio::EmailSetting.scrim_for(KEY),
      "the tint is written after the footer, so a raise on the footer line loses it"
  end

  # --- the footer, through its ONLY opt-in path -----------------------------

  # THE DEFECT THIS FILE WAS ADDED FOR. The default footer logo was deliberately
  # removed in this same change, so a band renders ONLY when an operator opts in
  # — and this PATCH is the only way to opt in. With the write dead, the whole
  # footer feature shipped unreachable in every consuming app.
  test "the footer an operator fills in is actually stored" do
    save_page(discord_url: "https://discord.gg/studio",
              footer_logo_url: "https://cdn.test/mark.png")

    footer = Studio::EmailSetting.footer

    refute_nil footer, "the only opt-in path to the shared footer wrote nothing"
    assert_equal "https://discord.gg/studio", footer[:discord_url]
    assert_equal "https://cdn.test/mark.png", footer[:logo_url]
  end

  # What the EMAILS read, not just what the row holds — the operator's opt-in
  # has to survive resolution to be worth anything.
  test "the stored footer is what an email resolves" do
    save_page(discord_url: "https://discord.gg/studio")

    assert_equal "https://discord.gg/studio", Studio::EmailCatalog.footer[:discord_url]
  end

  # --- the footer wipe, now through the write path that had it --------------

  # These three are the guard banner_copy_test describes as "exercised through
  # the controller's own write path" while calling the model directly. Here they
  # go through the controller, so they also fail if the controller stops calling
  # update_footer — which is precisely how the wipe fix got shipped dead.

  test "a page nobody edited does not create a cleared footer" do
    save_page

    assert_nil Studio::EmailSetting.footer,
      "blank posts from a page nobody edited must not create a cleared footer"
  end

  test "reposting a stored footer leaves it alone" do
    Studio::EmailSetting.set_footer(logo_url: "https://cdn.test/mark.png")
    Studio::EmailSetting.forget!

    save_page(footer_logo_url: "https://cdn.test/mark.png")

    assert_equal "https://cdn.test/mark.png", Studio::EmailSetting.footer[:logo_url]
  end

  test "clearing the footer on purpose still clears it" do
    Studio::EmailSetting.set_footer(logo_url: "https://cdn.test/mark.png")
    Studio::EmailSetting.forget!

    save_page(footer_logo_url: "")

    assert_empty Studio::EmailCatalog.footer, "an explicit clear must still work"
  end

  # --- the CTA toggle, over HTTP --------------------------------------------

  # Same shape as hide_logo: a boolean that is not a COPY_FIELD and needs its own
  # write, which is how it went dead the first time.
  test "the CTA toggle saves both ways over HTTP" do
    save_page(cta_enabled: "0")
    refute Studio::EmailSetting.cta_enabled_for(KEY), "unticking saved nothing"

    save_page(cta_enabled: "1")
    assert Studio::EmailSetting.cta_enabled_for(KEY), "ticking saved nothing"
  end

  # --- the control ----------------------------------------------------------

  # THE MUTATION. Break the footer write the way it was broken — a call the
  # receiver does not answer — and the assertions above must fail. A test that
  # passes against the bug it was written for proves nothing.
  #
  # Reproduced at the model rather than by editing the action, so the mutation
  # is the DEFECT (the controller calling something that raises NoMethodError)
  # and not a rewrite of the code under test.
  test "MUTATION: a footer write that does not answer reddens this file" do
    Studio::EmailSetting.singleton_class.class_eval do
      alias_method :update_footer_real, :update_footer
      define_method(:update_footer) do |**|
        raise NoMethodError, "undefined method `write_footer' for Studio::EmailsController"
      end
    end

    save_page(discord_url: "https://discord.gg/studio",
              footer_logo_url: "https://cdn.test/mark.png")

    assert_nil Studio::EmailSetting.footer,
      "MUTATION SURVIVED — the footer saved with the write broken"
    assert_equal "Couldn't save the banner text. Please try again.", flash[:alert],
      "MUTATION SURVIVED — the operator was told Saved. with the write broken"
    assert_nil Studio::EmailSetting.scrim_for(KEY),
      "MUTATION SURVIVED — the tint after the raise persisted anyway"
    assert_operator ErrorLog.count, :>, 0,
      "MUTATION SURVIVED — a raising save logged nothing"
  ensure
    Studio::EmailSetting.singleton_class.class_eval do
      alias_method :update_footer, :update_footer_real
      remove_method :update_footer_real
    end
  end
end
