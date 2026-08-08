# frozen_string_literal: true

require_relative "../../test_helper"

# [unit] The three decisions behind the shared environment banner. These run
# against the SHIPPED module (lib/studio/environment_banner.rb is required
# directly, not re-declared in test_helper), so a rule can't pass here while the
# gem does something else.
class StudioEnvironmentBannerTest < Minitest::Test
  Banner = Studio::EnvironmentBanner

  # ── qa_environment? ─────────────────────────────────────────

  def test_qa_environment_is_true_for_every_truthy_spelling
    %w[1 true yes on TRUE  On ].each do |value|
      assert Banner.qa_environment?({ "QA_ENV" => value }), "expected #{value.inspect} to read as QA"
    end
  end

  def test_qa_environment_is_false_when_unset_or_falsey
    [nil, "", "  ", "false", "0", "no"].each do |value|
      refute Banner.qa_environment?({ "QA_ENV" => value }), "expected #{value.inspect} to read as not-QA"
    end
  end

  # ── show? ───────────────────────────────────────────────────

  def test_show_is_true_in_every_non_production_environment
    %w[development test staging].each do |env|
      assert Banner.show?(rails_env: env, qa_environment: false)
    end
  end

  def test_show_is_false_in_real_production
    refute Banner.show?(rails_env: "production", qa_environment: false)
  end

  # A QA app runs RAILS_ENV=production but is a review target, not production.
  def test_show_is_true_in_production_when_qa_environment
    assert Banner.show?(rails_env: "production", qa_environment: true)
  end

  def test_show_accepts_a_symbol_or_string_env
    refute Banner.show?(rails_env: :production, qa_environment: false)
    assert Banner.show?(rails_env: :development, qa_environment: false)
  end

  # ── message ─────────────────────────────────────────────────

  def test_message_names_the_rails_environment
    assert_equal "Development Environment",
                 Banner.message(rails_env: "development", qa_environment: false)
  end

  def test_message_calls_a_qa_app_non_production_instead_of_production
    assert_equal "QA Environment · Non-production",
                 Banner.message(rails_env: "production", qa_environment: true)
  end

  def test_message_appends_extra_segments
    assert_equal "QA Environment · Non-production · Devnet",
                 Banner.message(rails_env: "production", qa_environment: true, extra: ["Devnet"])
    assert_equal "Development Environment · Devnet",
                 Banner.message(rails_env: "development", qa_environment: false, extra: ["Devnet"])
  end

  def test_message_drops_blank_extra_segments
    assert_equal "Development Environment",
                 Banner.message(rails_env: "development", qa_environment: false, extra: [nil, "", "  "])
  end

  # ── inbox path ──────────────────────────────────────────────

  # The banner links this; Studio::LocalEmailsController answers it. A drift
  # between the two is exactly the dead link this standard exists to prevent.
  def test_inbox_path_matches_the_engine_route
    assert_equal "/_studio/local_emails", Banner::INBOX_PATH

    studio_rb = File.read(File.expand_path("../../../lib/studio.rb", __dir__))
    assert_includes studio_rb, %(get "#{Banner::INBOX_PATH.delete_prefix("/")}")
  end
end
