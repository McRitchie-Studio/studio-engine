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

   One page holds one chat. The page needs the engine's head
   (`layouts/studio/_head`), which every host already renders: the chat's script
   is the lazy `agent-chat` controller on the engine's Stimulus application.

## What the browser may choose

- **The soul** only from `Studio.agent_chat_souls`. Off the list is a 404; with
  one soul on the list a request naming none uses it. The hub checks again that
  your app may address that soul.
- **Never the person.** Signed in, the proxy sends `current_user.email`. Signed
  out, it sends a random token from a signed, http-only cookie
  (`studio_agent_chat_anon`, one year), minted on the first message. A signed-out
  visitor who has never written is answered `{turns: [], pending: false}` without
  asking the hub.
- **The fold on sign-in.** A signed-in `POST /agent_chat/messages` from a browser
  that still holds the anon cookie sends `person: {email, anon_token}`, and the
  hub folds that anonymous thread into the person's. After the hub's 201 the
  proxy deletes the cookie, so the fold happens once; on any failure the cookie
  is kept for the retry. A signed-in visitor is never minted a token, a
  signed-in post with no cookie sends `{email}` alone, and a signed-in
  `GET /agent_chat/turns` always sends `{email}` alone (the fold is the hub's
  job, on a post). So a visitor who chats signed out, then signs in, keeps the
  thread once they send their next message.
- **Never the IP.** The proxy sends `request.remote_ip`, which the hub caps on.

The POST is CSRF-protected (the host's `protect_from_forgery`, forced to
`:exception` on this controller); the composer's form carries the token and the
script sends it as `X-CSRF-Token`. Every answer is JSON with `Cache-Control: no-store`.

## Answers

| Proxy answer | When |
|--------------|------|
| `201 {turn}` | the hub stored the message |
| `200 {turns, pending}` | the thread after `after` (a turn id), at most `limit` (≤ 50) |
| `422 {error}` | a blank or over-4,000-character message, or the hub's own refusal (its reason) |
| `429 {error, retry_after}` | the hub's cap; `Retry-After` is passed on |
| `404 {error}` | a soul off the list, or one the hub has no web chat for |
| `503 {error, retry: true}` | the hub is down, slow, answered 5xx or garbage, refused the app's credential (401/403), or the app has no token. The visitor sees "Can't reach <name> right now" and **Try again**; the cause is in the log. |

## Turns: keyed by id and role

The hub answers one message row as two turns that share the row's id and
status: the visitor's words (`role: "user"`) and, once answered, the agent's
(`role: "agent"`). A turn is therefore identified by **(id, role)**, never by id
alone: `turnKey` in `studio/agent_chat` is `"<id>:<role>"`, `mergeTurns` keys by
it, and each turn's element carries it as `data-turn-key` (plus the bare row id
as `data-turn-id`). Keyed by id alone, the answer would replace the visitor's
own message. `after` is a row id (rows with id > after).

## The hub client

`Studio::AgentChat.post_message(soul:, text:, person:, ip:)` and
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
  minutes of waiting, 30 seconds otherwise, and not while the tab is hidden. Each
  poll sends `after` = the row id of the last turn before the first unsettled one,
  so a pending row is asked about until it settles (an unsettled row's user turn
  is itself unsettled, so the cursor lands on an earlier row);
- Enter sends, Shift+Enter is a new line; the words stay in the box until the
  app answers 201, and a refusal shows its reason above them;
- keeps the thread at its end while the reader is within 20px of it;
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
