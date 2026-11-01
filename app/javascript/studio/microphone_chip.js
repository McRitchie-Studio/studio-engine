// studio/microphone_chip: the microphone chip (studio/voice/_microphone_chip).
// It names the microphone the page records from and, tapped, lists the others;
// picking one remembers it on this device (studio/microphone), and the next
// take opens it. Ported from Voicebox's microphone_controller.js
// (docs/VOICE_CAPTURE.md).
//
// It listens and never opens the microphone itself: the recorder
// (studio/voice_recorder) announces what it opened (EVENTS.opened, with the
// track's own label), each frame's level while a take records (EVENTS.level,
// painted as the dot), and when it let go. It re-lists on devicechange, so a
// headset plugged in or pulled out shows up at once.
//
// The list shows every microphone with the one in use marked ("In use").
// Picking another switches on the page, by device id, and opens the help
// dialog (studio/voice/_microphone_help) with "Switched to X" on top: Chrome's
// site settings are where the microphone is ALLOWED, never how the page
// switches. The dialog also opens on a refused microphone, on the second
// silent take in a row on one microphone, and from the help link;
// data-microphone-help says which (switched, denied, silent, help) while open.
//
// On the root: data-microphone-state (prompt: not allowed yet, no names;
// ready; denied; unsupported), data-microphone-label (the name shown),
// data-microphone-live ("true" while a take records), data-microphone-heard
// (once a frame of that take cleared SILENCE_RMS), --studio-mic-level (0..1).
import {
  EVENTS, audioInputs, permissionGranted, pickerChoices, displayedLabel, configureMicrophone,
  rememberedDeviceId, rememberDevice, announce, trimLabel, browserFamily
} from "studio/microphone"
import { meterLevel, SILENCE_RMS } from "studio/level_meter"

function parseJson(text) {
  try { return JSON.parse(text || "null") } catch (_) { return null }
}

