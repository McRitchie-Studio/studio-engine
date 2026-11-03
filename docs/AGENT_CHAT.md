# Agent chat

One chat with one agent, on any app's page, answered by the McRitchie Studio
hub's agents. The hub holds every thread (one per person and soul, the same on
every app); the app stores no message. Plan: `.agents/epics/agent-chat-primitive.md`.

```text
browser ──POST /agent_chat/messages──▶ app (Studio::AgentChatsController) ──POST hub /api/v1/agent_chat/messages──▶ hub
browser ──GET  /agent_chat/turns?after=<id>──▶ app ──GET hub /api/v1/agent_chat/turns──▶ hub
```

## Adopting it

1. **Name the souls** your pages may chat with, in `config/initializers/studio.rb`.
   This allow-list is the gate: with no soul, `Studio.routes` draws no
   `/agent_chat` route.

   ```ruby
   Studio.agent_chat_souls = %w[alex]
   # Studio.agent_chat_hub_url = "https://mcritchie.studio"   # the default
   ```

2. **Set the app's credential** as `AGENT_CHAT_TOKEN` (Heroku config; 1Password
   `apps.<slug>.agent-chat`). The hub stores only its digest and must list your
   app under `config/agent_routes.yml` `web: apps:` for that soul. Or set
   `Studio.agent_chat_token` directly.

3. **Render the chat** on any page:

   ```erb
   <%= render "studio/agent_chat/chat", soul: "alex", name: "Alex",
              portrait: image_tag("alex.png", class: "w-24 h-24 rounded-full object-cover") %>
   ```

   | Local | Meaning |
   |-------|---------|
   | `soul:` | The agent's slug. Must be on `Studio.agent_chat_souls`, or the render raises. |
   | `name:` | The agent's display name: header, composer placeholder, typing line. |
   | `portrait:` | Ready markup for the big round portrait (96px works). Nil shows the name's initial. |
   | `role:` | Optional text or markup under the name. |
   | `empty:` | Optional line for an empty thread (default "Say hello to <name>."). |
   | `cards:` | **The card slot**: ready markup between the header and the thread (a `capture` block). /build puts its intake cards here. |
   | `voice:` | `true` puts hold to talk in the composer ("Talking by voice" below). Off by default. |
   | `voice_copy:` | The words of that option: `{ privacy:, recorder:, chip: }`, each optional. |

   One page holds one chat. The page needs the engine's head
   (`layouts/studio/_head`), which every host already renders: the chat's script
   is the lazy `agent-chat` controller on the engine's Stimulus application.

## Who may use it

`Studio.agent_chat_allowed` is a callable taking the user, **nil when signed out**.
Default: everyone, a public chat. It is the server's gate, not only the look: the
`/agent_chat` routes skip sign-in, so with `AGENT_CHAT_TOKEN` set anyone can POST
there even with every link hidden, and the hub answers. A refused viewer gets
`403 {error, reason: "not_allowed"}` on both calls, before any hub call and with no
anon cookie, and the chat partial renders nothing for them. One setting covers the
footer's Chat link too, unless `site_footer_chat_allowed` says otherwise, and a user
it refuses may not talk by voice. A hook that raises closes the chat and logs.

```ruby
config.agent_chat_allowed = ->(user) { user&.admin? }   # admins only, while testing
```

## What the browser may choose

- **The soul** only from `Studio.agent_chat_souls`. Off the list is a 404; with
  one soul on the list a request naming none uses it. The hub checks again that
  your app may address that soul.
- **Never the person, and only a PROVEN email.** The hub keys a person's
  threads on their email across every app, so a claimed address would open its
  owner's thread. The proxy sends `current_user.email` only when the user's
  `email_verified_at` is present (the engine's magic link stamps it, as does
  the host `from_omniauth` pattern in [`GOOGLE_AUTH_SETUP.md`](GOOGLE_AUTH_SETUP.md);
  the profile page clears it when the address changes, and the engine's
  password signup never sets it). Set `Studio.agent_chat_verified_email = ->(user) { ... }` to use
  another proof: it answers the proven address or nil, and when set it decides
  alone. Everyone else, signed out or signed in unverified, chats as an
  anonymous visitor: a random token from a signed, http-only cookie
  (`studio_agent_chat_anon`, one year), minted on the first message. A signed-out
  visitor who has never written is answered `{turns: [], pending: false}` without
  asking the hub.
