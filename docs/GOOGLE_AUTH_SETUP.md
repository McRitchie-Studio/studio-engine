# Google OAuth Setup

Google sign-in ships ready with studio-engine. A new app gets the "Sign in with
Google" button, the OmniAuth strategy and a default `User.from_omniauth` with no
gem, initializer or User code of its own. What is left is one manual step: give
the app an OAuth client.

## What the engine ships

| Piece | Where | A host that has its own |
|---|---|---|
| `omniauth`, `omniauth-google-oauth2`, `omniauth-rails_csrf_protection` | gemspec runtime dependencies, required by `lib/studio/engine.rb` | keeps its Gemfile lines; same gems |
| The `google_oauth2` strategy (POST-only request phase, `scope: "email,profile"`, `prompt: "select_account"`) | `Studio::GoogleSignIn::Middleware`, added by the `studio.google_sign_in` initializer | its own `OmniAuth::Builder` wins; the engine's middleware passes the request through |
| `User.from_omniauth` | `Studio::OmniauthUser` (`app/models/concerns/studio/omniauth_user.rb`) | its own `def self.from_omniauth` wins |
| The callback | `OmniauthCallbacksController`, drawn by `Studio.routes` | turf-monster overrides the controller; unchanged |
| The button | `studio/google_sign_in/_button`, on `/login`, `/signup` and the `/profile` Google row | an app that renders its own auth card keeps it |

### How the engine knows the host registered Google

The engine's initializers run before the host's `config/initializers`, so at boot
the host's `OmniAuth::Builder` is not on the stack yet. The engine therefore adds
its middleware unconditionally and decides per request. Once the app's
middleware stack is built, `Studio::GoogleSignIn.host_registered?` reads it
(`Rails.application.config.middleware.middlewares`) and memoizes the answer:

- an entry whose class is `OmniAuth::Strategies::GoogleOauth2` counts;
- an `OmniAuth::Builder` entry counts when its block calls `provider
  :google_oauth2` (or names the strategy class). The block is evaluated against a
  recorder that registers nothing;
- a Builder that registers only other providers does not count, so the engine
  still supplies Google beside them;
- a block the recorder cannot evaluate counts, because two strategies on one path
  is the failure this exists to prevent.

`Studio::GoogleSignIn.registration` answers `:host`, `:engine` or `:none`.

### The button's two states

`Studio.google_ready?` is true when `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`
are both set.

- **Ready.** The button is a POST form to `/auth/google_oauth2`. It is also
  ready when the host registered its own provider (that host owns its own
  readiness, and its tests post with no credentials) or OmniAuth is in test mode.
- **Not yet.** The button stays visible and opens a modal: Google sign-in is
  still being set up for this app. The modal offers **Request Google setup** and
  **Use email instead** ("Not now" on `/profile`). With no client, the engine's
  strategy is off, so a direct POST to `/auth/google_oauth2` answers 404
  rather than sending the person to a Google error page.

**Request Google setup** posts to `POST /_studio/google_setup_request`
(`Studio::GoogleSetupRequestsController`). It writes a `[google-setup]` log line
on every request, and at most once per host per day it mails
`Studio.google_setup_request_to` (default `team@mcritchie.studio`) through the
app's own mailer (`Studio::GoogleSetupMailer`, sent from `Studio.mailer_from`).
The email carries the app name, the host and the exact redirect URI to register.
The daily claim is a `Rails.cache` key (`studio/google_setup_request/<host>/<date>`);
an app whose cache is a `NullStore` falls back to an in-process store, so it
still gets one email per dyno per day.

## The manual step: give the app an OAuth client

1. **Register the redirect URI** on the shared production OAuth client, in Google
   Cloud project `enduring-maxim-491202-t6`. Steffon does this from the admin@
   Chrome profile. The URI is
   `https://<host>/auth/google_oauth2/callback`, exactly what the setup-request
   email names. For a local desk, use `http://localhost:{PORT}/auth/google_oauth2/callback`.
2. **Set the two env vars** on the app, then restart it:

   ```bash
   heroku config:set GOOGLE_CLIENT_ID=... GOOGLE_CLIENT_SECRET=... --app your-app
   ```

   Locally they go in the app's own `.env` (`dotenv-rails`), hydrated from the
   credential inventory. Never paste a secret into a chat or a log. A local boot
   must not carry the production client's secret (hub
   `Devops::GoogleOAuthClients`).

Once both are set, the button posts straight to Google.

## User model

The default `from_omniauth` needs `provider:string` and `uid:string` on `users`
(plus the usual unique `email`). In order, it:

1. finds the account holding this Google id (`provider` + `uid`);
2. else links the account holding the address, compared case-insensitively, but
   only when Google verified it; an unverified match answers
   `:email_not_verified`;
3. else creates an account, with the address downcased.

If the new account's `name_slug` is blank or already taken (a second "Mia"), the
slug becomes `user-<id>` instead of failing on the unique slug index. A collision
with nobody to find is logged with `ErrorLog.capture!` and the sign-in is refused
with a "use another method" message rather than a 500.

To use your own rules, define `def self.from_omniauth(auth, email_verified: false)`
on `User`; it wins. To keep the default under its own name, `include
Studio::OmniauthUser`. See [USER_CONTRACT.md](USER_CONTRACT.md).

## Apps that wire Google themselves

The hub, turf-monster, moms-app, cyvasse and acquisition-studio carry
`config/initializers/omniauth.rb` and their own `from_omniauth`. They keep
working unchanged: the engine sees their provider and stands aside, and their
`from_omniauth` is the one called. Such an app may delete its initializer, its
three Gemfile lines and its `from_omniauth` to take the engine's, but it does not
have to. Keep the initializer if it does more than register the provider (the
hub pins the callback host with `CanonicalHost.pin_omniauth!`).

`OmniAuth.config.allowed_request_methods = [:post]` is set by the engine; a host
that sets it too runs later and wins.

## Current apps

| App | Port | Dev URI | Prod URI |
|-----|------|---------|----------|
| McRitchie Studio | 3000 | `http://localhost:3000/auth/google_oauth2/callback` | `https://app.mcritchie.studio/auth/google_oauth2/callback` |
| Turf Monster | 3100 | `http://localhost:3100/auth/google_oauth2/callback` | `https://app.turfmonster.media/auth/google_oauth2/callback` |
| Tax Studio | 3200 | `http://localhost:3200/auth/google_oauth2/callback` | `https://tax.mcritchie.studio/auth/google_oauth2/callback` |

## Troubleshooting

- **The button opens "Google sign-in is still being set up".** `GOOGLE_CLIENT_ID`
  or `GOOGLE_CLIENT_SECRET` is unset on this app. Do the manual step above.
- **"No route matches [POST] /auth/google_oauth2".** The same cause: with no
  client the engine's strategy is off.
- **GET `/auth/google_oauth2` does not start OAuth.** Expected. The request phase
  is POST-only; use `button_to` or a POST form.
- **"redirect_uri_mismatch".** The callback is not registered on the OAuth client.
  Register the exact URI from the setup-request email.
- **OmniAuth warns that it builds callback URLs from the request's host.** Pin the
  host (`OmniAuth.config.full_host`, or the hub's `CanonicalHost.pin_omniauth!`)
  on an app that answers on more than one hostname.
