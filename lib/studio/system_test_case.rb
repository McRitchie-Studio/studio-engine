# frozen_string_literal: true

# Studio::SystemTestCase: the one browser-test base every host app inherits.
#
# A host's test/application_system_test_case.rb becomes:
#
#   require "test_helper"
#   require "studio/system_test_case"
#
#   class ApplicationSystemTestCase < Studio::SystemTestCase
#     driven_by :selenium, using: :headless_chrome, screen_size: [1400, 1000]
#   end
#
# It owns the harness bugs that were fixed app by app, so a fix ships once, in
# the gem, to every app. Detail and the customization API: docs/SYSTEM_TESTS.md.
#
# lib/studio.rb does NOT require this file. It needs Capybara and
# selenium-webdriver, which a host bundles in its test group and the gem does
# not declare. The host requires it from its system-test base only.
require "action_dispatch/system_test_case"
require "capybara/selenium/driver"

module Studio
  class SystemTestCase < ActionDispatch::SystemTestCase
    # The harness hooks this base runs, by name. A subclass opts out of one by
    # name, with a reason (skip_harness_hook); every other hook still runs.
    HOOKS = {
      reset_window: "setup: resize the window to desktop_size. The browser outlives " \
                    "the test, so a resize leaks into the next test (commercial-welding " \
                    "went red under one seed).",
      restore_script_timeout: "around evaluate_async_script: give back the script " \
                              "timeout. Capybara 3.40.0 sets it to default_max_wait_time " \
                              "(2s) and never restores it (voicebox ContrastSystemTest).",
      clear_emulation: "teardown: clear the DevTools device-metrics override that " \
                       "phone_viewport! sets, so a phone viewport does not leak."
    }.freeze

    # Selenium's stock read budget is Net::HTTP's 60s. A cold Chrome launch on a
    # slow CI runner can pass it, and the run dies with Net::ReadTimeout in
    # whichever test the seed put first (hub PR #2494).
    DEFAULT_READ_TIMEOUT = 180
    DEFAULT_DESKTOP_SIZE = [1400, 1000].freeze

    # Thread-local switch the restore_script_timeout hook reads. The prepend on
    # Capybara's driver is global; this key makes the opt-out per test class.
    SCRIPT_TIMEOUT_KEY = :studio_system_test_restore_script_timeout

    # The window every test starts in. Set it through driven_by's screen_size,
    # so the browser's launch size and the reset size are one number.
    class_attribute :desktop_size, instance_accessor: false, default: DEFAULT_DESKTOP_SIZE
    # The phone viewport phone_viewport! and assert_viewport_width default to.
    class_attribute :phone_width, instance_accessor: false, default: 390
    class_attribute :phone_height, instance_accessor: false, default: 844
    # { hook name => reason } for the hooks this class opted out of.
    class_attribute :skipped_harness_hooks, instance_accessor: false, default: {}.freeze

    class << self
      # Rails' driven_by, with two additions. screen_size also becomes
      # desktop_size, the size reset_window restores. A Selenium driver gets a
      # 180s read timeout unless options: names its own :timeout.
      def driven_by(driver = :selenium, using: :headless_chrome, screen_size: DEFAULT_DESKTOP_SIZE,
                    options: {}, &capabilities)
        self.desktop_size = Array(screen_size).dup.freeze
        options = { timeout: DEFAULT_READ_TIMEOUT }.merge(options) if driver.to_sym == :selenium
        super(driver, using: using, screen_size: screen_size, options: options, &capabilities)
      end

      # Opt this class (and its subclasses) out of one harness hook. The name
      # must be in HOOKS and the reason must say why; both are logged once, so a
      # skipped fix is never silent.
      def skip_harness_hook(name, reason:)
        name = name.to_sym
        unless HOOKS.key?(name)
          raise ArgumentError, "unknown harness hook #{name.inspect}; the hooks are #{HOOKS.keys.map(&:inspect).join(', ')}"
        end
        raise ArgumentError, "skip_harness_hook #{name.inspect} needs a reason:" if reason.to_s.strip.empty?

        self.skipped_harness_hooks = skipped_harness_hooks.merge(name => reason.to_s.strip).freeze
        warn "[Studio::SystemTestCase] #{self.name || inspect} skips the #{name} hook: #{reason.to_s.strip}"
      end

      def harness_hook?(name)
        !skipped_harness_hooks.key?(name.to_sym)
      end

      # Read by the driver prepend below. nil (no Studio test running on this
      # thread) means on: the restore is a pure bug fix.
      def restore_script_timeout?
        Thread.current[SCRIPT_TIMEOUT_KEY] != false
      end
    end

    # Capybara 3.40.0's evaluate_async_script sets the browser's script timeout
    # to Capybara.default_max_wait_time (2s) and never sets it back. The browser
    # outlives the test, so every later execute_script in the run has 2s, not the
    # driver's 30s. This gives back the timeout it borrowed (voicebox PR #35).
    module RestoresScriptTimeout
      def evaluate_async_script(script, *args)
        return super unless Studio::SystemTestCase.restore_script_timeout?

        timeouts = browser.manage.timeouts
        previous = timeouts.script_timeout
        super
      ensure
        timeouts.script_timeout = previous if previous
      end
    end
    Capybara::Selenium::Driver.prepend(RestoresScriptTimeout)

    driven_by :selenium, using: :headless_chrome, screen_size: DEFAULT_DESKTOP_SIZE

    # The base's setup runs before any setup a subclass declares, so an app's
    # own setup always starts in the reset window.
    setup do
      Thread.current[SCRIPT_TIMEOUT_KEY] = self.class.harness_hook?(:restore_script_timeout)
      reset_window if self.class.harness_hook?(:reset_window) && browser_window?
    end

    # Teardown callbacks run in reverse: a subclass's teardown runs first, then
    # this one.
    teardown do
      clear_emulation if self.class.harness_hook?(:clear_emulation) && devtools?
    ensure
      Thread.current[SCRIPT_TIMEOUT_KEY] = nil
    end

    def reset_window
      page.driver.browser.manage.window.resize_to(*self.class.desktop_size)
    end

    # A real phone-width viewport. Headless Chrome will not size its window
    # under 500px, so resize_to(390, ...) gives a 500px page and a "390px" check
    # passes at the wrong width. DevTools device-metrics emulation sets the
    # viewport itself. After each visit, before you measure, call
    # assert_viewport_width. The clear_emulation hook clears it in teardown.
    def phone_viewport!(width = self.class.phone_width, height = self.class.phone_height)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                      width: width, height: height, deviceScaleFactor: 1, mobile: true)
    end

    # Reads clientWidth, not innerWidth: under mobile emulation innerWidth grows
    # to fit a page that overflows, so a check against it passes vacuously.
    # Phone widths only: a desktop Linux Chrome takes 15px of clientWidth for
    # its scrollbar.
    def assert_viewport_width(width = self.class.phone_width)
      assert_equal width, evaluate_script("document.documentElement.clientWidth"), "the viewport is #{width}px"
    end

    def clear_emulation
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end

    private

    # A real browser window: Selenium, not rack_test. A subclass driven by
    # rack_test skips the browser hooks without opting out.
    def browser_window?
      page.driver.respond_to?(:browser) && page.driver.browser.respond_to?(:manage)
    end

    # A Chromium browser that takes DevTools commands.
    def devtools?
      browser_window? && page.driver.browser.respond_to?(:execute_cdp)
    end
  end
end
