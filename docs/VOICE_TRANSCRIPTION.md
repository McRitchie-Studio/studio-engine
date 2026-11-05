# Voice transcription: who spoke and what they said

The server half of the voice layer. A finished take from the recorder
([`VOICE_CAPTURE.md`](VOICE_CAPTURE.md)), plus the speaker embedding the browser
made of it ([`VOICE_PROFILE.md`](VOICE_PROFILE.md)), becomes
**`{text, speaker, score}`**. It is card 3 of the Studio Voice epic; the hub's
agent chat (card 4, hold to talk to Alex) is its first consumer.

Ported from Voicebox: `Transcription::OpenAI` and `Transcription::Mock`, the
adapter selection in `config/initializers/voicebox.rb`, the
`VOICEBOX_NO_LIVE_CALLS` trap, and `RecordingPipeline.no_speech_reason`. Who
spoke reuses the engine's own `Studio::VoiceMatch` and the user's saved voice
(`users.voice_embedding`); there is no second profile store. Named people
without an account (a child in a household) are a later card.

```text
recorder ──studio:voice-recorder:take {blob, mimeType, durationMs}──▶ page
page (embeds the take on the device) ──POST /voice/takes (multipart)──▶ Studio::VoiceTakesController
  ──▶ Studio::VoiceTranscription.hear ──▶ transcriber (mock | openai) + VoiceMatch against current_user
  ◀── 200 {text, speaker, score, identified, check, duration_ms}
```

## What is kept

The take's audio **does leave the app**: it goes to the speech-to-text vendor
(OpenAI, under the app's own key) to be transcribed. Name OpenAI, and that a
spoken message's audio is sent to it and not kept, on the app's privacy page
and beside the microphone where the take is recorded.

**The app keeps nothing.** The upload is read once, handed to the transcriber, and its
tempfile is deleted before the answer. No row is written. `voice[audio]` and
`voice[embedding]` are in the engine's parameter filter (beside the profile's
`voice[embeddings]`), so neither reaches a request log. A failure's `ErrorLog`
row carries the engine's own words (the model, the HTTP status and a reason
code) on the user who sent the take (`target`); the vendor's error text, the
audio and the vector never reach it.

## Turn it on in an app

1. Install the voice profile migration if the app has not
   ([`VOICE_PROFILE.md`](VOICE_PROFILE.md), step 1); without the columns every
   take answers `check: "no_profile"` and still transcribes.
2. In `config/initializers/studio.rb`:

   ```ruby
   Studio.configure do |config|
     config.voice_transcription = true            # draws POST /voice/takes
     # config.voice_transcriber = "openai"        # default: openai in production, mock elsewhere
     # config.voice_openai_api_key = ...          # default: ENV["STUDIO_VOICE_OPENAI_API_KEY"]
     # config.voice_takes_rate_limit = { to: 20, within: 600 }   # per user; false turns it off
     # config.voice_transcribe_deadline = 25      # seconds, both models together
     # config.voice_chat_allowed = ->(user) { user.admin? }   # who may post a take; default anyone signed in
   end
   ```

3. Set the app's own **`STUDIO_VOICE_OPENAI_API_KEY`** in its Heroku config (or
   `Studio.voice_openai_api_key`): voice's own key, on its own budget. The
   app's shared `OPENAI_API_KEY` (on the hub, the image key) is **never** read.
   Each app holds its own key; never copy another app's. Without one the
   endpoint answers the 503 below, and nothing crashes.

## The endpoint: `POST /voice/takes`

Drawn by `Studio.routes` only when `Studio.voice_transcription` is on (every
take is a paid vendor call). Route name `studio_voice_takes`.

- **Signed in only**: the host's `require_authentication` (a JSON `401` when
  signed out).
- **CSRF-protected**: send the page's token as `X-CSRF-Token`. A bad or missing one is
  `422 {error, reason: "invalid_token"}` with no ErrorLog row (`Studio::ErrorHandling`).
- **JSON answers**, `Cache-Control: no-store`.
- **Rate-limited per user**: at most `Studio.voice_takes_rate_limit` takes
  (default 20 in any 10-minute window, a fixed window per user id). Over it,
  the `429` below, before the take is read or sent anywhere. The counter lives
  in `Rails.cache` (or the config's `store:`); when that is a `NullStore`, a
  per-process memory store, so the limit never goes inert. It instruments
  `rate_limit.action_controller` as Rails' own `rate_limit` does.

### Request (multipart/form-data)

| Field | Required | Meaning |
|---|---|---|
| `voice[audio]` | yes | The take's blob (`event.detail.blob`). At most **10 MB** (`MAX_BYTES`). |
| `voice[duration_ms]` | yes | `event.detail.durationMs`, 1 to **120000** (`MAX_DURATION_MS`). |
| `voice[mime_type]` | no | `event.detail.mimeType` (e.g. `audio/webm;codecs=opus`); else the part's own `Content-Type`. One of `audio/webm`, `video/webm`, `audio/ogg`, `audio/mp4`, `audio/m4a`, `audio/x-m4a`, `audio/mpeg`, `audio/wav`, `audio/x-wav`. |
| `voice[embedding]` | no | The take's speaker vector, a JSON array (the embedder's size, 256). |
| `voice[model]` | no | The embedder id that made it (`Studio::VoiceMatch.model_id(Studio.voice_embedder)`). |

