# frozen_string_literal: true

require_relative "../../test_helper"
require "active_support/core_ext/string/inflections"
require_relative "../../../lib/studio/s3"
require_relative "../../../app/services/studio/email_catalog"

# [unit] The preview half of Studio::EmailCatalog — the capability folded in from
# turf-monster's ::EmailCatalog so turf-monster can delete its own email manager
# instead of running two.
#
# The load-bearing property is NOT that previews render. It is that a preview
# CANNOT take the manager down. A `preview:` builder is host code executed
# against whatever sample data happens to exist in this environment — an empty
# table, a fixture that moved, a mailer whose signature changed since someone
# wrote the lambda. Every one of those is a normal Tuesday, and none of them may
# turn "show me my emails" into a 500.
class EmailCatalogPreviewTest < Minitest::Test
  # Stand-in for a Mail. Only the parts the catalog touches.
  FakeMail = Struct.new(:subject, :html_body) do
    def html_part = html_body && Struct.new(:body).new(html_body)
    def body = html_body.to_s
  end

  # Stand-in for ActionMailer::MessageDelivery — the shape the DOCUMENTED idiom
  # actually returns. FakeMail above is EAGER, and an eager stand-in cannot
  # reproduce the bug this class is written to prevent: `UserMailer.magic_link(…)`
  # hands back a lazy proxy whose mailer action has not run yet, so the builder's
  # exception surfaces at the first `subject`/`html_part` — not at `call`.
  # Responds to `message` and runs the body there, exactly as ActionMailer does.
  # (Mail::Message does NOT respond to `message`; that is what tells them apart.)
  LazyDelivery = Struct.new(:builder) do
    def message = builder.call
    def subject = message.subject
    def html_part = message.html_part
    def body = message.body
  end

  def setup
    Studio::EmailCatalog.reset!
  end

  def teardown
    Studio::EmailCatalog.reset!
  end

  # --- type -----------------------------------------------------------------

  def test_entries_default_to_transactional
    assert_equal :transactional, Studio::EmailCatalog.type("magic_link")
    refute Studio::EmailCatalog.entry("magic_link").marketing?
  end

  def test_a_host_can_register_a_marketing_email
    Studio::EmailCatalog.register("newsletter_welcome", label: "Newsletter welcome", type: :marketing)

    assert_equal :marketing, Studio::EmailCatalog.type("newsletter_welcome")
    assert Studio::EmailCatalog.entry("newsletter_welcome").marketing?
  end

  def test_a_bogus_type_falls_back_instead_of_raising
    # A typo in an initializer must not take the host's BOOT down over a badge.
    Studio::EmailCatalog.register("odd", label: "Odd", type: "transactionnal")

    assert_equal :transactional, Studio::EmailCatalog.type("odd")
  end

  def test_re_registering_keeps_the_type_when_it_is_not_restated
    Studio::EmailCatalog.register("newsletter_welcome", type: :marketing)
    Studio::EmailCatalog.register("newsletter_welcome", label: "Welcome!")

    assert_equal :marketing, Studio::EmailCatalog.type("newsletter_welcome")
    assert_equal "Welcome!", Studio::EmailCatalog.label("newsletter_welcome")
  end

  # --- preview: the happy path ----------------------------------------------

  def test_a_registered_builder_is_previewable
    Studio::EmailCatalog.register("winnings", preview: -> { FakeMail.new("You won!", "<h1>You won</h1>") })

    assert Studio::EmailCatalog.previewable?("winnings")
    assert_equal "You won!", Studio::EmailCatalog.preview_subject("winnings")
    assert_equal "<h1>You won</h1>", Studio::EmailCatalog.preview_html("winnings")
  end

  def test_re_registering_keeps_the_preview_when_it_is_not_restated
    Studio::EmailCatalog.register("winnings", preview: -> { FakeMail.new("s", "<p>x</p>") })
    Studio::EmailCatalog.register("winnings", label: "Contest winnings")

    assert Studio::EmailCatalog.previewable?("winnings"),
      "relabelling an email must not silently drop its preview"
  end

  def test_an_email_without_a_builder_is_not_previewable
    refute Studio::EmailCatalog.previewable?("magic_link")
    assert_nil Studio::EmailCatalog.preview_html("magic_link")
    assert_nil Studio::EmailCatalog.preview_error("magic_link"),
      "having no preview is not an ERROR — it is just nothing to show"
  end

  # --- preview: the failure paths that matter -------------------------------

  # The realistic shape: the builder calls a method on a sample record that
  # isn't there. Written as a real NoMethodError rather than naming an
  # ActiveRecord constant — this suite is pure Ruby with no AR loaded, so
  # `raise ActiveRecord::RecordNotFound` would raise NameError instead and the
  # test would pass for a reason it doesn't claim.
  # REGRESSION GUARD. The containment used to be a lie for the one shape the
  # docs recommend. `preview_mail` returned whatever the builder returned; for a
  # mailer call that is a LAZY delivery, so `callable.call` succeeded, NO error
  # was recorded, and the mailer body finally ran — and raised — inside
  # `preview_subject`, outside every rescue. `/admin/emails/:key` 500'd through
  # the host's rescue_from, losing the whole page. One preview's cost was the
  # manager, which is precisely what this class promises never happens.
  def test_a_lazy_mailer_delivery_that_fails_is_contained_not_propagated
    Studio::EmailCatalog.register("lazy_boom",
      preview: -> { LazyDelivery.new(-> { raise ArgumentError, "sample data is gone" }) })

    assert_nil Studio::EmailCatalog.preview_mail("lazy_boom"),
      "a lazy delivery must be FORCED inside the rescue, not handed back unrun"
    assert_includes Studio::EmailCatalog.preview_error("lazy_boom"), "ArgumentError"
  end

  # The 500 the bug actually produced, asserted at the call the page makes first.
  def test_preview_subject_never_propagates_a_lazy_builders_failure
    Studio::EmailCatalog.register("lazy_boom",
      preview: -> { LazyDelivery.new(-> { raise ArgumentError, "sample data is gone" }) })

    subject = nil
    begin
      subject = Studio::EmailCatalog.preview_subject("lazy_boom")
    rescue StandardError, ScriptError => e
      flunk "preview_subject propagated #{e.class}: #{e.message} — the page it feeds 500s"
    end
    assert_nil subject
  end

  def test_preview_html_never_propagates_a_lazy_builders_failure
    Studio::EmailCatalog.register("lazy_boom",
      preview: -> { LazyDelivery.new(-> { raise NotImplementedError, "mailer moved" }) })

    assert_nil Studio::EmailCatalog.preview_html("lazy_boom")
    assert_includes Studio::EmailCatalog.preview_error("lazy_boom"), "NotImplementedError"
  end

  # The happy path of the same shape — forcing must not break a WORKING mailer
  # builder, and the forced value must be the real mail, not the proxy.
  def test_a_lazy_mailer_delivery_that_works_previews_normally
    Studio::EmailCatalog.register("lazy_ok",
      preview: -> { LazyDelivery.new(-> { FakeMail.new("Your magic link", "<p>hi</p>") }) })

    assert_equal "Your magic link", Studio::EmailCatalog.preview_subject("lazy_ok")
    assert_includes Studio::EmailCatalog.preview_html("lazy_ok"), "<p>hi</p>"
    assert_nil Studio::EmailCatalog.preview_error("lazy_ok")
  end

  def test_a_raising_builder_returns_nil_instead_of_propagating
    Studio::EmailCatalog.register("broken", preview: -> { nil.email_address })

    assert_nil Studio::EmailCatalog.preview_html("broken"),
      "one broken builder must cost ONE preview, not the whole email manager"
    assert_includes Studio::EmailCatalog.preview_error("broken"), "NoMethodError"
  end

  def test_a_raising_builder_records_why
    Studio::EmailCatalog.register("broken", preview: -> { raise ArgumentError, "wrong number of arguments" })
    Studio::EmailCatalog.preview_html("broken")

    error = Studio::EmailCatalog.preview_error("broken")
    refute_nil error, "the page must be able to say WHY, not just show a blank frame"
    assert_includes error, "ArgumentError"
    assert_includes error, "wrong number of arguments"
  end

  def test_a_builder_that_raises_a_non_standard_error_is_still_contained
    # NoMethodError on a nil sample record is the single most likely failure, and
    # a NameError from a renamed mailer is a close second. Both are StandardError,
    # but a ScriptError (a broken autoload) must not escape either.
    Studio::EmailCatalog.register("boom", preview: -> { raise NotImplementedError, "nope" })

    assert_nil Studio::EmailCatalog.preview_html("boom")
    assert_includes Studio::EmailCatalog.preview_error("boom"), "NotImplementedError"
  end

  def test_a_later_success_clears_the_recorded_error
    calls = 0
    Studio::EmailCatalog.register("flaky", preview: lambda {
      calls += 1
      raise "first call fails" if calls == 1

      FakeMail.new("ok", "<p>ok</p>")
    })

    Studio::EmailCatalog.preview_html("flaky")
    refute_nil Studio::EmailCatalog.preview_error("flaky")

    assert_equal "<p>ok</p>", Studio::EmailCatalog.preview_html("flaky")
    assert_nil Studio::EmailCatalog.preview_error("flaky"),
      "a stale error would keep shouting about a preview that now works"
  end

  def test_a_builder_returning_something_mail_less_does_not_blow_up
    Studio::EmailCatalog.register("weird", preview: -> { Object.new })

    assert_nil Studio::EmailCatalog.preview_html("weird")
    refute_nil Studio::EmailCatalog.preview_error("weird")
  end

  def test_an_unregistered_key_is_simply_not_previewable
    refute Studio::EmailCatalog.previewable?("does_not_exist")
    assert_nil Studio::EmailCatalog.preview_html("does_not_exist")
  end

  # The builder must not run just because the page LISTED the email — the index
  # renders every row, and running eight host lambdas to draw a table would make
  # the list as fragile as the previews.
  def test_listing_entries_does_not_invoke_any_builder
    ran = false
    Studio::EmailCatalog.register("winnings", preview: -> { ran = true; FakeMail.new("s", "<p>x</p>") })

    Studio::EmailCatalog.entries.each { |entry| entry.label && entry.previewable? }

    refute ran, "the index must not execute host preview code to draw its rows"
  end
end
