// [unit] studio/microphone: which device a recorder opens (the remembered one
// while it is plugged in, the system default by id otherwise), the constraints
// that choice builds, the fallback when the browser says the device is gone,
// the trimmed labels, the storage key, and which help a browser gets. Ported
// from Voicebox's test/system/microphone_chooser_test.rb, which is the spec.
// Loaded from source as a data: module (it imports nothing).
import { test } from "node:test"
import assert from "node:assert/strict"
import { studioSource, loadStudioModule } from "./support/studio_module.mjs"

const m = await loadStudioModule("studio/microphone")

const memory = (seed) => {
  const map = new Map(Object.entries(seed || {}))
  return { getItem: (k) => (map.has(k) ? map.get(k) : null), setItem: (k, v) => map.set(k, String(v)), removeItem: (k) => map.delete(k), map }
}
const broken = { getItem() { throw new Error("blocked") }, setItem() { throw new Error("blocked") }, removeItem() { throw new Error("blocked") } }
const mic = (deviceId, label) => ({ kind: "audioinput", deviceId, label, groupId: "" })
const LISTED = [mic("default", "Default - MacBook Pro Microphone (Built-in)"), mic("mbp", "MacBook Pro Microphone (Built-in)"),
                mic("arctis", "Arctis Nova Pro Wireless (1038:12e0)")]
const BLANK = [mic("", ""), mic("", ""), mic("", "")]

test("the module imports nothing and its key is engine-namespaced", () => {
  assert.doesNotMatch(studioSource("studio/microphone"), /^\s*import\s/m)
  assert.equal(m.STORAGE_KEY, "studio.microphone")
  assert.ok(Object.values(m.EVENTS).every((name) => name.startsWith("studio:microphone:")))
})

test("chooseDeviceId keeps the remembered device while it is plugged in and lets go once it is gone", () => {
  assert.equal(m.chooseDeviceId(LISTED, "arctis"), "arctis")
  assert.equal(m.chooseDeviceId(LISTED, "headset-in-a-drawer"), null)
  assert.equal(m.chooseDeviceId(LISTED, null), null)
  assert.equal(m.chooseDeviceId(BLANK, "arctis"), "arctis", "before permission it is tried")
  assert.equal(m.chooseDeviceId([], "arctis"), "arctis")
})

test("audioConstraints asks for the exact device, or lets the browser pick", () => {
  assert.deepEqual(m.audioConstraints("arctis"), { audio: { deviceId: { exact: "arctis" } } })
  assert.deepEqual(m.audioConstraints(null), { audio: true })
  assert.deepEqual(m.audioConstraints(""), { audio: true })
})

test("trimLabel drops USB ids, the Built-in tag and Chrome's Default prefix", () => {
  assert.deepEqual([
    m.trimLabel("Arctis Nova Pro Wireless (1038:12e0)"),
    m.trimLabel("Default - MacBook Pro Microphone (Built-in)"),
    m.trimLabel("Communications - Jabra Evolve2 (0b0e:24c8)  "),
    m.trimLabel("Yeti Stereo Microphone (046d:0ab7) Analog"),
    m.trimLabel(""), m.trimLabel(null)
  ], ["Arctis Nova Pro Wireless", "MacBook Pro Microphone", "Jabra Evolve2", "Yeti Stereo Microphone Analog", "", ""])
})

test("the picker offers real named devices once each, and the chip names the right one", () => {
  const listed = [mic("default", "Default - MacBook Pro Microphone (Built-in)"), mic("communications", "Communications - MacBook Pro Microphone (Built-in)"),
                  mic("mbp", "MacBook Pro Microphone (Built-in)"), mic("arctis", "Arctis Nova Pro Wireless (1038:12e0)"),
                  mic("arctis", "Arctis Nova Pro Wireless (1038:12e0)"), { kind: "audiooutput", deviceId: "spk", label: "Speakers" }]
  assert.deepEqual(m.pickerChoices(m.audioInputs(listed)),
    [{ deviceId: "mbp", label: "MacBook Pro Microphone" }, { deviceId: "arctis", label: "Arctis Nova Pro Wireless" }])
  assert.deepEqual(m.pickerChoices([mic("default", "Default - Built-in")]), [{ deviceId: "default", label: "Built-in" }])
  assert.equal(m.permissionGranted(listed), true)
  assert.equal(m.permissionGranted([mic("", "")]), false)
  assert.equal(m.displayedLabel(listed, "arctis", null), "Arctis Nova Pro Wireless")
  assert.equal(m.displayedLabel(listed, "gone", null), "MacBook Pro Microphone", "the system default")
  assert.equal(m.displayedLabel(listed, "arctis", "MacBook Pro Microphone (Built-in)"), "MacBook Pro Microphone", "the track recorded from wins")
  assert.equal(m.displayedLabel([mic("", "")], "arctis", null), null)
})

