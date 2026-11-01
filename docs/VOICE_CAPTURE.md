# Voice capture

The engine's capture layer: a **microphone chip** that names the microphone a
page records from and lets a person pick another, its **help dialog**, ONE
**level meter**, and a **record button** that hands the finished take to the
page. It uploads nothing: the page that renders it decides where the audio
goes. It is card 1 of the Studio Voice epic (one voice layer for every app and
agent); the hub's agent chat is its first consumer (card 4).

Ported from Voicebox, where it was measured: `microphone.js`,
`microphone_controller.js`, `shared/_microphone_chip`, `shared/_microphone_help`,
`MicrophoneHelper`, and the recorder and level meter that Voicebox carried twice
(`recorder_controller.js`, `voice_setup_controller.js`). The engine's own voice
row on `/profile` ([`VOICE_PROFILE.md`](VOICE_PROFILE.md)) now runs on the same
meter.

## Why the chip exists

Chrome's site setting can pick a microphone that is switched off (a wireless
headset in a drawer) instead of the system's own, and every take then records
silence with nothing on the page saying which microphone was used. So:

- With nothing picked, the recorder asks for the **system default by device id**
  (Chrome's `default` entry, or its real twin), never a bare `{ audio: true }`,
  which opens Chrome's per-site preference. Before permission only a bare request
  can ask; once it grants permission, a stream that landed elsewhere is closed and
  the system default opened in its place.
- A picked microphone is remembered on the device and opened with
  `deviceId: { exact }`. A picked one that is gone is forgotten and the default
  opened instead (`fellBack`), so it never blocks recording.
- The chip names the device a take actually opened (the track's own label), and
  its dot shows the live level, so a dead microphone is visible at a glance.
- A take whose loudest frame stays under **-40 dBFS** (`SILENCE_RMS = 0.01`) is
  refused before it goes anywhere: a speech model handed silence makes a word up.
  Two silent takes in a row on one microphone open the help.
- A microphone another app holds (`NotReadableError`, Chrome's older
  `TrackStartError`) gets its own line, "Your microphone is busy in another
  app. Close it there, then try again." (`failed.busy`, overridable with the
  recorder's `copy:`), never "I couldn't find a microphone".

## Adopt it in a page

Render the two partials. Both are lazy controllers on the engine's Stimulus
application (`studio/stimulus`), so nothing loads on a page that renders neither.

```erb
<%= render "studio/voice/microphone_chip" %>
<%= render "studio/voice/recorder", id: "chat-recorder", mode: "hold",
           copy: { "idle" => { "button" => "Hold to talk" } } %>
```

Then take the audio from the event, in the page's own module:

```js
document.getElementById("chat-recorder").addEventListener("studio:voice-recorder:take", (event) => {
  const { blob, mimeType, durationMs, peakRms, microphone } = event.detail
  // Upload it, transcribe it, embed it, or drop it: the page decides.
})
```

To turn a take into words and a speaker, post it to the engine's own
`POST /voice/takes`, which answers `{text, speaker, score}` and keeps nothing:
[`VOICE_TRANSCRIPTION.md`](VOICE_TRANSCRIPTION.md) is that contract.

The chip and the recorder find each other through `window` events, so they can
sit anywhere on the page. One chip serves any number of recorders.

A page with its own markup can skip `_recorder` and put
`data-studio-controller="voice-recorder"` on its own element with the data
attributes below; a page's own controls can call `voice-recorder#start`,
`#stop` and `#toggle` (`data-studio-action`). Render `studio/voice/styles` once
if the page uses the engine classes without either partial.

## The contract

### Partials

| Partial | Locals (all optional) |
|---|---|
| `studio/voice/microphone_chip` | `copy:` (merged over `Studio::VoiceCapture::MICROPHONE_COPY`), `storage_key:` (default `"studio.microphone"`), `id:` (the picker's id; two chips on one page need two) |
| `studio/voice/microphone_help` | Rendered by the chip; `copy:`, `title_id:` |
| `studio/voice/recorder` | `copy:` (per-state words over `COPY` in `studio/voice_recorder`), `mode:` (`"toggle"` or `"hold"`), `max_ms:` (default 60000), `id:` |
| `studio/voice/styles` | Rendered by both: the scoped CSS |

`copy:` merges one level deep per section: `{ "help" => { "close" => "Done" } }`
changes one line and keeps the rest. The words live in
`lib/studio/voice_capture.rb`.

### Controllers and modules

| Identifier | Controller | Module |
|---|---|---|
| `microphone-chip` | `studio/controllers/microphone_chip_controller` | `studio/microphone_chip` (`mountMicrophoneChip`) |
| `voice-recorder` | `studio/controllers/voice_recorder_controller` | `studio/voice_recorder` (`mountVoiceRecorder`) |
| | | `studio/microphone`: which device opens (`openMicrophone`, `systemDefaultId`, `displayedLabel`, `pickerChoices`, `trimLabel`, `browserFamily`, `configureMicrophone`) |
| | | `studio/level_meter`: the one meter (`createLevelMeter`, `SILENCE_RMS`, `meterLevel`, `takeWasHeard`, `rootMeanSquare`, `peakWindowRms`) |

Every module is pinned by the engine's importmap like any other
`studio/<name>`; a host imports `studio/microphone` or `studio/level_meter`
directly when it builds its own recorder. A recorder that opens the microphone
through `openMicrophone` and announces with `studio/microphone`'s `EVENTS` keeps
the chip in step.

### Events

On the recorder's root (they bubble):

| Event | Detail |
|---|---|
| `studio:voice-recorder:take` | `{ blob, mimeType, durationMs, peakRms, microphone: { label, deviceId } }`: a heard take |
| `studio:voice-recorder:silent` | `{ durationMs, microphone }`: a take refused as silent; no blob is handed over |
| `studio:voice-recorder:state` | `{ state }` on every change |

On `window`, from the recorder to the chip (`studio/microphone`'s `EVENTS`):
`studio:microphone:opened` (`{ label, deviceId, fellBack }`),
`studio:microphone:level` (`{ rms }`), `studio:microphone:closed`,
`studio:microphone:denied`, `studio:microphone:silent` (`{ label }`), and from
the chip, `studio:microphone:chosen` (`{ deviceId }`).

### State on the page

| Element | Attributes |
|---|---|
| Chip root | `data-microphone-state` (`prompt`, `ready`, `denied`, `unsupported`), `data-microphone-label`, `data-microphone-live`, `data-microphone-heard`, `data-microphone-help` (while the dialog is open: `switched`, `denied`, `silent`, `help`), `data-microphone-ready`, `--studio-mic-level` |
| Recorder root | `data-voice-recorder-state` (`idle`, `starting`, `recording`, `captured`, `silent`, `failed`, `denied`, `unsupported`), `data-voice-recorder-mode`, `data-voice-recorder-heard`, `data-voice-recorder-peak`, `data-voice-recorder-level`, `data-voice-recorder-ready`, `--studio-recorder-level` |

### Storage

The pick is kept in `localStorage` under **`studio.microphone`**, one key for
every engine page on an origin, so a chip on the chat and one on `/profile`
agree. A host that must keep an older key (Voicebox's `voicebox.microphone`, when
it moves onto the engine) renders the chip with `storage_key:`, or calls
`configureMicrophone({ storageKey })`; without that, a Voicebox user picks their
microphone once more after the move. A storage that throws (private mode,
blocked site data) means "no pick": the default opens.

## What a host must allow

- The page needs the microphone, so its `Permissions-Policy` must not set
  `microphone=()`.
- Nothing is fetched from another origin. The partials carry an inline `<style>`
  block, as the voice row does.

## Look and feel

Every colour is a theme token: the primary through `--color-primary-500-rgb`,
filled controls through `--color-cta-fill` / `--color-cta` under
`--btn-primary-fg`, surfaces through `--color-inset`, `--color-surface` and the
text tokens, so dark mode and each app's palette apply. Every control is at
least 44px tall, nothing scrolls sideways at 390px, and under reduced motion the
meter steps in quarters four times a second and the dot stops scaling. Labels a
device gives are inserted as text, never markup.

Keyboard and screen readers: the chip, every option and the help link wear the
same 3px primary focus ring. Esc in the open list closes it and puts focus back
on the chip. The option in use carries `aria-current="true"`; options carry no
`aria-pressed` (picking is not a toggle). The help's drawing of Chrome's address
bar shows a drawn bar, not the app's host.

## Tests

- `test/javascript/microphone.test.mjs`: the chooser (Voicebox's
  `microphone_chooser_test.rb` as the spec), the key, `openMicrophone`'s
  fallbacks.
- `test/javascript/level_meter.test.mjs`: the silence line, the scale,
  `takeWasHeard`, a meter against a stub Web Audio graph.
- `test/javascript/voice_recorder.test.mjs`: heard and silent takes, a refused
  microphone, a busy one, a recorder that will not start releasing the
  microphone, hold mode.
- `test/javascript/microphone_chip.test.mjs`: Esc returns focus to the chip;
  options carry `aria-current`, not `aria-pressed`.
- `test/views/voice_capture_render_test.rb`: the partials and their contract.
- `e2e/voice_capture.spec.js` on `/lab/voice_capture`: the chip, a switch to an
  exact device that survives a reload, a silent take refused, a heard take's
  blob, a devicechange relist, a refusal, a busy microphone, hold to talk, the
  keyboard (Esc, the 3px rings), dark and light.
