# frozen_string_literal: true

require_relative "../../test_helper"

# [unit] Studio::MailSender: the default sender and the production guard that
# refuses an example.com placeholder (the Rails scaffold's ApplicationMailer
# shadow, which Resend refuses). lib/studio/mail_sender.rb is pure Ruby and the
# test helper requires it, so these cases run the real file, not a mirror.
class StudioMailSenderTest < Minitest::Test
  # A stand-in for an ActionMailer class: default_params, a private `new`, and
  # a proc default evaluated inside an instance, as ActionMailer evaluates it.
  def fake_mailer(name, from)
    Class.new do
      define_singleton_method(:name) { name }
      define_singleton_method(:default_params) { { from: from } }
      private_class_method :new

      def app_label
        "Instance"
      end
    end
  end

  class RecordingLogger
    attr_reader :warnings

    def initialize
      @warnings = []
    end

    def warn(message)
      @warnings << message
    end
  end

  # ── default_for ────────────────────────────────────────────

  def test_default_names_the_app_at_the_team_address
    assert_equal "Voicebox <team@mcritchie.studio>", Studio::MailSender.default_for("Voicebox")
    assert_equal "Moms App <team@mcritchie.studio>", Studio::MailSender.default_for("  Moms App ")
  end

  def test_an_unnamed_app_sends_as_mcritchie_studio
    assert_equal "McRitchie Studio <team@mcritchie.studio>", Studio::MailSender.default_for("Studio")
    assert_equal "McRitchie Studio <team@mcritchie.studio>", Studio::MailSender.default_for(nil)
    assert_equal "McRitchie Studio <team@mcritchie.studio>", Studio::MailSender.default_for("  ")
  end

  def test_a_name_with_specials_is_quoted
    assert_equal %("Acme, Inc." <team@mcritchie.studio>), Studio::MailSender.default_for("Acme, Inc.")
    assert_equal %("Say \\"Hi\\"" <team@mcritchie.studio>), Studio::MailSender.default_for(%(Say "Hi"))
    assert_equal "Mom's App <team@mcritchie.studio>", Studio::MailSender.default_for("Mom's App")
  end

  # ── placeholder? ───────────────────────────────────────────

  def test_example_domains_are_placeholders
    assert Studio::MailSender.placeholder?("from@example.com")
    assert Studio::MailSender.placeholder?("App <hello@EXAMPLE.org>")
    assert Studio::MailSender.placeholder?("x@mail.example.net")
    assert Studio::MailSender.placeholder?(["team@mcritchie.studio", "from@example.com"])
  end

  def test_real_domains_are_not_placeholders
    refute Studio::MailSender.placeholder?("Voicebox <team@mcritchie.studio>")
    refute Studio::MailSender.placeholder?("a@notexample.com")
    refute Studio::MailSender.placeholder?("a@example.community")
    refute Studio::MailSender.placeholder?("a@example.com.au")
    refute Studio::MailSender.placeholder?(nil)
  end

  # ── resolve ────────────────────────────────────────────────

  def test_resolve_reads_a_string_default
    assert_equal "from@example.com", Studio::MailSender.resolve(fake_mailer("ApplicationMailer", "from@example.com"))
  end

  def test_resolve_evaluates_a_proc_default_inside_a_mailer_instance
    mailer = fake_mailer("ApplicationMailer", -> { "#{app_label} <team@mcritchie.studio>" })
    assert_equal "Instance <team@mcritchie.studio>", Studio::MailSender.resolve(mailer)

    one_arg = fake_mailer("ApplicationMailer", ->(m) { "#{m.app_label} One <team@mcritchie.studio>" })
    assert_equal "Instance One <team@mcritchie.studio>", Studio::MailSender.resolve(one_arg)
  end

  # ── verify! ────────────────────────────────────────────────

  def test_production_refuses_a_placeholder_sender_naming_the_fix
    mailer = fake_mailer("ApplicationMailer", "from@example.com")
    error = assert_raises(Studio::MailSender::PlaceholderSenderError) do
      Studio::MailSender.verify!(mailer_classes: [mailer], rails_env: "production")
    end
    assert_includes error.message, %(ApplicationMailer sends from "from@example.com")
    assert_includes error.message, "app/mailers/application_mailer.rb"
    assert_includes error.message, "resend_from:"
  end

  def test_production_refuses_a_placeholder_a_proc_resolves_to
    mailer = fake_mailer("UserMailer", -> { "Nope <x@example.com>" })
    assert_raises(Studio::MailSender::PlaceholderSenderError) do
      Studio::MailSender.verify!(mailer_classes: [fake_mailer("ApplicationMailer", "ok@mcritchie.studio"), mailer],
                                 rails_env: "production")
    end
  end

  def test_production_passes_a_team_sender
    mailer = fake_mailer("ApplicationMailer", -> { "Voicebox <team@mcritchie.studio>" })
    assert_equal :verified, Studio::MailSender.verify!(mailer_classes: [mailer], rails_env: "production")
  end

  def test_outside_production_the_guard_stands_aside
    mailer = fake_mailer("ApplicationMailer", "from@example.com")
    %w[test development].each do |env|
      assert_equal :skipped, Studio::MailSender.verify!(mailer_classes: [mailer], rails_env: env)
    end
  end

  def test_an_unresolvable_sender_is_logged_and_skipped_never_a_refused_boot
    broken = fake_mailer("ApplicationMailer", -> { raise KeyError, "no request" })
    logger = RecordingLogger.new

    assert_equal :verified, Studio::MailSender.verify!(mailer_classes: [broken], rails_env: "production", logger: logger)
    assert_equal 1, logger.warnings.size
    assert_includes logger.warnings.first, "ApplicationMailer"
    assert_includes logger.warnings.first, "KeyError"
  end
end
