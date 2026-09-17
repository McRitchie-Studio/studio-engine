# Session drift

A page is rendered for one session. The browser's session can change while that
page stays open: another tab signs in or out, the session expires, or the server
revokes it. This primitive lets every page notice, repair itself in place when it
can, and tell a deliberate switch from an accidental one.

It is generic web2. The engine knows sessions, accounts and fingerprints. It knows
nothing about what else a host binds a session to; a host plugs that in as an
**identity source** (see [Plugging in an external identity](#plugging-in-an-external-identity)).

- Server: `SessionContext` (states, fingerprint, stamp), `Studio::SessionFingerprint`,
  `Studio::SessionDrift` (included by `Studio::ErrorHandling`),
  `Studio::SessionStatesController` (`GET /session/state`, opt-in).
- Browser: `app/assets/javascripts/studio/session.js`, which publishes
  `window.StudioSession`.
- Delivery: `layouts/studio/_head` renders `studio/_session_stamp` on every page.

## States

| State | Meaning | Who reports it |
|-------|---------|----------------|
| `anonymous` | Nobody is signed in. A first-class state, not an error. | Server and browser |
| `authenticated` | Somebody is signed in and the page still describes them. | Server and browser |
| `stale` | The page learned its stamp is out of date; a rehydrate is due. | Browser |
| `changed` | An identity source observes someone other than the bound identity. | Browser |
| `rehydrated` | The page pulled the server's session in place and is signed in, possibly as someone new. | Browser |
| `signed_out` | The page was signed in and the server now reports nobody. | Browser |

`SessionContext::STATES` lists all six. `SessionContext::SERVER_STATES` lists the
two a server render can report; the other four exist only in a browser comparing
an old page with a newer truth.

## The stamp

Every page rendered by a `Studio::ErrorHandling` controller carries one:

```html
<meta name="studio-session" content="{&quot;v&quot;:1,&quot;state&quot;:&quot;authenticated&quot;, ...}">
```

| Field | Type | Meaning |
|-------|------|---------|
| `v` | integer | Stamp version. Bumped only when a field changes meaning. |
| `state` | string | `anonymous` or `authenticated`. |
| `fingerprint` | string | `"anonymous"`, or 32 hex characters naming the session. |
| `issuedAt` | integer | Epoch milliseconds when the server built the stamp. Tabs compare it to decide whose truth is newer. |
| `expiresAt` | integer or null | Epoch milliseconds when the session lapses, from the session store's `expire_after`. |
| `rehydrateUrl` | string or null | Where the store refetches the stamp. Null unless the host draws the route. |
| `identities` | object | `{ source name: bound identity }` for host-declared identity sources. Empty by default. |

It is a meta tag, not a JSON script tag, on purpose. Turbo merges the head on
every navigation. It never removes script elements, so a JSON script tag would
pile up one copy per visit, and a selector lookup would return the oldest. Meta
tags are replaced.

A head rendered anywhere else (a controller without `Studio::ErrorHandling`, the
e2e lab, a bare view in a unit test) emits no stamp and no store, byte-identical
to the head before this primitive existed. When the stamp itself fails in
production, the meta tag is omitted but the script still loads (dormant): the
script is Turbo-tracked, and Turbo fully reloads between pages whose tracked
scripts differ.

### The fingerprint

`Studio::SessionFingerprint.for(user, identities:)` is an HMAC-SHA256, truncated
to 32 hex characters, over:

- the user's id;
- the user's `session_token`, when the host has that column. Rotating it (log
  out everywhere) changes the fingerprint, so a page rendered before the rotation
  can see it was revoked;
- the identities bound to the session, sorted. Re-binding the session to another
  identity changes the fingerprint even when the account and token do not.

The key derives from the app's `secret_key_base`
(`Rails.application.key_generator`, purpose `studio/session-fingerprint`), so
every process of one app agrees. Set `Studio.session_fingerprint_secret` only to
pin a value. The fingerprint never carries the id or the token readably.

An anonymous session with no bindings is the plain constant `"anonymous"`, so
every signed-out tab agrees with every other.

## Server API

### `SessionContext`

All additive. `to_h` (the legacy `mode` payload a host's own client store reads)
is unchanged, and `onchain_session:` is now optional.

| Method | Returns |
|--------|---------|
| `#state` | `:anonymous` or `:authenticated` |
| `#anonymous?`, `#authenticated?` | Booleans |
| `#fingerprint(identities = {})` | The fingerprint string |
| `#to_stamp(rehydrate_url:, expires_at:, identities:, issued_at:)` | The stamp hash above |

### `Studio::SessionDrift` (included by `Studio::ErrorHandling`)

Helper methods only; no filters, no response changes.

| Helper | Purpose |
|--------|---------|
| `studio_session_context` | The request's `SessionContext`, built from `current_user`. |
| `studio_session_stamp` | The stamp. Raises on failure (the endpoint relies on that). |
| `studio_session_page_stamp` | The stamp as a page renders it. In production a failure goes to `ErrorLog` and the page renders without a stamp; development and test re-raise so a consumer's suite sees it. |
| `studio_session_identities` | **Host hook.** `{ source name => bound identity }`. Baseline `{}`. |
| `studio_session_rehydrate_url` | The endpoint path, or nil when the route is not drawn. |

### The rehydrate endpoint

Opt in from `config/initializers/studio.rb`:

```ruby
config.draw_session_routes = true
```

That draws `GET /session/state` (`studio_session_state_path`,
`Studio::SessionStatesController#show`), JSON only:

```json
{
  "session": { "v": 1, "state": "authenticated", "fingerprint": "...", "...": "..." },
  "context": { "loggedIn": true, "mode": "web2", "...": "..." },
  "csrf": "<fresh authenticity token>"
}
```

- `session` is the same stamp a page carries, so the store compares like with like.
- `context` is the host's `client_session_payload`, so a host store hydrated from
  that payload can refresh from the same response.
- `csrf` is fresh. Signing in or out resets the Rails session, which invalidates
  the token a stale page holds; the store swaps it into `meta[name="csrf-token"]`.

The action skips `require_authentication`: an anonymous browser gets a 200
describing an anonymous session. A host filter that revokes the session
(`verify_session_token` answers JSON with a 401) is still honoured, and the store
reads the 401 as revoked. Responses are `Cache-Control: no-store`.

**Why it is off by default.** It inherits the host's `ApplicationController`
filters, and the store calls it whenever a tab returns from the background or
learns another tab changed the session. Before opting in, check that no host
filter redirects this JSON GET (an onboarding redirect would answer with HTML).
Without the route, pages still carry the stamp and the store still detects drift;
it cannot repair a page in place, so the page stays `stale`.

## Browser API

`window.StudioSession`:

| Member | Purpose |
|--------|---------|
| `current()` | Snapshot: `{ state, reason, source, expected, fingerprint, identities, context, issuedAt, expiresAt, rehydrateUrl, mismatches }`. `state` is null while dormant. |
| `subscribe(fn)` | `fn(snapshot, detail)` on every transition. Returns an unsubscribe function. A throwing subscriber never starves the next. |
| `refresh()` | Rehydrates now and returns a Promise of the snapshot. A deliberate refresh is always `expected`. If a background probe is already on the wire, it waits for it and asks again. Resolves unchanged when there is no rehydrate URL. |
| `expectChange(scope, { timeoutMs })` | Declares a switch is coming. Returns `{ release(), isActive() }`. See [Holds](#holds). |
| `registerIdentitySource(source)` | Plugs in an identity source. Returns `{ unregister() }`. See [Identity sources](#identity-sources). |
| `observed(name)` | The last identity a source reported. |
| `configure({ revalidateAfterHiddenMs, holdTimeoutMs })` | Defaults 30000 and 60000. |
| `STATES`, `SESSION_SCOPE` | Constants. |

### Events

Dispatched on `document`. `event.detail` is
`{ state, previous, reason, source, expected, drift, observed, error, snapshot }`.

| Event | When |
|-------|------|
| `session:changed` | Every transition. |
| `session:mismatch` | Drift nobody declared (`drift && !expected`). The one a warning listens to. |

`reason` is one of `render`, `navigation`, `peer`, `expiry`, `server`, `manual`,
`revoked`, `restored`, `source`, `resolved`, `unregistered`, `rehydrate_failed`.

### Alpine

When Alpine is on the page, `Alpine.store('studioSession')` mirrors the snapshot,
plus `is(state)`. The store never touches a host's own stores (turf-monster keeps
`Alpine.store('session')` and its `#session-context` payload).

```html
<div x-show="$store.studioSession.is('signed_out')">You signed out in another tab.</div>
```

### Dormant without a stamp

With no meta tag the store fetches nothing, broadcasts nothing and reports
`state: null`, until a Turbo navigation brings a stamp in.

## How drift is detected

Everything is a source. The engine ships three web2 sources, together the
`session` scope:

| Source | Observes | On a mismatch |
|--------|----------|---------------|
| `peer` | Other tabs announce `{ fingerprint, state, issuedAt }` on the `studio-session` BroadcastChannel. Only a strictly NEWER, different fingerprint counts; an older one gets this tab's announce in reply. | `stale`, then rehydrate |
| `expiry` | A timer at the stamp's `expiresAt`. | `stale`, then rehydrate |
| `server` | Returning to a tab hidden for `revalidateAfterHiddenMs`, and a bfcache restore, probe the endpoint. A 401 reads as revoked. | Rehydrate |

A rehydrate then settles the page:

| The server answers | The page becomes |
|--------------------|------------------|
| The same fingerprint | Back to its previous state, silently |
| A different signed-in session | `rehydrated` |
| Anonymous, after being signed in (or a 401) | `signed_out` |
| Nothing usable (network error, bad body) | Stays `stale`; `rehydrate_failed` is drift |

Without a rehydrate URL, `stale` is final and is itself the drift.

A Turbo navigation re-seats the page from the new stamp. That is this tab's own
render, so it is never drift. A restored snapshot (Turbo's cache) carrying an
OLDER stamp goes `stale` with reason `restored` and rechecks with the server.

## Identity sources

```js
StudioSession.registerIdentitySource({
  name: "device",                    // required; unique; letters, digits, _ and -
  start(report) {                    // required; call report() whenever the identity changes
    const off = watchSomething((id) => report(id));
    return off;                      // optional stop function, called by unregister()
  },
  bound(snapshot) { ... },           // optional; default snapshot.identities[name]
  equals(bound, observed) { ... }    // optional; default ===
});
```

- `report(undefined)` means "cannot tell" and changes nothing.
- `report(null)` means "observes nobody".
- `report("id")` means "observes this identity".
- A source whose bound identity is null is **unbound**: it records what it sees
  but never mismatches. An anonymous page with an identity in view is not a warning.
- A mismatch moves the page to `changed` and fires `session:mismatch` unless held.
  When the source reports the bound identity again, the page returns to its
  previous state (`reason: "resolved"`), and that is not a warning.
- Reserved names: `peer`, `expiry`, `server`, `session`, `*`.

The server half is the host hook. The stamp's `identities` and the fingerprint
both come from it:

```ruby
class ApplicationController < ActionController::Base
  include Studio::ErrorHandling

  private

  def studio_session_identities
    { device: session[:device_id] }
  end
end
```

## Holds

A flow that switches identity on purpose declares it first:

```js
const hold = StudioSession.expectChange("device");        // one source
const hold = StudioSession.expectChange(["device", "session"]);
const hold = StudioSession.expectChange("*", { timeoutMs: 120000 });
```

While a matching hold is active, drift still transitions the state and still fires
`session:changed`, with `expected: true`. It does not fire `session:mismatch`.
Scopes are a source name, `"session"` (the three web2 sources) or `"*"`. Holds
expire (60 seconds by default), so a forgotten hold cannot hide drift forever.
Call `hold.release()` when the flow ends.

## Plugging in an external identity

The engine stays web2. A web3 layer plugs into it from outside, with no engine
change. For turf-monster, planned in `ceremony-page-lacks-wallet-signal`:

- **Server (turf-monster):** `studio_session_identities` returns
  `{ wallet: <the address this session authenticated with> }`. The address is in
  the stamp and in the fingerprint, so a re-bind in one tab reaches the others.
- **Browser (solana-studio's JS):** one source named `wallet` that reports the
  connected provider's address whenever it changes, and `undefined` while the
  provider cannot say.
- **A signing ceremony:** `expectChange("wallet")` before a deliberate switch,
  re-authenticate, then `StudioSession.refresh()`. An undeclared switch arrives
  as `session:mismatch`.

## Adopting it in a host

1. Nothing, for the stamp and detection: bumping the engine puts both on every page.
2. Opt in to the endpoint (`config.draw_session_routes = true`) after checking
   the host's filters let `GET /session/state` answer JSON.
3. Subscribe where a page cares: `document.addEventListener("session:mismatch", ...)`
   or `$store.studioSession`.
4. Override `studio_session_identities` only if the host binds the session to
   something beyond the account.

## Limits

- Cross-tab sync needs `BroadcastChannel`. Without it the `server` and `expiry`
  sources still work; there is no `localStorage` fallback.
- There is no polling interval. Probes happen on return to a hidden tab and on
  bfcache restore.
- The store never reloads a page or signs anyone out. It reports; the page decides.
- `SessionContext`'s legacy `mode` half (`guest`/`web2`/`web3`, `phantom_linked?`,
  `address`) predates this primitive and is unchanged for existing consumers. New
  session vocabulary goes in the stamp, never in `to_h`.

## Tests

| File | Covers |
|------|--------|
| `test/lib/studio/session_fingerprint_test.rb` | Fingerprint properties |
| `test/lib/studio/session_context_test.rb` | States, stamp shape, the frozen `to_h` |
| `test/integration/session_drift_test.rb` | The stamp on a real page, fingerprint changes, the endpoint, revocation, opt-in |
| `test/views/studio_session_store_test.rb` + `test/support/session_store_harness.js` | The store executed under node, one vm context per tab, every scenario asserted by name; delivery wiring |
| `e2e/session_drift.spec.js` | A real browser: the engine head delivers a running store before Alpine, and two tabs hear each other over BroadcastChannel |
| `test/lib/session_drift_vocabulary_test.rb` | No wallet, signer, Solana or chain vocabulary in the primitive's code |
