# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../lib/studio/mail_transport"

# [unit] Studio::MailTransport must survive a Rails CONSTANT that is not a Rails
# APPLICATION — the same trap test/lib/studio/s3_namespace_only_rails_test.rb
# pins for Studio::S3, in the file that was missed when that one was fixed.
#
# THE TRAP. `configure!` defaults two keyword arguments off `defined?(Rails)`:
# `rails_env:` reads `Rails.env` and `logger:` reads `Rails.logger`.
# rails-html-sanitizer — a transitive dependency of `action_view` — defines a
# NAMESPACE-ONLY `module Rails`: a bare Module with zero singleton methods.
# Against it `defined?(Rails)` reads TRUE and the very next call raises
# NoMethodError. Measured at the head this file was added against, a bare
# `Studio::MailTransport.configure!(env: {}, action_mailer: mailer)` died with
# `NoMethodError: undefined method 'env' for module Rails`.
#
# WHY THIS FILE COULD NOT EXIST BEFORE, and why it does now. test_helper requires
# lib/studio/js_literal, whose first line is `require "action_view"` — so merely
# loading the unit suite is what conjures the bare constant. lib/studio.rb loads
# js_literal (line 11) BEFORE mail_transport (line 25), so a real host arms the
# same condition in the same order.
#
# NO STUB HERE, ON PURPOSE. The absent accessor IS the condition under test, so a
# hand-rolled double of `Rails.env` would pass against the old code too and prove
# nothing. bin/release-check runs each test file in its own process
# (`ruby -Itest <file>`), so a sibling that installs the accessor cannot reach
# this one. The fixture is the real dependency graph rather than a model of it.
#
# THE TWO GUARDS ARE TESTED SEPARATELY, and that separation is the point. Ruby
# evaluates only the defaults the caller omitted, and `rails_env:` is declared
# ABOVE `logger:` — so a bare call raises out of the FIRST one and never reaches
# the second, which is exactly how a second straggler hides behind the first.
# Each test below supplies one argument and omits the other, so each defaulting
# expression is the only one that can raise. Verified by mutation: restoring the
# old shape on line 9 alone reddens only test_..._rails_env, and on line 11 alone
# only test_..._logger.
class MailTransportNamespaceOnlyRailsTest < Minitest::Test
  Mailer = Struct.new(:delivery_method, :smtp_settings)

  # THE PRECONDITION, asserted rather than assumed. If action_view ever stops
  # arriving through test_helper, the constant vanishes, `defined?(Rails)` reads
  # false, both defaults take their safe branch for the WRONG reason, and the two
  # tests below would pass while testing nothing.
  def test_the_fixture_really_is_a_rails_constant_without_env_or_logger
    assert defined?(Rails),
           "action_view should have defined a bare `module Rails`; without it the " \
           "assertions below are inert"
    refute Rails.respond_to?(:env),
           "this file must NOT stub Rails.env — the missing accessor is the " \
           "condition under test, and a sibling's stub leaking in would hide the bug"
    refute Rails.respond_to?(:logger),
           "this file must NOT stub Rails.logger — the logger default is a second, " \
           "independently reachable straggler and needs the same bare constant"
  end

  # ISOLATES THE `rails_env:` DEFAULT (lib/studio/mail_transport.rb:9) by passing
  # `logger:` explicitly, so the logger default cannot fire and take the blame.
  #
  # ASSERTS THE OUTCOME, NOT MERELY "IT DID NOT RAISE". `:default` is reachable
  # only by falling through the `rails_env.to_s == "test"` early return, so a
  # fallback that resolved to "test" would surface here as `:test`. The transport
  # decision is the observable that a caller actually depends on.
  def test_a_namespace_only_rails_falls_back_to_a_development_rails_env
    mailer = Mailer.new(:smtp, {})

    result = Studio::MailTransport.configure!(env: {}, action_mailer: mailer, logger: nil)

    assert_equal :default, result.transport,
                 "a Rails constant with no application behind it must fall back to " \
                 "the \"development\" default; guarding on `defined?(Rails)` alone " \
                 "raises NoMethodError: undefined method `env' for module Rails"
    assert_equal "no transactional transport configured", result.message
  end

  # ISOLATES THE `logger:` DEFAULT (lib/studio/mail_transport.rb:11) by passing
  # `rails_env:` explicitly, so the env default cannot fire first.
  #
  # DRIVES A PATH THAT ACTUALLY LOGS. `MAIL_TRANSPORT=ses` with no credentials
  # takes the `ses_ready == false` branch and calls `log(logger, :warn, ...)`, so
  # the defaulted logger is USED rather than merely computed — a default that
  # resolved to something unloggable would surface here rather than in a host.
  def test_a_namespace_only_rails_falls_back_to_a_nil_logger
    mailer = Mailer.new(:smtp, {})

    result = Studio::MailTransport.configure!(
      env: { "MAIL_TRANSPORT" => "ses" },
      rails_env: "development",
      action_mailer: mailer
    )

    assert_equal :default, result.transport,
                 "the logger default must fall back to nil against a namespace-only " \
                 "Rails; guarding on `defined?(Rails)` alone raises NoMethodError: " \
                 "undefined method `logger' for module Rails"
  end

  # THE EVERYDAY CALL SHAPE — both defaults at once, which is what a gem unit test
  # writes when it has no opinion about either. It is the call that was measured
  # dying, and it is the one the next author will write.
  def test_the_bare_call_shape_survives_a_namespace_only_rails
    mailer = Mailer.new(:smtp, {})

    result = Studio::MailTransport.configure!(env: {}, action_mailer: mailer)

    assert_equal :default, result.transport
  end
end
