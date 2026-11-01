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

**Nothing.** The upload is read once, handed to the transcriber, and its
tempfile is deleted before the answer. No row is written. `voice[audio]` and
`voice[embedding]` are in the engine's parameter filter (beside the profile's
`voice[embeddings]`), so neither reaches a request log. The vendor's error words
can reach `ErrorLog`; the audio and the vector never do.

## Turn it on in an app

1. Install the voice profile migration if the app has not
   ([`VOICE_PROFILE.md`](VOICE_PROFILE.md), step 1); without the columns every
   take answers `check: "no_profile"` and still transcribes.
2. In `config/initializers/studio.rb`:

   ```ruby
   Studio.configure do |config|
     config.voice_transcription = true            # draws POST /voice/takes
     # config.voice_transcriber = "openai"        # default: openai in production, mock elsewhere
     # config.voice_openai_api_key = ...          # default: ENV["OPENAI_API_KEY"]
   end
   ```

3. Set the app's own **`OPENAI_API_KEY`** in its Heroku config (or
   `Studio.voice_openai_api_key`). Each app holds its own key; never copy
   another app's. Without one the endpoint answers the 503 below, and nothing
   crashes.

## The endpoint: `POST /voice/takes`

Drawn by `Studio.routes` only when `Studio.voice_transcription` is on (every
take is a paid vendor call). Route name `studio_voice_takes`.

- **Signed in only**: the host's `require_authentication` (a JSON `401` when
  signed out).
- **CSRF-protected**: send the page's token as `X-CSRF-Token`.
- **JSON answers**, `Cache-Control: no-store`.

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
| `422` | `{error}` | no audio, empty audio, no or too long a duration |
| `422` | `{error, reason: "no_speech"}` | the transcript is what a model writes for silence ("Thank you for watching", a lone "um", empty, or no Latin letters when told English) |
| `503` | `{error, reason: "not_configured"}` | no key, or an unknown transcriber name. `error` is `NOT_CONFIGURED_MESSAGE`: "Voice isn't set up on this app yet, so I can't hear recordings. Type instead for now." The cause is an `ErrorLog` row. |
| `503` | `{error, reason: "transcriber_failed", retry: true}` | the vendor failed on both models, refused the key, or could not be reached. The cause is an `ErrorLog` row. |

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
transcriber), `HttpError` (`#status`; 0 when the vendor could not be reached)
and `ArgumentError` (a type a take cannot be). All three are `StandardError`.

## Transcribers

| Name | What | Default where |
|---|---|---|
| `openai` | OpenAI `POST /v1/audio/transcriptions`, multipart, one file. `gpt-4o-transcribe`, retried once on `whisper-1` for any failure but a 401 or 403 (`Studio.voice_transcribe_model`, `Studio.voice_transcribe_fallback_model`; blank the fallback to turn the retry off). Both are told `Studio.voice_transcribe_language` (`"en"`): left to guess, a model handed near-silence answers a stock word in any language. Timeouts 10 s to connect, 120 s to read. | production |
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
(`127.0.0.1`, `localhost`) is not live: the engine's own tests drive the real
adapter against a stub server there.

## Config

| Setting | Default | Meaning |
|---|---|---|
| `Studio.voice_transcription` | `false` | Draws `POST /voice/takes`. |
| `Studio.voice_transcriber` | `nil` | `"openai"` or `"mock"`; `nil` as above. |
| `Studio.voice_openai_api_key` | `nil` | The key; `nil` reads `OPENAI_API_KEY`. |
| `Studio.voice_transcribe_model` | `"gpt-4o-transcribe"` | First model. |
| `Studio.voice_transcribe_fallback_model` | `"whisper-1"` | The one retry; blank turns it off. |
| `Studio.voice_transcribe_language` | `"en"` | ISO-639-1; blank lets the model guess. |
| `Studio.voice_embedder` | `"wespeaker"` | Shared with the profile: the embedder a take must come from to be compared. |

## Limits a host should know

- The size cap is checked after Rack has parsed the upload; an app that wants
  to refuse a huge body earlier caps it at the web server.
- There is no per-user rate limit in the engine yet. Each take is one vendor
  call (two on a retry); the pilot should watch spend.

## Tests

- `test/lib/studio/voice_transcription_test.rb` (unit): adapter selection, the
  key, the mock, the trap, the OpenAI request against a stub server on
  `127.0.0.1` (multipart body, model, language, bearer), the retry and its
  exceptions, a missing key, an unreachable vendor, the no-speech rule, and who
  spoke (matched, below threshold, embedder mismatch, no profile, no embedding).
- `test/integration/voice_takes_requests_test.rb`: the endpoint through the
  dummy app with the mock: the answer, Someone new, only the signed-in user is
  compared, nothing stored or logged, signed out, CSRF, the caps, no speech,
  and the 503 without a key.