test("remembering uses the engine key, survives a storage that throws, and forgets on request", () => {
  const store = memory()
  m.rememberDevice("arctis", store)
  assert.equal(m.rememberedDeviceId(store), "arctis")
  assert.deepEqual([...store.map.keys()], ["studio.microphone"])
  m.forgetDevice(store)
  assert.equal(m.rememberedDeviceId(store), null)
  m.rememberDevice("arctis", broken)
  m.forgetDevice(broken)
  assert.equal(m.rememberedDeviceId(broken), null)
  assert.equal(m.rememberedDeviceId(null), null)
})

test("configureMicrophone moves the key; a blank key restores the engine's", async () => {
  const fresh = await loadStudioModule("studio/microphone")
  const store = memory()
  assert.equal(fresh.configureMicrophone({ storageKey: "voicebox.microphone" }), "voicebox.microphone")
  fresh.rememberDevice("arctis", store)
  assert.deepEqual([...store.map.keys()], ["voicebox.microphone"])
  assert.equal(fresh.storageKey(), "voicebox.microphone")
  assert.equal(fresh.configureMicrophone({}), "studio.microphone")
  assert.equal(fresh.rememberedDeviceId(store), null, "the engine key holds nothing")
  assert.equal(fresh.rememberedDeviceId(store, "voicebox.microphone"), "arctis", "an explicit key reads its own")
})

test("systemDefaultId asks for the system default by its real twin's id, else by default, else not at all", () => {
  assert.equal(m.systemDefaultId([mic("default", "Default - MacBook Pro Microphone (Built-in)"), mic("arctis", "Arctis Nova Pro Wireless (1038:12e0)"), mic("mbp", "MacBook Pro Microphone (Built-in)")]), "mbp")
  assert.equal(m.systemDefaultId([mic("default", "Default - MacBook Pro Microphone"), mic("arctis", "Arctis Nova Pro Wireless")]), "default")
  assert.equal(m.systemDefaultId([mic("arctis", "Arctis Nova Pro Wireless"), mic("mbp", "MacBook Pro Microphone")]), null)
  assert.equal(m.systemDefaultId(BLANK), null)
})

// A browser double. site: what a bare { audio: true } opens (Chrome's per-site
// preference). grantAfter: the listing once the first open grants permission.
function devices(listed, present, site = "default", grantAfter = null) {
  const calls = []
  const stopped = []
  let current = listed
  const labels = { arctis: "Arctis Nova Pro Wireless (1038:12e0)", default: "MacBook Pro Microphone (Built-in)", mbp: "MacBook Pro Microphone (Built-in)" }
  const stream = (label, deviceId) => ({
    getAudioTracks: () => [{ label, getSettings: () => ({ deviceId }) }],
    getTracks: () => [{ stop: () => stopped.push(label) }]
  })
  return {
    calls, stopped,
    enumerateDevices: async () => current,
    getUserMedia: async (c) => {
      calls.push(c)
      if (grantAfter) current = grantAfter
      const exact = c.audio && c.audio.deviceId && c.audio.deviceId.exact
      if (exact && !present.includes(exact)) throw Object.assign(new Error("gone"), { name: "OverconstrainedError" })
      const id = exact || site
      return stream(labels[id], id)
    }
  }
}

const exact = (id) => ({ audio: { deviceId: { exact: id } } })
const browser = { audio: true }

test("openMicrophone opens the remembered device", async () => {
  const kept = memory({ "studio.microphone": "arctis" })
  const here = devices(LISTED, ["arctis", "mbp"])
  const a = await m.openMicrophone(here, kept)
  assert.deepEqual(here.calls, [exact("arctis")])
  assert.deepEqual([a.label, a.deviceId, a.fellBack, m.rememberedDeviceId(kept)], ["Arctis Nova Pro Wireless", "arctis", false, "arctis"])
})

