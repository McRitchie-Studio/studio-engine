# Voice profile

The voice row on `/profile`: **Set up your voice**. A signed-in person reads
three short phrases, their device turns each take into a speaker embedding, and
one averaged voice is saved on their own user record, so an agent or app can
tell who is speaking. It is off by default.

## What is stored, and what is not

- **Stored:** `users.voice_embedding` (an array of 256 floats, a unit vector),
  `users.voice_embedding_model` (which embedder and revision made it) and
  `users.voice_embedding_updated_at`.
- **Never stored or uploaded:** audio. Each take is recorded in the browser,
  embedded there (`app/javascript/studio/voice_profile.js`) and dropped. The save
  request (`POST /profile/voice`) carries only `voice[model]` and
  `voice[embeddings]`, three vectors, and the server averages them
  (`Studio::VoiceMatch.enrol`).
- **Delete** (`DELETE /profile/voice`) clears all three columns.

The row shows this consent line: "This saves a voice pattern, not a recording.
Your device listens to three short phrases and keeps only numbers that describe
how you sound, so your agent can tell it's you. Delete it any time."

## Turn it on in an app

1. Install the migration, which adds the three columns to `users`
   (`if_not_exists`; skipped on an app with no `users` table):

   ```bash
   bin/rails studio_engine:install:migrations && bin/rails db:migrate
   ```

2. Turn the row on in `config/initializers/studio.rb`:

   ```ruby
   Studio.configure do |config|
     config.voice_profile = true
     # Tests only: a fixed vector per window.studioFakeVoice instead of the model.
     config.voice_embedder = "fake" if Rails.env.test?
   end
   ```

3. Let the browser fetch the model. The page loads transformers.js from
   **jsDelivr** (`cdn.jsdelivr.net`, which also serves its onnxruntime-web
   WebAssembly) and the speaker model from **Hugging Face** (`huggingface.co`,
   which redirects the file to `*.hf.co`). Add them to the app's CSP:

   ```ruby
   policy.script_src  ..., "https://cdn.jsdelivr.net"
   policy.connect_src ..., "https://cdn.jsdelivr.net", "https://huggingface.co", "https://*.hf.co"
   ```

   `script_src` also needs `'wasm-unsafe-eval'` (or `'unsafe-eval'`) for the
   WebAssembly runtime, and the page needs the microphone, so a
   `Permissions-Policy` must not set `microphone=()`.

4. Name both hosts, and the voice pattern, on the app's privacy page.

The row renders only when `Studio.voice_profile` is on **and** the user answers
all three columns, so turning the flag on before migrating draws nothing.

## The embedder

`Studio::VoiceMatch::EMBEDDERS`:

| Name | Model | Size | Use |
|------|-------|------|-----|
| `wespeaker` (default) | `onnx-community/wespeaker-voxceleb-resnet34-LM`, int8 (`model_quantized.onnx`), revision `6a61a1833ff2583aabeba044f5c8221f00b67ceb`, via transformers.js 3.7.6 | 256 | Real voices. About 6.7 MB of model plus 4.3 MB of runtime, cached by the browser after the first setup. |
| `fake` | none | 256 | Tests. A deterministic vector per `window.studioFakeVoice`, because Chrome's fake microphone cannot play chosen audio. |

The server refuses a save whose `voice[model]` is not the id of
`Studio.voice_embedder`, so a page cannot pick its own embedder and a test vector
can never be saved where the real model runs. Changing the pinned revision
changes the id; saved voices then show "Your saved voice came from an older
model" until their owner re-records.

## Silent takes

While a take records, an `AnalyserNode` on the microphone stream drives the
level ring around the record button (`--studio-voice-level`, 0..1). A take whose
loudest frame never reaches RMS 0.01 (-40 dBFS) is refused in the browser and
the phrase stays current ("I couldn't hear that one"). The embedder checks the
decoded samples again, and the server refuses a take that embedded to zeros.

## Asking who is speaking

```ruby
model = Studio::VoiceMatch.model_id(Studio.voice_embedder)
user  = Studio::VoiceMatch.identify(embedding, among: User.all, model: model)
# => the closest user at or above Studio::VoiceMatch::THRESHOLD (0.6), else nil

result = Studio::VoiceMatch.match(embedding, among: User.all, model: model)
result.user    # as above
result.score   # the closest cosine, or nil when nobody had a comparable voice
```

`among` is any scope or enumerable of users; a scope is narrowed to the model in
SQL. Only users whose `voice_embedding_model` equals `model` are compared. The
threshold was measured in Voicebox (same voice 0.85 to 0.91, different voices
0.04 to 0.53 on synthetic speech). Nothing in the engine calls it yet; agent chat
wiring is a later change.

## Tests

- `test/lib/studio/voice_match_test.rb` (unit): the matcher, averaging and save
  validation.
- `test/integration/voice_profile_requests_test.rb`: the row's gates, the
  endpoints scoped to the signed-in user, the migration up and down.
- `test/javascript/voice_profile.test.mjs`: the meter, the silence rule, the
  fake embedder and the mounted flow against a stub browser.
- `e2e/voice_profile.spec.js`: the row at 390px with a generated microphone.
