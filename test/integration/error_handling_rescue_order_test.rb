# frozen_string_literal: true

require "bundler/setup"
ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"
require "minitest/autorun"
require "active_support/test_case"

# ActiveSupport::Rescuable resolves handlers with `reverse_each`, so the LAST
# matching `rescue_from` registered wins. Studio::ErrorHandling registers a
# StandardError catch-all alongside specific handlers — if the catch-all is
# registered last it silently shadows every specific handler, and
# handle_not_found becomes unreachable code.
#
# That regression is invisible to an ordinary request test, which is why it
# survived from the initial commit: handle_unexpected_error re-raises in dev and
# test, so a shadowed RecordNotFound just propagates like an untrapped error and
# LOOKS correct locally. It only manifests in QA and production, as a "Something
# went wrong" page plus a stray ErrorLog row on every 404, in every consuming app
# at once.
#
# So the discriminator here is NOT "does it raise" — both handlers raise. It is
# **which handler claimed the exception**, observed through its one side effect:
# the catch-all writes an ErrorLog row, handle_not_found never does. That is the
# actual contract, and it is what these tests assert.
#
# The 404 STATUS, format, and body are deliberately NOT asserted here, because
# handle_not_found deliberately renders nothing — it re-raises to
# ActionDispatch::PublicExceptions, so the response is Rails' own and belongs to
# the consuming app. The consumer-CI suites cover it end to end: turf's
# Admin::ModelsControllerTest#test_unknown_model_key_returns_not_found asserts an
# unknown key still returns 404.
class ErrorHandlingRescueOrderTest < ActiveSupport::TestCase
  # Includes the concern exactly as a host ApplicationController does. The single
  # override stands in for the concern's only observable side effect, so handler
  # selection is visible without an error_logs table (the dummy app has no schema).
  class ProbeController < ActionController::Base
    include Studio::ErrorHandling

    attr_reader :error_logged

    def create_error_log(_exception)
      @error_logged = true
    end
  end

  test "RecordNotFound is claimed by handle_not_found — no ErrorLog row, and it propagates" do
    controller = ProbeController.new

    # It must still reach the app as a RecordNotFound: handle_not_found re-raises
    # so Rails renders its own 404. A handler that rendered instead would swallow
    # this and fail here.
    assert_raises(ActiveRecord::RecordNotFound) do
      controller.rescue_with_handler(ActiveRecord::RecordNotFound.new("no such record"))
    end

    # THE regression assertion. If the rescue_from order is ever flipped back, the
    # StandardError catch-all claims this instead and logs it — which is precisely
    # the fleet-wide bug (an ErrorLog row on every 404).
    refute controller.error_logged,
           "a 404 must not write an ErrorLog row — handle_not_found was shadowed by the " \
           "StandardError catch-all, which is the bug this ordering fixes"
  end

  test "an unexpected error is still claimed by the catch-all — logged, then re-raised in test env" do
    controller = ProbeController.new

    assert_raises(ArgumentError) do
      controller.rescue_with_handler(ArgumentError.new("boom"))
    end

    assert controller.error_logged,
           "handle_unexpected_error must still capture genuine errors; narrowing the " \
           "catch-all would lose the ErrorLog trail"
  end

  test "a RecordNotFound subclass is also claimed by handle_not_found" do
    subclass = Class.new(ActiveRecord::RecordNotFound)
    controller = ProbeController.new

    assert_raises(subclass) { controller.rescue_with_handler(subclass.new("gone")) }

    refute controller.error_logged,
           "rescue_from matches subclasses, so a RecordNotFound descendant must not log either"
  end
end