```js
recorder.addEventListener("studio:voice-recorder:take", async ({ detail }) => {
  const form = new FormData()
  form.append("voice[audio]", detail.blob, "take")
  form.append("voice[mime_type]", detail.mimeType)
  form.append("voice[duration_ms]", Math.round(detail.durationMs))
  // optional, when the page embedded the take (studio/voice_profile's embedder):
  // form.append("voice[embedding]", JSON.stringify(vector)); form.append("voice[model]", modelId)
  const response = await fetch("/voice/takes", {
    method: "POST", body: form,
    headers: { "X-CSRF-Token": csrfToken, Accept: "application/json" }
  })
  const answer = await response.json()   // check response.ok: fetch does not reject on a 4xx/5xx
})
```

### Answers

| Status | Body | When |
|---|---|---|
| `200` | `{text, speaker, score, identified, check, duration_ms}` | heard |
| `401` | `{error: "unauthenticated"}` | signed out |
| `413` | `{error}` | over 10 MB |
| `415` | `{error}` | a type a take cannot be |
| `422` | `{error}` | no audio (including a `voice` param that is a string or a list), empty audio, no or too long a duration |
| `422` | `{error, reason: "no_speech"}` | the transcript is what a model writes for silence ("Thank you for watching", a lone "um", empty, or no Latin letters when told English) |
| `503` | `{error, reason: "not_configured"}` | no key, or an unknown transcriber name. `error` is `NOT_CONFIGURED_MESSAGE`: "Voice isn't set up on this app yet, so I can't hear recordings. Type instead for now." The cause is an `ErrorLog` row. |
| `429` | `{error, reason: "rate_limited", retry_after}` | over the per-user limit; `retry_after` is seconds until the window ends, also sent as `Retry-After`. Nothing was transcribed. |
| `503` | `{error, reason: "transcriber_failed", retry: true}` | the vendor failed (on both models where a retry applies), refused the key, throttled the account, could not be reached, or ran past the deadline. The cause is an `ErrorLog` row on the user. |

`error` is always a line the page can show as is.

### The 200 body