// Binds one chip. Returns { refresh, destroy }.
export function mountMicrophoneChip(root, { win = window } = {}) {
  const doc = root.ownerDocument
  const one = (selector) => root.querySelector(selector)
  const copy = parseJson(root.getAttribute("data-microphone-copy")) || {}
  const key = root.getAttribute("data-microphone-storage-key")
  if (key) configureMicrophone({ storageKey: key })
  const media = win.navigator && win.navigator.mediaDevices
  const chip = one("[data-microphone-chip]")
  const panel = one("[data-microphone-panel]")
  const dialog = one("[data-microphone-dialog]")
  const browser = browserFamily(win.navigator && win.navigator.userAgent)
  root.dataset.microphoneBrowser = browser

  let inputs = []
  let active = null
  let denied = false
  let unsupported = false
  let fellBack = false
  let silentRun = 0
  let silentLabel = null
  let lastTakeSilent = false
  let helpSession = null
  let permission = null
  let destroyed = false

  // ---- What the recorder says ----------------------------------------------

  function opened(detail) {
    // A take that was heard breaks the silent run.
    if (!lastTakeSilent) silentRun = 0
    lastTakeSilent = false
    denied = false
    active = detail.label ? detail : null
    fellBack = !!detail.fellBack
    root.dataset.microphoneLive = "true"
    root.dataset.microphoneHeard = "false"
    paintLevel(0)
    // Allowing the microphone is what gives the devices their names.
    refresh()
  }

  function closed() {
    root.dataset.microphoneLive = "false"
    paintLevel(0)
  }

  function paintLevel(rms) {
    const level = meterLevel(rms)
    root.style.setProperty("--studio-mic-level", level.toFixed(3))
    root.dataset.microphoneLevel = level.toFixed(2)
    if (rms >= SILENCE_RMS) root.dataset.microphoneHeard = "true"
  }

  // One silent take is often a pause or a quiet room: the recorder's line
  // names the microphone and that is enough. Two in a row on the same
  // microphone means it is not hearing anything, and the help opens.
  function silentTake(label) {
    lastTakeSilent = true
    const name = trimLabel(label)
    silentRun = name === silentLabel ? silentRun + 1 : 1
    silentLabel = name
    if (silentRun < 2) return
    silentRun = 0
    openHelp("silent", label)
  }

  const listeners = [
    [EVENTS.opened, (event) => opened(event.detail || {})],
    [EVENTS.level, (event) => paintLevel((event.detail || {}).rms)],
    [EVENTS.closed, () => closed()],
    [EVENTS.denied, () => { denied = true; render(); openHelp("denied") }],
    [EVENTS.silent, (event) => silentTake((event.detail || {}).label)]
  ]

  // ---- The list ------------------------------------------------------------

  // The browser's own answer, where it gives one: "denied" outlasts a reload,
  // and a person who allows it in the site settings sees the chip catch up.
  async function watchPermission() {
    try {
      if (!win.navigator.permissions || !win.navigator.permissions.query) return
      const status = await win.navigator.permissions.query({ name: "microphone" })
      if (destroyed) return
      permission = status
      const apply = () => { denied = status.state === "denied"; refresh() }
      status.onchange = apply
      if (status.state === "denied") apply()
    } catch (_) { /* Firefox before 131 cannot be asked; the takes tell us */ }
  }

  async function refresh() {
    if (!media || !media.enumerateDevices) {
      unsupported = true
      render()
      return
    }
    try {
      inputs = audioInputs(await media.enumerateDevices())
    } catch (_) {
      inputs = []
    }
    if (destroyed) return
    // The device last recorded from was unplugged: stop naming it.
    if (active && active.deviceId && permissionGranted(inputs) &&
        !inputs.some((device) => device.deviceId === active.deviceId)) {
      active = null
    }
    render()
  }

  function state() {
    if (unsupported) return "unsupported"
    if (denied) return "denied"
    return permissionGranted(inputs) || active ? "ready" : "prompt"
  }

  function fill(template, name) {
    return String(template || "").replace("%{microphone}", name)
  }

  function render() {
    const now = state()
    const words = copy[now] || {}
    const name = now === "ready" ? displayedLabel(inputs, rememberedDeviceId(), active && active.label) : null
    root.dataset.microphoneState = now
    root.dataset.microphoneLabel = name || ""
    root.dataset.microphoneFellBack = fellBack ? "true" : "false"
    const label = one("[data-microphone-label]")
    if (label) {
      label.textContent = now === "ready"
        ? (name ? fill(words.chip || "%{microphone}", name) : (copy.prompt || {}).chip || "")
        : words.chip || ""
    }
    if (chip) {
      if (name && words.aria) chip.setAttribute("aria-label", fill(words.aria, name))
      else chip.removeAttribute("aria-label")
    }
    const note = one("[data-microphone-note]")
    if (note) {
      const fell = fellBack && name && copy.fell_back ? fill(copy.fell_back, name) : null
      note.textContent = fell || words.note || ""
    }
    renderList(now, note)
  }

  // One button per microphone, the one in use marked with a check and an
  // "In use" pill, the rest plain options. Labels go in as text, never as
  // markup: a device names itself.
  function renderList(now, note) {
    const list = one("[data-microphone-list]")
    if (!list) return
    const choices = now === "ready" ? pickerChoices(inputs) : []
    const current = currentDeviceId(choices)
    list.replaceChildren(...choices.map((choice) => {
      const inUse = choice.deviceId === current
      const item = doc.createElement("li")
      const button = doc.createElement("button")
      button.type = "button"
      button.className = "studio-mic-option"
      button.dataset.microphoneOption = choice.deviceId
      button.setAttribute("aria-pressed", inUse ? "true" : "false")
      if (inUse) button.setAttribute("aria-current", "true")
      const mark = doc.createElement("span")
      mark.className = "studio-mic-check"
      mark.setAttribute("aria-hidden", "true")
      mark.textContent = inUse ? "✓" : ""
      const label = doc.createElement("span")
      label.className = "studio-mic-option-label"
      label.textContent = choice.label
      button.append(mark, label)
      if (inUse) {
        const pill = doc.createElement("span")
        pill.className = "studio-mic-in-use"
        pill.textContent = copy.in_use || "In use"
        button.append(pill)
      }
      item.append(button)
      return item
    }))
    if (now === "ready" && choices.length === 0 && note) note.textContent = copy.empty || ""
  }

  // The picked device, else the one last recorded from, else the system
  // default's twin among the real devices.
  function currentDeviceId(choices) {
    const ids = choices.map((choice) => choice.deviceId)
    const remembered = rememberedDeviceId()
    if (remembered && ids.includes(remembered)) return remembered
    if (active && ids.includes(active.deviceId)) return active.deviceId
    const name = displayedLabel(inputs, null, active && active.label)
    const twin = choices.find((choice) => choice.label === name)
    return twin ? twin.deviceId : null
  }

  function toggle() {
    if (!panel) return
    if (panel.hidden) openPanel()
    else closePanel()
  }

  function openPanel() {
    panel.hidden = false
    if (chip) chip.setAttribute("aria-expanded", "true")
    refresh()
  }

  function closePanel() {
    if (!panel) return
    panel.hidden = true
    if (chip) chip.setAttribute("aria-expanded", "false")
  }

  function pick(button) {
    const deviceId = button.dataset.microphoneOption
    if (!deviceId) return
    if (button.getAttribute("aria-current") === "true") {
      closePanel()
      if (chip) chip.focus()
      return
    }
    rememberDevice(deviceId)
    // The chip now names the pick; the next take opens it and confirms.
    active = null
    fellBack = false
    announce(EVENTS.chosen, { deviceId }, win)
    const choice = pickerChoices(inputs).find((c) => c.deviceId === deviceId)
    render()
    closePanel()
    openHelp("switched", choice ? choice.label : "", chip)
  }

  // ---- The help dialog -----------------------------------------------------

  // kind: switched, denied, silent, or help (no lead line). returnTo: where
  // focus goes when it closes, else wherever it was when it opened.
  function openHelp(kind, name = "", returnTo = null) {
    if (!dialog) return
    const help = copy.help || {}
    const chrome = browser === "chrome"
    const microphone = trimLabel(name) || help.unnamed || "the microphone"
    const lead = {
      switched: [help.switched, chrome ? help.switched_tip_chrome : help.switched_tip_other],
      silent: [help.silent, help.silent_tip],
      denied: [help.denied, help.denied_tip]
    }[kind]
    const leadBox = one("[data-microphone-help-lead]")
    if (leadBox) leadBox.hidden = !lead
    if (lead) {
      const headline = one("[data-microphone-help-headline]")
      const tip = one("[data-microphone-help-tip]")
      if (headline) headline.textContent = fill(lead[0], microphone)
      if (tip) tip.textContent = lead[1] || ""
    }
    const title = one("[data-microphone-help-title]")
    if (title) title.textContent = (chrome ? help.title_chrome : help.title_other) || ""
    const chromeSteps = one("[data-microphone-help-chrome]")
    if (chromeSteps) chromeSteps.hidden = !chrome
    const other = one("[data-microphone-help-other]")
    if (other) other.hidden = chrome
    root.dataset.microphoneHelp = kind

    if (dialog.open) return
    helpSession = { returnFocus: returnTo || doc.activeElement, done: false }
    if (typeof dialog.showModal === "function") dialog.showModal()
    else dialog.setAttribute("open", "")
    const close = one("[data-microphone-help-close]")
    if (close) close.focus()
  }

  // Esc, Close or a backdrop click: focus goes back where it came from.
  //
  // The close event is queued, so one from an earlier opening can land late:
  // while the dialog is open again (ignored), or after the newer opening has
  // closed too. Each opening is a session that hands focus back once.
  function helpClosed() {
    const session = helpSession
    if (!session || session.done || dialog.open) return
    session.done = true
    delete root.dataset.microphoneHelp
    const back = session.returnFocus
    const target = back && back.isConnected && back.offsetParent !== null ? back : chip
    if (target) target.focus()
  }

  // ---- Wiring --------------------------------------------------------------

  function onClick(event) {
    const target = event.target
    if (!target.closest) return
    // A click on the backdrop lands on the dialog element itself.
    if (dialog && target === dialog) { dialog.close(); return }
    const option = target.closest("[data-microphone-option]")
    if (option && root.contains(option)) { pick(option); return }
    if (target.closest("[data-microphone-help-link]")) {
      openHelp("help", "", target.closest("[data-microphone-help-link]"))
      return
    }
    if (chip && target.closest("[data-microphone-chip]") === chip) toggle()
  }

  // Esc closes the list, but an Esc inside the help dialog is the dialog's: it
  // shuts the dialog and leaves the list where it was.
  function onKey(event) {
    if (event.key !== "Escape") return
    if (dialog && dialog.contains(event.target)) return
    closePanel()
  }

  const onDeviceChange = () => refresh()
  const onDialogClose = () => helpClosed()

  listeners.forEach(([name, fn]) => win.addEventListener(name, fn))
  root.addEventListener("click", onClick)
  root.addEventListener("keydown", onKey)
  if (dialog) dialog.addEventListener("close", onDialogClose)
  if (media && media.addEventListener) media.addEventListener("devicechange", onDeviceChange)
  watchPermission()
  refresh()
  root.dataset.microphoneReady = "true"

  return {
    refresh,
    destroy() {
      destroyed = true
      listeners.forEach(([name, fn]) => win.removeEventListener(name, fn))
      root.removeEventListener("click", onClick)
      root.removeEventListener("keydown", onKey)
      if (dialog) dialog.removeEventListener("close", onDialogClose)
      if (media && media.removeEventListener) media.removeEventListener("devicechange", onDeviceChange)
      if (permission) permission.onchange = null
      if (dialog && dialog.open) dialog.close()
      delete root.dataset.microphoneReady
    }
  }
}
