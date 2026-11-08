# Not-found page

A lost visitor sees a friendly page, not Rails' bare "The page you were looking for
doesn't exist". The page names the app, shows its brand mark, says what happened in
one short line and gives one button: back to the app's home. When the visitor came
from a page on the same app, a second link goes back there. The status stays 404.

## Adopt it: one line

In `config/application.rb`, inside the application class:

```ruby
config.exceptions_app = Studio::ExceptionsApp.new
```

That is all. Rails sends every exception it renders to the exceptions app, so both
kinds of miss reach the page:

- an unknown address (`ActionController::RoutingError`), and
- a record that is not there (`ActiveRecord::RecordNotFound`). `Studio::ErrorHandling`
  re-raises it on purpose, with no ErrorLog row, so it lands here.

No route is added. A catch-all route (`match "*path"`) would not see a RecordNotFound
and would change what a routing test raises, so the engine does not use one.

## What it answers

| Request | Answer |
|---------|--------|
| A 404 for an HTML request, `Accept: */*` included (curl, monitors, crawlers) | The page, inside the app's own layout (navbar, footer, theme), status 404 |
| A 404 for a JSON or XML request, or a `.json` address | `ActionDispatch::PublicExceptions`: `{"status":404,"error":"Not Found"}`, status 404. Never the HTML page |
| Any other status (500, 422 and the rest) | `ActionDispatch::PublicExceptions`, unchanged: `public/<status>.html` |

The HTML or data split is Rails' own rule (PublicExceptions), so the two cannot drift.

## It cannot loop, and it cannot change the status

`Studio::NotFoundController` renders the page. It inherits the app's
`ApplicationController`, so the page runs the app's before_actions, layout and
database. If any of them raises, or answers anything but a 404 HTML page (a sign-in
redirect, a 406 from `allow_browser`), the exceptions app throws that answer away and
serves the static `public/404.html` with status 404. It logs one
`[studio.not_found] the page fell back to public/404.html` warning. The fallback only
reads a file, so nothing is left that can fail back into the app.

So keep `public/404.html` and style it to the brand: it is the last resort. Give it the
same words and the same `data-test="not-found"` and `data-test="not-found-home"` hooks
as the page, so a test can read either.

## Walls

The controller skips the engine's `require_authentication`, so a signed-out visitor sees
the page. An app with its own default-deny wall must list the page as public, or the
wall's redirect costs the page its layout (the static file answers instead). The hub
lists it in `AdminWall::PUBLIC_ACTIONS`:

```ruby
"studio/not_found" => %w[show]
```

A real walled page still answers with its wall. Only an address the app does not have,
or a record it does not hold, reaches this page.

## What it skips

The page runs as the exceptions app. Rails calls it from `ShowExceptions`, which sits
outside the session and cookie middleware, so the request has already left them.
Nothing the page writes to the session or a cookie is saved. A callback that throttles
itself through the session (it stamps "done" and skips the next time) never holds here:
it pays its full cost on every 404. So `Studio::NotFoundController` turns off the
engine's callbacks of that kind:

| Callback | From | What it would cost on every 404 |
|----------|------|---------------------------------|
| `track_user_session` (after_action) | `Studio::ErrorHandling` | A new `Studio::UserSession` row for each signed-in 404 |
| `detect_geo_state` (before_action) | `Studio::GeoDetection` | An IP geo lookup, up to 3s |

The controller overrides both methods as no-ops. It does not skip the callbacks, so
they stay registered. An app that already skips them itself, even with a raising
`skip_before_action`, still boots; it can drop those lines when it bumps the engine.
An app without `Studio::GeoDetection` is unaffected. An app needs no initializer for
either.

`end_revoked_device_session` (`Studio::ErrorHandling`, [`DEVICE_SESSIONS.md`](DEVICE_SESSIONS.md))
stays on the page. It is not throttled: it reads one row and writes nothing to the
database, so a 404 for an ended device session renders signed out.

An app that adds its own session-throttled or network callback to
`ApplicationController` skips it on the page in an initializer:

```ruby
Rails.application.config.to_prepare do
  next unless defined?(Studio::NotFoundController)

  Studio::NotFoundController.skip_before_action :my_callback
end
```

## Where the words come from

| Part | Source |
|------|--------|
| The app's name | `Studio.app_name` |
| The brand mark | `Studio.navbar_brand[:logo]`, else `Studio.logo_for("Navbar Logo")`; none draws no image |
| The button home | `main_app.root_path`, else `/` |
| Go back | the `Referer`, only when it is a page on this host |

The page is the `studio/not_found` partial. It uses theme tokens only, so it reads in
light and dark, and it stacks its buttons at phone width. The style guide shows it as
**Not Found**, in the Pages group (`/admin/style`).

## Test it in the app

The test environment hides exceptions (`show_exceptions :rescuable` and
`consider_all_requests_local`), so an integration test turns them on for the request:

```ruby
def with_production_exceptions
  config = Rails.application.env_config
  saved = config.slice("action_dispatch.show_exceptions", "action_dispatch.show_detailed_exceptions")
  config["action_dispatch.show_exceptions"] = :all
  config["action_dispatch.show_detailed_exceptions"] = false
  yield
ensure
  config.merge!(saved)
end
```

Then assert `assert_response :not_found` and the `[data-test='not-found']` page.

**Its og:url is the app's home.** The page calls `link_preview(url: home)`, so a 404 at a hidden route (a component gallery's assets, say) never names that route in the link-preview tags its layout writes.