- **The fold on sign-in.** A verified `POST /agent_chat/messages` from a browser
  that still holds the anon cookie sends `person: {email, anon_token}`, and the
  hub folds that anonymous thread into the person's. After the hub's 201 the
  proxy deletes the cookie, so the fold happens once; on any failure the cookie
  is kept for the retry. A verified user is never minted a token, a verified
  post with no cookie sends `{email}` alone, and a verified
  `GET /agent_chat/turns` always sends `{email}` alone (the fold is the hub's
  job, on a post). So a visitor who chats signed out, then signs in with a
  verified address, keeps the thread once they send their next message.
- **Never the IP.** The proxy sends `request.remote_ip`, which the hub caps on.
- **`voice` only as a measurement.** See "Talking by voice".

The POST is CSRF-protected (the host's `protect_from_forgery`, forced to
`:exception` on this controller); the composer's form carries the token and the
script sends it as `X-CSRF-Token`. Every answer is JSON with `Cache-Control: no-store`.

## Answers

| Proxy answer | When |
|--------------|------|
| `201 {turn}` | the hub stored the message; `{turn, voice}` when it answered what it kept of a spoken one |
| `200 {turns, pending}` | the thread after `after` (a turn id), at most `limit` (≤ 50) |
| `422 {error}` | a blank or over-4,000-character message, a malformed `voice`, or the hub's own refusal (its reason) |
| `429 {error, retry_after}` | the hub's cap; `Retry-After` is passed on |
| `403 {error, reason: "not_allowed"}` | `Studio.agent_chat_allowed` refused this viewer; the hub was not asked |
| `404 {error}` | a soul off the list, or one the hub has no web chat for |
| `503 {error, retry: true}` | the hub is down, slow, answered 5xx or garbage, refused the app's credential (401/403), or the app has no token. The visitor sees "Can't reach <name> right now" and **Try again**; the cause is in the log. |

## Turns: keyed by id and role

The hub answers one message row as two turns that share the row's id and
status: the visitor's words (`role: "user"`) and, once answered, the agent's
(`role: "agent"`). A turn is therefore identified by **(id, role)**, never by id
alone: `turnKey` in `studio/agent_chat` is `"<id>:<role>"`, `mergeTurns` keys by
it, and each turn's element carries it as `data-turn-key` (plus the bare row id
as `data-turn-id`). Keyed by id alone, the answer would replace the visitor's
own message. A new agent turn is placed right after its own user turn, so a
visitor who sends A, then B before A is answered, sees A's answer under A.
`after` is a row id (rows with id > after).

## Talking by voice

```erb
<%= render "studio/agent_chat/chat", soul: "alex", name: "Alex", voice: true %>
```

A microphone chip and a hold-to-talk button sit in the composer, under the box,
and the privacy line under the composer. A take goes:

```text
recorder ──take──▶ studio/agent_chat_voice ──POST /voice/takes (multipart)──▶ {text, speaker, score, check, duration_ms}
                   studio/agent_chat_voice ──POST /agent_chat/messages {soul, text, voice}──▶ proxy ──▶ hub
```

**Who gets the mic.** All of these, or the chat renders as it always did:

1. the render passes `voice: true`;
2. the app turned takes on (`Studio.voice_transcription`; no route otherwise);
3. someone is signed in. `POST /voice/takes` is sign-in only and each take is paid,
   so a signed-out visitor never sees it, whatever the hook says;
4. `Studio.agent_chat_allowed` lets them chat at all, and
   `Studio.voice_chat_allowed`, a callable taking the user (default: anyone signed
   in), says yes. A hook that raises says no, and logs.

**The hook is the gate, not only the look.** `POST /voice/takes` answers a user it
refuses `403 {error, reason: "not_allowed"}` before counting or transcribing, and
the proxy drops their `voice` (the words still go, as typed).

**`voice` is a measurement, never a name.** The exact field the proxy sends the hub,
beside `soul`, `text`, `person` and `ip`:

```json
{ "voice": { "check": "matched", "score": 0.8731, "duration_ms": 2140 } }
```

