# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "active_support"
require "active_support/test_case"
require_relative "../../lib/studio/system_test_case"

# [unit] Studio::SystemTestCase's hooks and its customization API, with no
# browser: a fake page records what each hook asks of the browser. The real
# Chrome run is test/system/system_test_case_browser_test.rb.
class SystemTestCaseTest < Minitest::Test
  # A stand-in for Selenium's browser: it records every call a hook makes.
  class FakeBrowser
    attr_reader :calls

    def initialize(calls)
      @calls = calls
    end

    def manage = self
    def window = self
    def resize_to(*size) = calls << [:resize_to, size]
    def execute_cdp(command, **params) = calls << [:execute_cdp, command, params]
  end

  FakeDriver = Struct.new(:browser)
  FakePage = Struct.new(:driver)

  # A host's base: the fake page in place of Capybara's. Each test builds its own
  # subclass so a class-level setting never leaks between tests.
  def host_class(&body)
    klass = Class.new(Studio::SystemTestCase) do
      attr_accessor :calls

      def page = FakePage.new(FakeDriver.new(FakeBrowser.new(calls)))
      def evaluate_script(_script) = 390
      def test_nothing; end
    end
    klass.class_eval(&body) if body
    klass
  end

  # Runs one test's setup and teardown callbacks and returns the browser calls.
  def run_hooks(klass)
    test = klass.new("test_nothing")
    test.calls = []
    test.run_callbacks(:setup)
    yield test if block_given?
    test.run_callbacks(:teardown)
    test.calls
  end

  RESET = [:resize_to, [1400, 1000]].freeze
  CLEAR_METRICS = [:execute_cdp, "Emulation.clearDeviceMetricsOverride", {}].freeze
  CLEAR_MEDIA = [:execute_cdp, "Emulation.setEmulatedMedia", { media: "", features: [] }].freeze

  def test_each_hook_runs_by_default
    calls = run_hooks(host_class)

    assert_equal [RESET, CLEAR_METRICS, CLEAR_MEDIA], calls
  end

  def test_skipping_reset_window_disables_only_that_hook
    klass = nil
    assert_output(nil, /skips the reset_window hook: this suite sizes its own window/) do
      klass = host_class { skip_harness_hook :reset_window, reason: "this suite sizes its own window" }
    end

    assert_equal [CLEAR_METRICS, CLEAR_MEDIA], run_hooks(klass)
    assert_restores_script_timeout klass, true
  end

  def test_skipping_clear_emulation_disables_only_that_hook
    klass = nil
    assert_output(nil, /skips the clear_emulation hook/) do
      klass = host_class { skip_harness_hook :clear_emulation, reason: "no phone tests" }
    end

    assert_equal [RESET], run_hooks(klass)
    assert_restores_script_timeout klass, true
  end

  def test_skipping_restore_script_timeout_disables_only_that_hook
    klass = nil
    assert_output(nil, /skips the restore_script_timeout hook/) do
      klass = host_class { skip_harness_hook :restore_script_timeout, reason: "measuring the raw driver" }
    end

    assert_restores_script_timeout klass, false
    assert_equal [RESET, CLEAR_METRICS, CLEAR_MEDIA], run_hooks(klass)
  end

  def test_an_opt_out_stays_on_its_own_class
    klass = nil
    assert_output(nil, /skips/) { klass = host_class { skip_harness_hook :reset_window, reason: "own size" } }

    assert klass.harness_hook?(:clear_emulation)
    refute klass.harness_hook?(:reset_window)
    refute Class.new(klass).harness_hook?(:reset_window), "a subclass inherits the opt-out"
    assert Studio::SystemTestCase.harness_hook?(:reset_window), "the base keeps the hook"
    assert host_class.harness_hook?(:reset_window), "a sibling keeps the hook"
  end

  def test_an_unknown_hook_name_is_refused
    error = assert_raises(ArgumentError) { host_class { skip_harness_hook :reset_windows, reason: "typo" } }

    assert_match(/unknown harness hook :reset_windows/, error.message)
    assert_match(/:reset_window, :restore_script_timeout, :clear_emulation/, error.message)
  end

  def test_an_opt_out_needs_a_reason
    assert_raises(ArgumentError) { host_class { skip_harness_hook :reset_window, reason: " " } }
  end

  def test_the_app_setup_runs_after_the_base_and_its_teardown_before
    klass = host_class do
      setup { calls << :app_setup }
      teardown { calls << :app_teardown }
    end

    assert_equal [RESET, :app_setup, :app_teardown, CLEAR_METRICS, CLEAR_MEDIA], run_hooks(klass)
  end

  def test_app_helpers_mix_in_beside_the_base_helpers
    helpers = Module.new { def sign_in_as(name) = calls << [:sign_in, name] }
    klass = host_class { include helpers }

    calls = run_hooks(klass) { |test| test.sign_in_as("pat") }

    assert_equal [RESET, [:sign_in, "pat"], CLEAR_METRICS, CLEAR_MEDIA], calls
  end

  def test_driven_by_sets_the_reset_size_and_the_read_timeout
    klass = host_class { driven_by :selenium, using: :headless_chrome, screen_size: [1280, 900] }

    assert_equal [1280, 900], klass.desktop_size
    assert_equal [[:resize_to, [1280, 900]], CLEAR_METRICS, CLEAR_MEDIA], run_hooks(klass)
    assert_equal({ timeout: 180 }, klass.driver.instance_variable_get(:@options))
    assert_equal [1400, 1000], Studio::SystemTestCase.desktop_size, "the base keeps its size"
  end

  def test_the_base_driver_has_the_long_read_timeout
    assert_equal({ timeout: Studio::SystemTestCase::DEFAULT_READ_TIMEOUT },
                 Studio::SystemTestCase.driver.instance_variable_get(:@options))
    assert_equal 180, Studio::SystemTestCase::DEFAULT_READ_TIMEOUT
  end

  def test_an_app_may_name_its_own_read_timeout
    klass = host_class { driven_by :selenium, options: { timeout: 240, url: "http://grid:4444" } }

    assert_equal({ timeout: 240, url: "http://grid:4444" }, klass.driver.instance_variable_get(:@options))
  end

  def test_a_non_selenium_driver_gets_no_selenium_options
    klass = host_class { driven_by :rack_test }

    assert_equal({}, klass.driver.instance_variable_get(:@options))
  end

  def test_phone_viewport_uses_the_class_phone_width
    calls = run_hooks(host_class) { |test| test.phone_viewport! }
    narrow = run_hooks(host_class { self.phone_width = 375 }) { |test| test.phone_viewport! }

    assert_includes calls, [:execute_cdp, "Emulation.setDeviceMetricsOverride",
                            { width: 390, height: 844, deviceScaleFactor: 1, mobile: true }]
    assert_includes narrow, [:execute_cdp, "Emulation.setDeviceMetricsOverride",
                             { width: 375, height: 844, deviceScaleFactor: 1, mobile: true }]
    assert_equal 390, Studio::SystemTestCase.phone_width, "the base keeps its width"
  end

  def test_assert_viewport_width_reads_client_width
    test = host_class.new("test_nothing")

    test.assert_viewport_width
    assert_raises(Minitest::Assertion) { test.assert_viewport_width(375) }
  end

  def test_the_browser_hooks_stand_down_without_a_browser_window
    klass = host_class { def page = FakePage.new(FakeDriver.new(Object.new)) }

    assert_equal [], run_hooks(klass)
  end

  # The driver prepend: a fake driver whose evaluate_async_script lowers the
  # script timeout to 2s the way Capybara 3.40.0 does.
  class LoweringDriver
    Timeouts = Struct.new(:script_timeout)

    def initialize = @timeouts = Timeouts.new(30)
    def browser = self
    def manage = self
    def timeouts = @timeouts

    def evaluate_async_script(_script, *_args)
      @timeouts.script_timeout = 2
      :result
    end

    prepend Studio::SystemTestCase::RestoresScriptTimeout
  end

  def test_the_prepend_sits_on_capybaras_selenium_driver
    assert_includes Capybara::Selenium::Driver.ancestors, Studio::SystemTestCase::RestoresScriptTimeout
  end

  def test_the_restore_is_on_outside_a_studio_test
    Thread.current[Studio::SystemTestCase::SCRIPT_TIMEOUT_KEY] = nil
    driver = LoweringDriver.new

    assert_equal :result, driver.evaluate_async_script("x")
    assert_equal 30, driver.timeouts.script_timeout
  end

  private

  # Runs setup, then an async script on the lowering driver, and reports
  # whether the 30s timeout came back.
  def assert_restores_script_timeout(klass, expected)
    test = klass.new("test_nothing")
    test.calls = []
    test.run_callbacks(:setup)
    driver = LoweringDriver.new
    driver.evaluate_async_script("x")

    assert_equal(expected ? 30 : 2, driver.timeouts.script_timeout)
  ensure
    test.run_callbacks(:teardown)
    assert_nil Thread.current[Studio::SystemTestCase::SCRIPT_TIMEOUT_KEY], "teardown clears the switch"
  end
end
