# System tests: `Studio::SystemTestCase`

One shared base for every host app's Capybara system tests. It owns the browser
harness bugs that were fixed app by app, so the next fix ships once, in the gem,
to every app. Each app keeps its own flavor: its own settings, setup, helpers and
tests.

## What the base owns

| Hook / setting | What it does | Why |
|----------------|--------------|-----|
| `reset_window` (setup) | Resizes the window to `desktop_size` before every test. | The browser outlives the test, so a resize leaks into whichever test runs next (commercial-welding went red under one seed; tasks `system-tests-reset-window-size`, `apps-system-tests-reset-window`). |
| `restore_script_timeout` (driver) | Gives back the script timeout after `evaluate_async_script`. | Capybara 3.40.0 sets it to `default_max_wait_time` (2s) and never restores it, so every later `execute_script` in the run has 2s, not 30s (voicebox `ContrastSystemTest`, task `ci-cause-voicebox-contrastsystemtest`). |
| `clear_emulation` (teardown) | Clears the DevTools device-metrics override. | `phone_viewport!` sets it, and the browser outlives the test. |
| 180s read timeout (`driven_by`) | Every Selenium driver gets `options: { timeout: 180 }`. | Selenium's stock 60s read budget dies on a cold Chrome launch on a slow CI runner (hub PR #2494). |

The base also gives every test three helpers: `phone_viewport!(width = phone_width,
height = phone_height)`, `assert_viewport_width(width = phone_width)` and
`clear_emulation`. Headless Chrome will not size its window under 500px, so a phone
width comes from DevTools emulation, not `resize_to`. After each visit, before you
measure, call `assert_viewport_width`: it reads `clientWidth`, because under mobile
emulation `innerWidth` grows to fit a page that overflows. The page must declare
`<meta name="viewport" content="width=device-width">`; without it Chrome lays a
mobile page out at 980px.

Phone widths only: a desktop Linux Chrome takes 15px of `clientWidth` for its
scrollbar.

## Adopt it in an app

1. Bump the app to the engine release that ships `Studio::SystemTestCase`.
   The app's test group already has `capybara` and `selenium-webdriver`.
2. Replace the base class and delete what the engine now owns:

   ```ruby
   # test/application_system_test_case.rb
   require "test_helper"
   require "studio/system_test_case"

   class ApplicationSystemTestCase < Studio::SystemTestCase
     driven_by :selenium, using: :headless_chrome, screen_size: [1400, 1000]
   end
   ```

   Delete the app's own window-reset `setup`, its emulation-clear `teardown`, its
   `phone_viewport!` and `assert_viewport_width` (unless it customizes them, below),
   its `RestoresScriptTimeout` prepend, and any `options: { timeout: ... }` that
   only restated 180.
3. Run the app's system suite twice, with two seeds, and ship.

`lib/studio.rb` does not load this file. It needs Capybara and selenium-webdriver,
which the gem does not declare, so the app requires it from its system-test base.

## Customize it

The base is a class. An app inherits it and adds its own flavor; it never copies it.

**Settings.** `driven_by` takes Rails' arguments. Its `screen_size` is also the
size `reset_window` restores (`desktop_size`), so the two are one number. Pass a
block for Chrome options, and `options:` to add driver options or a different
`timeout:`.

```ruby
class ApplicationSystemTestCase < Studio::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [1280, 900] do |options|
    options.add_argument("--use-fake-device-for-media-stream")
  end

  self.phone_width = 375   # the default for phone_viewport! and assert_viewport_width (390)
  self.phone_height = 812  # (844)
end
```

**Setup and teardown.** An app's `setup` runs after the base's, so it starts in the
reset window. An app's `teardown` runs before the base's.

```ruby
setup { sign_in_through_magic_link(users(:alex)) }
```

**Helpers.** Define them in the app's base, or mix them in:

```ruby
include SignInHelpers

# A customized helper calls super:
def phone_viewport!(width = self.class.phone_width, height = self.class.phone_height)
  super
  visit "/privacy"
  assert_viewport_width(width)
end
```

**App-specific tests.** They stay in the app's `test/system/` and inherit
`ApplicationSystemTestCase` as before.

**Opt out of one hook.** Name the hook and give the reason. The base logs both to
standard error when the class loads, so a skipped fix is never silent. Every other
hook still runs. An unknown name raises.

```ruby
class RawDriverTest < ApplicationSystemTestCase
  skip_harness_hook :restore_script_timeout, reason: "measures the driver's own timeout"
end
# [Studio::SystemTestCase] RawDriverTest skips the restore_script_timeout hook: measures ...
```

The names are `Studio::SystemTestCase::HOOKS.keys`: `:reset_window`,
`:restore_script_timeout` and `:clear_emulation`. An opt-out holds for the class and
its subclasses. A class driven by `rack_test` needs no opt-out: the browser hooks
stand down when there is no browser window.

## Tests

- `test/lib/system_test_case_test.rb` [unit]: each hook runs, each opt-out disables
  only its hook, the app's setup runs after the base's, and the settings.
- `test/system/system_test_case_browser_test.rb` [system]: a real headless Chrome
  against the dummy host. One test dirties the browser (a small window, a phone
  viewport, an async script); the next finds it clean.