`check` must be one of `Studio::VoiceTranscription::CHECKS` (else a 422); `score` is
a cosine clamped to -1..1 at 4 places, or null; `duration_ms` is
1..`MAX_DURATION_MS`, or null. Anything else in the post, a browser-chosen name
above all, stops at `Studio::AgentChat.voice_param`. The hub names the speaker
itself: the verified person's own name when `check` is `matched`, else "Someone
new", and an anonymous visitor is always "Someone new". The status line says who
the hub answered it kept (`{turn, voice: {speaker}}`), or a plain "Sent." when it
answers no `voice`. On the hub the same two paths are answered in-process
(`HubAgentChatsController`); the proxy is not involved.

**The status line** (`data-agent-chat-voice-status`, set as text) and its state
(`data-agent-chat-voice-state`):

| State | When |
|-------|------|
| `idle`, `listening` | Between takes, and while the button is held. A new hold clears the last take's line. |
| `transcribing`, `sending`, `sent` | The take's journey. `sent` names the speaker the server kept. |
| `queued` | A take landed while another is being transcribed. It waits its turn, in order; none is dropped. |
| `silent` | The recorder heard nothing. Nothing is sent. |
| `no_speech` | `/voice/takes` heard no words (422). |
| `not_configured` | No voice key on this app (503). |
| `rate_limited` | 429 on the take or the send, with the wait when the server gives one. |
| `refused` | 401 ("Sign in again to talk."), 403, 413, 415, or another 422. |
| `failed` | The transcriber failed, the network failed, or the send failed. |

**No words are lost.** A send that fails puts the words in the box, after anything
already typed, and says so; press send to try again.

**The words.** `Studio::AgentChat::VOICE_PRIVACY` is the privacy line Alex McRitchie
approved on 2026-11-01: use the constant on the privacy page too. `voice_copy:
{ privacy: "..." }` replaces it beside the mic; a blank one is the default, never
none. `recorder:` and `chip:` merge over `VOICE_RECORDER_COPY` and `VOICE_CHIP_COPY`
one level deep, as the partials' `copy:` does ([`VOICE_CAPTURE.md`](VOICE_CAPTURE.md)).

### Adopting voice: the checklist

The steps an app's adoption task follows, in order. Nothing here is on by default.

1. **Bump the engine** to a release carrying this.
2. **Souls.** `config.agent_chat_souls = %w[alex]` (or the app's own soul), and the
   hub lists the app under `config/agent_routes.yml` `web: apps:`.
3. **`AGENT_CHAT_TOKEN`** in the app's Heroku config (1Password
   `agent-chat.<slug>.applications`). The hub stores its digest.
4. **A verified email.** The app's `users` has `email_verified_at`, or set
   `config.agent_chat_verified_email`. Without one every user is an anonymous
   visitor, and every take says "Someone new".
5. **`STUDIO_VOICE_OPENAI_API_KEY`**, the app's own, never another app's
   ([`VOICE_TRANSCRIPTION.md`](VOICE_TRANSCRIPTION.md)). Without it a take answers
   the `not_configured` line and nothing crashes.
6. **Turn takes on**, in `config/initializers/studio.rb`:

   ```ruby
   config.voice_transcription = true
   # A SHARED counter: per-process memory lets each dyno count alone.
   config.voice_takes_rate_limit = { to: 20, within: 600, store: Rack::Attack.cache.store }
   # While testing, who may use the chat at all (default: everyone). The server
   # refuses anyone else with a 403 before the hub; the footer link follows it:
   config.agent_chat_allowed = ->(user) { user&.admin? }
   # Who may talk (default: anyone signed in the chat allows):
   # config.voice_chat_allowed = ->(user) { user.admin? }
   ```

   **Set `agent_chat_allowed` before `AGENT_CHAT_TOKEN` reaches production on an
   app whose chat is not meant to be public:** hiding the link is not a gate.

7. **QA runs the mock.** `STUDIO_VOICE_TRANSCRIBER=mock` on the QA app, which runs
   `RAILS_ENV=production` and would otherwise spend the real key.
