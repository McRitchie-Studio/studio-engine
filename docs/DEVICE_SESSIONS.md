# Device sessions — a logout ends that device's session

Every app keeps its sessions in the encrypted cookie store, so the whole session
lives in the browser. Before this primitive a logout deleted only the browser's
copy: a copy of the pre-logout cookie (a stolen cookie, or a late response that
set the old cookie back) still signed in. Turf measured it (task
`turf-e2e-retry-only-causes`).

Now a logout ends **this device's** session on the server, and only that one.
Other devices of the same user stay signed in (Alex McRitchie's choice, option B,
2026-11-08). "Log out everywhere" is still the separate OPSEC-045 path: rotate
`user.session_token`.

Code: `Studio::UserSession` (`app/models/studio/user_session.rb`) and
`Studio::ErrorHandling` (`app/controllers/concerns/studio/error_handling.rb`).
Tests: `test/integration/user_session_revocation_test.rb` (unit) and
`test/integration/logout_ends_device_session_test.rb` (the replay suite).

## How it works

| Step | Where | What |
|------|-------|------|
| Sign-in | `set_app_session` | `Studio::UserSession.start!` writes a `studio_user_sessions` row with a random `sid` (24 bytes, URL-safe) and puts the sid in this app's mark (`session[:"<session_key>_session_mark"]`). A re-auth by the same user keeps the sid only while the sid is live: `start!` reads it again first (one query), and a revoked sid, or one with no row, gets a new sid. |
| Every signed-in request | `prepend_before_action :end_revoked_device_session` | `Studio::UserSession.verdict` reads the cookie's sid on the `sid` index: one query. Any revoked row of the sid, or no row: the request is signed out through the host's own `clear_app_session`, and runs as a visitor. |
| Tracking | `after_action :track_user_session` | Reuses the row the check read, so it adds no read. At most one write per 5 minutes, as before. After 30 idle minutes a new row starts with the **same** sid. |
| Logout | `clear_app_session` (the engine's `GET /logout`) and `reset_session` (Turf's logout, and a sign-in by a different identity) | `Studio::UserSession.revoke!` stamps `revoked_at` on every row of the sid and drops the mark. |
| Pruning | `Studio::UserSession.prune_due!`, run when a row is created | Deletes up to 1,000 rows last seen more than 90 days ago, at most once an hour per process. No host job. |

A failed revoke or start is written to `ErrorLog` and the logout or sign-in goes
on. A database fault in the check answers "no verdict" and signs nobody out: the
request's own user lookup needs the same database, and a copied cookie cannot
cause the fault. The fault is written to `ErrorLog` too, at most once per
`CHECK_FAILURE_LOG_EVERY` (5 minutes) per process, so an outage adds no write to
every request.

## Cookies from before this change

A signed-in cookie with no sid is accepted until
`Studio::UserSession.legacy_grace_until` (default 2026-12-08 UTC). Its request gives
it a sid (the pre-sid row its mark names takes the sid), so the deploy signs nobody
out. After that date a cookie that still has no sid is signed out once. The date
is the bound on the one gap: a copy of a pre-deploy cookie has no sid, so until the
date it still signs in after the device logs out.

A device idle for more than 90 days has no row left, so its cookie no longer signs
in, and the user signs in again.

## Single sign-on

The mark and the rows are per app. The `sid` is in this app's mark, and the row is
in this app's database. A logout in one app revokes that app's sid only. It keeps
the current SSO behaviour:

- The hub's `clear_app_session` still clears the `sso_*` awareness keys when the
  hub is the source, so the "Continue as" offer goes away in apps that share the
  cookie (`STUDIO_SSO_SHARED_COOKIE`).
- A satellite that already signed in through SSO keeps its own session on that
  device. Its sid is its own and is not revoked.
- On a shared cookie, Turf's `reset_session` deletes every app's keys from the
  browser (as before), but it revokes only Turf's sid.

## Off switches

- An app without the `sid` and `revoked_at` columns (it has not run
  `AddDeviceRevocationToStudioUserSessions`) checks nothing and tracks as before.
  The release sweep installs the migration in every member. The boot names the
  gap: `Studio::HostSchema.device_session_check!` logs a warning, and a Sentry
  warning, in every environment. It never raises, so a host's CI stays green until
  the sweep adds the columns. `Studio.host_schema_check = false` turns it off.
- Under test nothing is checked or written unless a test sets
  `Studio::UserSession.record_in_test = true`, so host query budgets hold.

## ActionCable

`/cable` connections read the session cookie directly, outside the controller
check. A host whose `ApplicationCable::Connection` authenticates from the session
refuses an ended device session with one line in its session reader:

```ruby
return nil if Studio::UserSession.respond_to?(:ended?) && Studio::UserSession.ended?(session)
```

`session` is `request.session` or the Hash decoded from the cookie. `ended?` is
true only for the `:ended` verdict; a live, legacy or unchecked cookie connects as
before. The `respond_to?` guard lets the line merge before the host's engine bump.

| App | Cable connection | Status |
|-----|------------------|--------|
| Hub (`mcritchie-studio`) | session user, OPSEC-045 token | calls `ended?` |
| Cyvasse | session user from the encrypted cookie | calls `ended?` |
| Turf | bare: no user, chat streams are public-read and Turbo signs stream names | nothing to refuse; a signed-out socket hears what a signed-out page does |
| Rolio | bare: no user | nothing to refuse |
| mcritchie-industries, moms-app | none | nothing to do |

A logout does not close a socket that is already open. The hub's
`ApplicationCable::Connection.disconnect(user)` drops a user's sockets on sign-out,
and the reconnect runs `connect` again, which now refuses the ended sid.
