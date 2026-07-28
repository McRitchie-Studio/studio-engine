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
# test (error_handling.rb), so locally a shadowed RecordNotFound just propagates
# like an untrapped error. It only manifests in QA and production, as a
# "Something went wrong" page plus a stray ErrorLog row on every 404, in every
# consuming app at once.
#
# These tests therefore assert the DISPATCH and its side effect — which handler
# ActiveSupport actually selects, and whether the error-log writer runs — rather
# than the order the source happens to be written in. Reordering the two
# rescue_from lines turns them red; reformatting them does not.
class ErrorHandlingRescueOrderTest < ActiveSupport::TestCase
  # Includes the concern exactly as a host ApplicationController does. The two
  # overrides stand in for the concern's I/O so dispatch is observable without a
  # real request and without an error_logs table (the dummy app has no schema).
  class ProbeController < ActionController::Base
    include Studio::ErrorHandling

    attr_reader :error_logged, :responded

    def create_error_log(_exception)
      @error_logged = true
    end

    def respond_to(*)
      @responded = true
    end
  end

  test "RecordNotFound dispatches to the not-found handler, not the catch-all" do
    controller = ProbeController.new

    controller.rescue_with_handler(ActiveRecord::RecordNotFound.new("no such record"))

    assert controller.responded,
           "expected handle_not_found to render a not-found response; the StandardError " \
           "catch-all shadowed it instead"
    refute controller.error_logged,
           "a 404 must not write an ErrorLog row — that is the fleet-wide symptom of the shadowing"
  end

  test "an unexpected error still dispatches to the catch-all" do
    controller = ProbeController.new

    # handle_unexpected_error logs, then re-raises in dev/test by design.
    assert_raises(ArgumentError) do
      controller.rescue_with_handler(ArgumentError.new("boom"))
    end

    assert controller.error_logged, "expected handle_unexpected_error to capture the error"
  end
end
