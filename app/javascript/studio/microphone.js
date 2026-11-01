// studio/microphone: which microphone a page records from. The one the person
// picked on the microphone chip (studio/microphone_chip), remembered on this
// device, or the system default when they never picked one or the picked one
// is gone. Ported from Voicebox's microphone.js (docs/VOICE_CAPTURE.md).
//
// Every recorder opens the microphone through openMicrophone, so the recorder
// and the chip never disagree about the device. The recorder then tells the
// chip what it opened, how loud the take is, and when it let go, with EVENTS on
// window; the chip only listens.
//
// Why it exists: Chrome's site setting can pick a microphone that is switched
// off (a wireless headset) instead of the system's own, and every take then
// records silence with nothing on the page saying which microphone was used.
//
// It imports nothing, so test/javascript/microphone.test.mjs loads it as a
// data: module.

// Where the pick is remembered (localStorage). One key for every engine page
// on an origin, so the chip on the hub's chat and on /profile agree. A host
// that wants its own key calls configureMicrophone({ storageKey }) or renders
// the chip with storage_key: (studio/voice/_microphone_chip).
export const STORAGE_KEY = "studio.microphone"

let currentKey = STORAGE_KEY

export function configureMicrophone({ storageKey } = {}) {
  currentKey = storageKey ? String(storageKey) : STORAGE_KEY
  return currentKey
}

export function storageKey() { return currentKey }

export const EVENTS = {
  opened: "studio:microphone:opened", // detail: { label, deviceId, fellBack }
  level: "studio:microphone:level", // detail: { rms }
  closed: "studio:microphone:closed",
  denied: "studio:microphone:denied",
  chosen: "studio:microphone:chosen", // detail: { deviceId }
  silent: "studio:microphone:silent" // detail: { label }: a take came back silent
}

// Which help to show: Chrome's (and Chromium Edge's, Opera's) site-settings
// steps, or one generic line for Safari and Firefox. Only desktop and Android
// Chromium carry "Chrome/" (or Edge's "Edg/"); Chrome and Edge on iOS say
// "CriOS/" and "EdgiOS/", WebKit underneath with no site-settings icon by the
// address, so they get the generic line too.
export function browserFamily(userAgent) {
  return /(Chrome|Chromium|Edg)\//.test(String(userAgent || "")) ? "chrome" : "other"
}

// Chrome's two stand-ins for "whatever the system picks". They repeat a real
// device under another id, so the picker leaves them out when real ones exist.
const PSEUDO_IDS = ["default", "communications"]

// "Arctis Nova Pro Wireless (1038:12e0)" -> "Arctis Nova Pro Wireless", and
// Chrome's "Default - MacBook Pro Microphone (Built-in)" ->
// "MacBook Pro Microphone". The USB vendor:product pair and the "(Built-in)"
// tag mean nothing to a person.
export function trimLabel(label) {
  return String(label || "")
    .replace(/^(Default|Communications)\s+-\s+/i, "")
    .replace(/\s*\([0-9a-f]{4}:[0-9a-f]{4}\)/gi, "")
    .replace(/\s*\(Built-in\)/gi, "")
    .replace(/\s+/g, " ")
    .trim()
}

export function audioInputs(devices) {
  return Array.from(devices || []).filter((device) => device && device.kind === "audioinput")
}

// Before the person allows the microphone the browser lists inputs with empty
// labels (and often empty ids): there is nothing to show yet.
export function permissionGranted(inputs) {
  return (inputs || []).some((device) => !!device.label)
}

// The devices worth offering in the picker: real ones, named, once each.
export function pickerChoices(inputs) {
  const named = (inputs || []).filter((device) => device.label && device.deviceId)
  const real = named.filter((device) => !PSEUDO_IDS.includes(device.deviceId))
  const seen = new Set()
  return (real.length ? real : named).flatMap((device) => {
    if (seen.has(device.deviceId)) return []
    seen.add(device.deviceId)
    return [{ deviceId: device.deviceId, label: trimLabel(device.label) }]
  })
}

// The remembered device, if it is still plugged in; null means "let the
// browser pick". Before permission the ids are blank and nothing can be
// checked, so the remembered one is tried and openMicrophone falls back if the
// browser says it is gone.
export function chooseDeviceId(inputs, rememberedId) {
  if (!rememberedId) return null
  if (inputs.some((device) => device.deviceId === rememberedId)) return rememberedId
  if (inputs.every((device) => !device.deviceId)) return rememberedId
  return null
}

// The system default, as a device to ask for by id. Chrome lists it as the
// "default" entry, and a bare { audio: true } does NOT open it: Chrome opens
// its per-site preference instead, which can be a headset switched off in a
// drawer. So with nothing picked the page asks for the system default by id,
// and the chip, which names the system default, names what is opened. The
// real twin's id when there is one (the track then reports that id), else
// "default" itself; null where the browser lists no "default" (Safari,
// Firefox), and there the browser's own choice stands and the opened track
// corrects the chip.
export function systemDefaultId(inputs) {
  const entry = inputs.find((device) => device.deviceId === "default" && device.label)
  if (!entry) return null
  const name = trimLabel(entry.label)
  const twin = inputs.find((device) => device.deviceId && !PSEUDO_IDS.includes(device.deviceId) &&
                                       trimLabel(device.label) === name)
  return twin ? twin.deviceId : "default"
}