| Key | Meaning |
|---|---|
| `text` | The transcript, stripped. |
| `speaker` | The signed-in user's display name when the take is their voice; else **"Someone new"**. |
| `score` | The cosine with the user's saved voice, 4 places; `null` when nothing was compared. |
| `identified` | `true` only when `check` is `matched`. |
| `check` | `matched` (at or above `Studio::VoiceMatch::THRESHOLD`, 0.6), `below_threshold` (compared, fell short; `score` says by how much), `no_profile` (the user has no saved voice), `embedder_mismatch` (the take's model, the app's embedder and the saved voice's model are not all the same revision, so nothing was compared), `no_embedding` (the take carried no usable vector). |
| `duration_ms` | The take's length, echoed for the chat's `metadata.voice`. |

Only the signed-in user's own voice is ever compared: another account's voice is
`below_threshold`, never their name.

## The library call

The endpoint is a thin shell over one call, which a host may use directly:

```ruby
heard = Studio::VoiceTranscription.hear(
  audio: io_or_string, mime_type: "audio/webm;codecs=opus", user: current_user,
  embedding: vector_or_json, model: model_id            # both optional
)
heard.text / heard.speaker / heard.score / heard.check / heard.identified?
heard.to_h  # => {"text"=>..., "speaker"=>..., "score"=>..., "identified"=>..., "check"=>...}
Studio::VoiceTranscription.no_speech_reason(heard.text)  # => nil, or why it is not speech
```

It raises `Studio::VoiceTranscription::NotConfigured` (no key, unknown
transcriber), `HttpError` (`#status`, 0 when nothing answered; `#reason`, one of
`unauthorized`, `rate_limited`, `server_error`, `rejected`, `timeout`,
`unreachable`) and `ArgumentError` (a type a take cannot be). All three are
`StandardError`. An `HttpError`'s message is the model, the status and the
reason, never the vendor's words.

## Transcribers

| Name | What | Default where |
|---|---|---|
| `openai` | OpenAI `POST /v1/audio/transcriptions`, multipart, one file. `gpt-4o-transcribe`, retried once on `whisper-1` when the first model fell over (a 5xx, or a 4xx other than 401, 403 and 429) and at least 2 s of the deadline are left (`Studio.voice_transcribe_model`, `Studio.voice_transcribe_fallback_model`; blank the fallback to turn the retry off). Never retried after a timeout, a 429, an auth failure, or no answer at all. Both are told `Studio.voice_transcribe_language` (`"en"`): left to guess, a model handed near-silence answers a stock word in any language. **One deadline for the whole take**, `Studio.voice_transcribe_deadline` (25 s), shared by both attempts: every socket timeout is what is left of it (connecting at most 10 s), and a hard timeout backs it, so a take never holds a web thread past it. | production |
| `mock` | No network. Answers `Mock::DEFAULT_TEXT`; `Mock.reply = ->(filename:, content_type:, bytes:) { "..." }` swaps it, `Mock.calls` records sizes (never bytes), `Mock.reset!` clears both. | everywhere else |

The name comes from `Studio.voice_transcriber`, else `STUDIO_VOICE_TRANSCRIBER`,
else `openai` in production and `mock` elsewhere. A desk that wants real
transcripts sets `STUDIO_VOICE_TRANSCRIBER=openai` and its own key.

### The no-live-calls trap

The OpenAI adapter calls `guard_live_call!` before it opens a socket. It raises
`Studio::VoiceTranscription::LiveCallAttempted`, deliberately **outside
StandardError** so no rescue swallows it, while **`VOICE_NO_LIVE_CALLS=1`**, and
in **any Rails test environment** unless `VOICE_NO_LIVE_CALLS=0`. So a host's
suite is protected without setting anything. A call to this machine
(`127.0.0.1`, `localhost`, `::1`; the check reads `URI#hostname`, so an IPv6
literal arrives unbracketed) is not live: the engine's own tests drive the real
adapter against a stub server there.

## Config

| Setting | Default | Meaning |
|---|---|---|
| `Studio.voice_transcription` | `false` | Draws `POST /voice/takes`. |
| `Studio.voice_transcriber` | `nil` | `"openai"` or `"mock"`; `nil` as above. |
| `Studio.voice_openai_api_key` | `nil` | The key; `nil` reads `STUDIO_VOICE_OPENAI_API_KEY`, never `OPENAI_API_KEY`. |
| `Studio.voice_transcribe_deadline` | `25` | Seconds for the whole take at the vendor, both attempts together. |
| `Studio.voice_takes_rate_limit` | `{ to: 20, within: 600 }` | Takes per user per window (seconds); `store:` optional; `false` turns it off. |
| `Studio.voice_transcribe_model` | `"gpt-4o-transcribe"` | First model. |
| `Studio.voice_transcribe_fallback_model` | `"whisper-1"` | The one retry; blank turns it off. |
| `Studio.voice_transcribe_language` | `"en"` | ISO-639-1; blank lets the model guess. |
| `Studio.voice_embedder` | `"wespeaker"` | Shared with the profile: the embedder a take must come from to be compared. |

## Limits a host should know

- The size cap is checked after Rack has parsed the upload; an app that wants
  to refuse a huge body earlier caps it at the web server.
- Each take is one vendor call (two on a retry), at most 20 per user per 10
  minutes by default. Spend is the vendor's to alert on: set a monthly budget
  and alert on the voice key's OpenAI project.
- The rate limit's window is per process when the app's cache is a `NullStore`
  (development); on a real shared cache it is per user across dynos.

## Tests

- `test/lib/studio/voice_transcription_test.rb` (unit): adapter selection, the
  key (never `OPENAI_API_KEY`), the mock, the trap (IPv6 loopback included), the
  OpenAI request against a stub server on `127.0.0.1` (multipart body, model,
  language, bearer), the retry and its exceptions, the one deadline against a
  stub that sleeps (cut, shared by both attempts, never retried), a vendor 429
  not retried, reason codes and no vendor words in a message, a missing key, an
  unreachable vendor, the no-speech rule, and who spoke (matched, below
  threshold, embedder mismatch, no profile, no embedding).
- `test/integration/voice_takes_requests_test.rb`: the endpoint through the
  dummy app with the mock: the answer, Someone new, only the signed-in user is
  compared, nothing stored or logged, signed out, CSRF, the caps, no speech,
  the 503 without a key (the shared key does not count), the `ErrorLog` row on
  the user, the per-user 429 (on a `NullStore` too), and a string `voice` 422.