8. **CSP, only if `config.voice_profile` is on.** With a saved voice the page runs
   the embedder in the browser, so add the entries in
   [`VOICE_PROFILE.md`](VOICE_PROFILE.md), step 3 (jsDelivr's transformers path,
   `huggingface.co`, `*.hf.co`). Without `voice_profile`, no entry is needed and
   every take says "Someone new". Allow the microphone too: a
   `Permissions-Policy` must not deny `microphone=(self)`
   ([`VOICE_CAPTURE.md`](VOICE_CAPTURE.md), "What a host must allow").
9. **Render it**: `voice: true` on the chat. The page needs the engine's head.
10. **Privacy page.** Add `Studio::AgentChat::VOICE_PRIVACY` verbatim.
11. **Footer.** `config.site_footer_chat_path`; the link follows
    `agent_chat_allowed` ([`SITE_FOOTER.md`](SITE_FOOTER.md), "The Chat link"). A signed-in admin sees the
    footer only on `site_footer_controllers`.

## The hub client

`Studio::AgentChat.post_message(soul:, text:, person:, ip:, voice:)` and
`Studio::AgentChat.turns(soul:, person:, after:, limit:)` are the two calls, usable
outside the controller. `person` is `{email:}`, `{anon_token:}`, or both (a
signed-in post that folds the visitor's anonymous thread). Every failure is
a `Studio::AgentChat::Error`: `Unavailable`, `Unauthorized`, `UnknownSoul`,
`Invalid`, `Capped` (`#retry_after`).

Bounds: 3 seconds to connect and finish TLS (`OPEN_TIMEOUT`), 8 seconds per read
or write (`READ_TIMEOUT`, `WRITE_TIMEOUT`), no silent retry. The bearer credential
goes only over TLS: a plain-`http` hub URL is refused unless its host is this
machine (a developer's local hub).

## The page's script

`studio/agent_chat` (mounted by `studio/controllers/agent_chat_controller`):

- loads the latest turns on connect; a failure shows the offline notice and
  retries every 15 seconds, or at once on **Try again**;
- polls every 2.5 seconds while an answer is pending, 10 seconds after two
  minutes of waiting, 30 seconds otherwise, and not while the tab is hidden (it
  asks at once when the tab comes back). Each
  poll sends `after` = the row id of the last turn before the first unsettled one,
  so a pending row is asked about until it settles (an unsettled row's user turn
  is itself unsettled, so the cursor lands on an earlier row);
- Enter sends, Shift+Enter is a new line; the words stay in the box until the
  app answers 201, and a refusal shows its reason above them;
- keeps the thread at its end while the reader is within 20px of it;
- answers **the public refresh hook**: dispatch `studio:agent-chat:refresh` on the
  chat's section, optionally with `{ detail: { turn } }` (a turn your code just
  got from the app). The turn shows at once with the typing line, the thread
  follows it, and the chat polls now; a poll already in flight is followed by one
  more, so a refresh is never swallowed. Use this, never a click on Try again;
- shows "<name> is thinking", then "<name> is typing" once a turn's status is
  `typing`, and "<name> could not answer this one" on a `failed` turn.

Turn text is set as text, never HTML. The look is the partials under
`app/views/studio/agent_chat/` and `.studio-agent-typing` in `engine-motion.css`,
all on theme tokens, so dark mode follows the host theme. The typing line needs
the motion layer, which the default Tailwind entry (`host.css`) imports; a host
that imports only `engine.css` sees both of its labels.

## Tests

- `test/lib/studio/agent_chat_test.rb`: the client against a stub hub on a real
  socket (both calls, timeouts, error mapping).
- `test/integration/agent_chat_proxy_test.rb`: the dummy host's page
  (`/agent_chat_lab`) and the proxy, signed in and signed out.
- `test/javascript/agent_chat.test.mjs`: the script's merge (a user turn and an
  agent turn sharing a row id both survive), cursor, cadence and follow rules.
- `e2e/agent_chat.spec.js`: the chat in a browser against the stand-in hub
  `e2e/boot.rb` runs (`AgentChatStubHub#converse!`, the hub's shared-id shape).
- `test/javascript/agent_chat_voice.test.mjs`: every refusal line, the take's body,
  `voice` carrying no name, a queued take, a failed send keeping the words.
- `e2e/agent_chat_voice.spec.js`: a real hold at 390px, light and dark, through the
  mock transcriber and the proxy to the stand-in hub, and the footer's Chat link.