export function audioConstraints(deviceId) {
  return deviceId ? { audio: { deviceId: { exact: deviceId } } } : { audio: true }
}

// The errors getUserMedia gives when an exact device is not there.
export function isMissingDevice(error) {
  return !!error && ["OverconstrainedError", "NotFoundError"].includes(error.name)
}

// What the chip names before a take has opened anything: the picked device,
// else the system default's name, else the first input. After a take, the
// track's own label wins (activeLabel), because that is the device that was
// actually recorded from.
export function displayedLabel(inputs, rememberedId, activeLabel) {
  if (activeLabel) return trimLabel(activeLabel)
  if (!permissionGranted(inputs)) return null
  const remembered = rememberedId && inputs.find((device) => device.deviceId === rememberedId && device.label)
  if (remembered) return trimLabel(remembered.label)
  const fallback = inputs.find((device) => device.deviceId === "default" && device.label) ||
                   inputs.find((device) => device.label)
  return fallback ? trimLabel(fallback.label) : null
}

// ---- Remembering the choice (localStorage can throw: private mode, blocked
// site data), so every touch is guarded and a failure means "no choice". ----

function storageOf(storage) {
  if (storage !== undefined) return storage
  try { return globalThis.localStorage || null } catch (_) { return null }
}

export function rememberedDeviceId(storage, key = currentKey) {
  try { return storageOf(storage)?.getItem(key) || null } catch (_) { return null }
}

export function rememberDevice(deviceId, storage, key = currentKey) {
  try {
    const store = storageOf(storage)
    if (!store) return
    if (deviceId) store.setItem(key, deviceId)
    else store.removeItem(key)
  } catch (_) { /* nothing remembered: the browser picks next time */ }
}

export function forgetDevice(storage, key = currentKey) { rememberDevice(null, storage, key) }

export function trackOf(stream) {
  return (stream && stream.getAudioTracks && stream.getAudioTracks()[0]) || null
}

// Opens the microphone the person picked, or the system default. A picked
// device that has gone away is forgotten and the default opened instead
// (fellBack), so a headset left in a drawer never blocks recording. Other
// errors (NotAllowedError above all) are the caller's to word.
//
// With nothing picked it asks for the system default by id (systemDefaultId),
// so Chrome's per-site preference never silently wins. Before permission the
// ids are blank and only a bare request can ask; once that grants permission,
// a stream that landed on another device is closed and the system default
// opened in its place, so even the first take records from what the chip will
// name.
export async function openMicrophone(mediaDevices = globalThis.navigator && globalThis.navigator.mediaDevices, storage) {
  const remembered = rememberedDeviceId(storage)
  const inputs = await listInputs(mediaDevices)
  const picked = chooseDeviceId(inputs, remembered)
  let fellBack = !!remembered && !picked
  if (fellBack) forgetDevice(storage)
  let deviceId = picked || systemDefaultId(inputs)

  let stream
  try {
    stream = await mediaDevices.getUserMedia(audioConstraints(deviceId))
  } catch (error) {
    if (!deviceId || !isMissingDevice(error)) throw error
    if (picked) {
      forgetDevice(storage)
      fellBack = true
    }
    deviceId = null
    stream = await mediaDevices.getUserMedia(audioConstraints(null))
  }

  if (!deviceId && !permissionGranted(inputs)) stream = await reopenSystemDefault(mediaDevices, stream)

  const track = trackOf(stream)
  const settings = settingsOf(track)
  const opened = { label: trimLabel(track && track.label), deviceId: settings.deviceId || deviceId || null, fellBack }
  announce(EVENTS.opened, opened)
  return { stream, ...opened }
}

async function listInputs(mediaDevices) {
  if (!mediaDevices || !mediaDevices.enumerateDevices) return []
  try { return audioInputs(await mediaDevices.enumerateDevices()) } catch (_) { return [] }
}

function settingsOf(track) {
  try { return (track && track.getSettings && track.getSettings()) || {} } catch (_) { return {} }
}

// After the permission prompt: is the bare request's stream the system
// default? If it landed elsewhere (Chrome's site preference), let it go and
// open the system default by id. Any doubt keeps the stream it has.
export async function reopenSystemDefault(mediaDevices, stream) {
  const inputs = await listInputs(mediaDevices)
  const wanted = systemDefaultId(inputs)
  const track = trackOf(stream)
  if (!wanted || !track) return stream
  const got = settingsOf(track).deviceId
  const wantedLabel = trimLabel((inputs.find((device) => device.deviceId === wanted) || {}).label)
  if (got === wanted || got === "default" || (wantedLabel && trimLabel(track.label) === wantedLabel)) return stream
  try {
    const replacement = await mediaDevices.getUserMedia(audioConstraints(wanted))
    stream.getTracks().forEach((t) => t.stop())
    return replacement
  } catch (_) {
    return stream
  }
}

// Tells the chip (and anything else listening on window).
export function announce(name, detail = {}, win = globalThis) {
  try { win.dispatchEvent(new CustomEvent(name, { detail })) } catch (_) { /* no listeners to tell */ }
}

// The silent-take line that names the microphone, or null when the track had
// no name to give (then the page's general line stands).
export function silentMessage(template, label) {
  const name = trimLabel(label)
  if (!template || !name) return null
  return template.replace("%{microphone}", name)
}