test("openMicrophone forgets an unlisted remembered device and opens the system default by id", async () => {
  const unlisted = memory({ "studio.microphone": "drawer" })
  const here = devices(LISTED, ["arctis", "mbp"])
  const b = await m.openMicrophone(here, unlisted)
  assert.deepEqual(here.calls, [exact("mbp")])
  assert.deepEqual([b.label, b.fellBack, m.rememberedDeviceId(unlisted)], ["MacBook Pro Microphone", true, null])
})

test("openMicrophone falls back to the browser when the remembered device is missing before permission", async () => {
  const blind = memory({ "studio.microphone": "arctis" })
  const gone = devices([mic("", ""), mic("", "")], [], "default")
  const c = await m.openMicrophone(gone, blind)
  assert.deepEqual(gone.calls, [exact("arctis"), browser])
  assert.deepEqual([c.label, c.fellBack, m.rememberedDeviceId(blind)], ["MacBook Pro Microphone", true, null])
})

test("nothing picked: the system default by id, never Chrome's site preference", async () => {
  const site = devices(LISTED, ["arctis", "mbp"], "arctis")
  const d = await m.openMicrophone(site, memory())
  assert.deepEqual(site.calls, [exact("mbp")])
  assert.deepEqual([d.label, d.fellBack], ["MacBook Pro Microphone", false])
})

test("the permission open landed on the site preference: let go, open the system default", async () => {
  const prompt = devices(BLANK, ["arctis", "mbp"], "arctis", LISTED)
  const e = await m.openMicrophone(prompt, memory())
  assert.deepEqual(prompt.calls, [browser, exact("mbp")])
  assert.deepEqual([e.label, e.deviceId], ["MacBook Pro Microphone", "mbp"])
  assert.deepEqual(prompt.stopped, ["Arctis Nova Pro Wireless (1038:12e0)"])
})

test("the permission open already is the system default: one open", async () => {
  const same = devices(BLANK, ["arctis", "mbp"], "mbp", LISTED)
  const f = await m.openMicrophone(same, memory())
  assert.deepEqual(same.calls, [browser])
  assert.equal(f.label, "MacBook Pro Microphone")
  assert.deepEqual(same.stopped, [])
})

test("a refusal is the caller's to word, never a silent fallback", async () => {
  const refused = devices(LISTED, [])
  refused.getUserMedia = async () => { throw Object.assign(new Error("no"), { name: "NotAllowedError" }) }
  await assert.rejects(m.openMicrophone(refused, memory({ "studio.microphone": "arctis" })), { name: "NotAllowedError" })
})

test("openMicrophone announces what it opened on window", async () => {
  const fresh = await loadStudioModule("studio/microphone")
  const heard = []
  const saved = globalThis.dispatchEvent
  globalThis.dispatchEvent = (event) => { heard.push([event.type, event.detail]); return true }
  try {
    await fresh.openMicrophone(devices(LISTED, ["arctis", "mbp"]), memory({ "studio.microphone": "arctis" }))
  } finally {
    globalThis.dispatchEvent = saved
  }
  assert.deepEqual(heard, [["studio:microphone:opened", { label: "Arctis Nova Pro Wireless", deviceId: "arctis", fellBack: false }]])
})

test("browserFamily: Chrome and Chromium Edge get Chrome's steps; Safari, Firefox and iOS browsers the generic line", () => {
  const uas = {
    chrome: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
    edge: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0",
    headless: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/141.0.0.0 Safari/537.36",
    safari: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
    firefox: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:132.0) Gecko/20100101 Firefox/132.0",
    chromeIos: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/141.0 Mobile/15E148 Safari/604.1",
    edgeIos: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 EdgiOS/141.0 Mobile/15E148 Safari/605.1.15",
    empty: ""
  }
  assert.deepEqual(Object.fromEntries(Object.entries(uas).map(([k, ua]) => [k, m.browserFamily(ua)])), {
    chrome: "chrome", edge: "chrome", headless: "chrome", safari: "other", firefox: "other", chromeIos: "other", edgeIos: "other", empty: "other"
  })
})

test("the silent line names the microphone, or gives way to the general one", () => {
  const named = "I couldn't hear anything from %{microphone}."
  assert.equal(m.silentMessage(named, "Arctis Nova Pro Wireless (1038:12e0)"), "I couldn't hear anything from Arctis Nova Pro Wireless.")
  assert.equal(m.silentMessage(named, ""), null)
  assert.equal(m.silentMessage(null, "Arctis"), null)
})
