# frozen_string_literal: true

# [system] Studio::SystemTestCase in a real headless Chrome against the dummy
# host: each test leaves the browser dirty the way a careless test would (a
# small window, a phone viewport, a lowered script timeout), and the next test
# finds it clean. Test order is pinned so the "dirty" test always runs first.
#
# Engine CI runs this on ubuntu-24.04, which ships Google Chrome; Selenium
# Manager finds the matching chromedriver. Its own process, like every file in
# bin/release-check.
require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "studio/system_test_case"

Studio::SystemTestCase.start_application
# The dummy's root is plain text, so Chrome asks for /favicon.ico, which the
# dummy does not draw. That 404 is the browser's, not the harness's.
Capybara.raise_server_errors = false

class SystemTestCaseBrowserTest < Studio::SystemTestCase
  # Each pair below must run dirty-then-check, so the order is the file's.
  i_suck_and_my_tests_are_order_dependent!

  driven_by :selenium, using: :headless_chrome, screen_size: [1200, 900]

  # Mobile emulation lays a page out at its viewport meta; a page without one
  # (the dummy's plain-text root) lays out at 980px. Every app page declares
  # width=device-width, so this one does too.
  PHONE_PAGE = "data:text/html,<meta name=viewport content='width=device-width'><p>phone</p>"

  setup { @app_setup_saw = window_size }

  def window_size
    page.driver.browser.manage.window.size.then { |size| [size.width, size.height] }
  end

  def script_timeout
    page.driver.browser.manage.timeouts.script_timeout
  end

  def test_1_dirty_the_browser
    assert_equal [1200, 900], @app_setup_saw, "the app's setup runs in the reset window"
    assert_equal 180, page.driver.browser.send(:bridge).http.read_timeout,
                 "driven_by gave this driver the cold-start read budget"

    visit "/"
    page.driver.browser.manage.window.resize_to(640, 480)
    phone_viewport!
    # Print media, not a colour scheme: headless Chrome follows the host's own
    # dark mode, so a laptop's baseline differs from CI's. Nothing prints.
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", media: "print")
    visit PHONE_PAGE
    assert_viewport_width 390
    assert evaluate_script("matchMedia('print').matches")

    assert_equal 1, evaluate_async_script("arguments[0](1)")
    assert_equal 30, script_timeout, "evaluate_async_script gives the script timeout back"
  end

  def test_2_the_next_test_starts_clean
    assert_equal [1200, 900], @app_setup_saw, "reset_window restored the size"

    visit PHONE_PAGE
    assert_operator evaluate_script("document.documentElement.clientWidth"), :>, 390,
                    "clear_emulation removed the phone viewport"
    refute evaluate_script("matchMedia('print').matches"),
           "clear_emulation removed the emulated media"
    assert_equal 30, script_timeout
  end
end
