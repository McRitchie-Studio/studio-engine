// [unit] studio/cropper: the crop a modal entry asks for, what Cropper.js is
// constructed and exported with, how a picked file is routed, the confirm
// event's detail, the wait for the library, and the crop-photo modal's scope.
// Loaded from source as a data: module, like toast.test.mjs; the module
// imports nothing, which is what lets the head load it by its own tag.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/cropper.js", import.meta.url), "utf8")
const {
  CROP_DEFAULTS, NOT_AN_IMAGE, GIF_REFUSED, CROPPER_MISSING, LIBRARY_WAIT_MS, LIBRARY_POLL_MS,
  cropSettings, cropperOptions, canvasOptions, isAnimatedCandidate, fileRoute, confirmedDetail,
  whenCropperLoads, cropPhotoModal
} = await import(`data:text/javascript,${encodeURIComponent(source)}`)

test("the module imports nothing, so the head can load it by its own tag", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

// ---- the crop ---------------------------------------------------------------

test("an opener that names nothing gets a square 256px avatar on a transparent ground", () => {
  assert.deepEqual(cropSettings(undefined), CROP_DEFAULTS)
  assert.equal(CROP_DEFAULTS.aspectRatio, 1)
  assert.equal(CROP_DEFAULTS.maxWidth, 256)
  assert.equal(CROP_DEFAULTS.transparent, true)
  assert.equal(CROP_DEFAULTS.allowGifs, false)
})

test("the ratio an opener asks for is the ratio the crop box holds", () => {
  const banner = cropSettings({ aspectRatio: 5, maxWidth: 2000, maxHeight: 400, autoCropArea: 1 })
  assert.equal(banner.aspectRatio, 5)
  assert.equal(cropperOptions(banner).aspectRatio, 5)
  assert.equal(cropperOptions(banner).autoCropArea, 1)

  const card = cropSettings({ aspectRatio: 1200 / 630, maxWidth: 1200 })
  assert.equal(cropperOptions(card).aspectRatio, 1200 / 630)
  assert.equal(cropperOptions(cropSettings({})).aspectRatio, 1)
})

test("a boolean prop is read as given and anything else keeps the default", () => {
  assert.equal(cropSettings({ transparent: false }).transparent, false)
  assert.equal(cropSettings({ transparent: "no" }).transparent, true)
  assert.equal(cropSettings({ allowGifs: true }).allowGifs, true)
  assert.equal(cropSettings({ allowGifs: 1 }).allowGifs, false)
  assert.equal(cropSettings({ dispatch: true }).dispatch, true)
  assert.equal(cropSettings({ owner: "iuh-3" }).owner, "iuh-3")
  assert.equal(cropSettings({}).owner, null)
})

test("the export caps the width alone and never passes a height", () => {
  const options = canvasOptions(cropSettings({ aspectRatio: 5, maxWidth: 2000, maxHeight: 400 }))
  assert.deepEqual(options, { maxWidth: 2000, imageSmoothingQuality: "high" })
  assert.equal("maxHeight" in options, false)
})

test("an opaque crop is filled white; a transparent one names no fill", () => {
  assert.equal(canvasOptions(cropSettings({ transparent: false })).fillColor, "#ffffff")
  assert.equal("fillColor" in canvasOptions(cropSettings({})), false)
})

// ---- a picked file ----------------------------------------------------------

test("a GIF is told apart by type, whatever its name says", () => {
  assert.equal(isAnimatedCandidate({ type: "image/gif", name: "a.png" }), true)
  assert.equal(isAnimatedCandidate({ type: "IMAGE/GIF", name: "A.GIF" }), true)
  assert.equal(isAnimatedCandidate({ type: "image/png", name: "renamed.gif" }), false)
  assert.equal(isAnimatedCandidate(null), false)
})

test("an image is cropped, a file that is no image is refused", () => {
  assert.deepEqual(fileRoute({ type: "image/png" }, cropSettings({})), { route: "crop" })
  assert.deepEqual(fileRoute({ type: "application/pdf" }, cropSettings({})), { error: NOT_AN_IMAGE })
  assert.deepEqual(fileRoute({ type: "" }, cropSettings({})), { error: NOT_AN_IMAGE })
})

test("a GIF passes through uncropped where allowed and is refused where not", () => {
  assert.deepEqual(fileRoute({ type: "image/gif" }, cropSettings({ allowGifs: true })), { route: "pass" })
  assert.deepEqual(fileRoute({ type: "image/gif" }, cropSettings({})), { error: GIF_REFUSED })
})

test("a confirm carries its owner; a passed-through file also carries its name", () => {
  assert.deepEqual(confirmedDetail("blob", "iuh-2"), { blob: "blob", owner: "iuh-2" })
  assert.deepEqual(confirmedDetail("blob", undefined), { blob: "blob", owner: null })
  const file = { name: "party.gif", type: "image/gif" }
  assert.deepEqual(confirmedDetail(file, "iuh-2", file),
    { blob: file, owner: "iuh-2", filename: "party.gif", uncropped: true })
})

// ---- the library ------------------------------------------------------------

// A window whose clock the test turns by hand.
const clockWindow = (extra = {}) => {
  let now = 0
  let timers = []
  const win = {
    setTimeout(fn, ms) { timers.push({ fn, at: now + (ms || 0) }); return timers.length },
    advance(ms) {
      const until = now + ms
      for (;;) {
        const due = timers.filter((t) => t.at <= until).sort((a, b) => a.at - b.at)[0]
        if (!due) break
        timers = timers.filter((t) => t !== due)
        now = due.at
        due.fn()
      }
      now = until
    },
    pending: () => timers.length,
    ...extra
  }
  return win
}

test("a page that has Cropper.js mounts at once", () => {
  const Cropper = function () {}
  const win = clockWindow({ Cropper })
  const seen = []
  whenCropperLoads(win, (library) => seen.push(library), () => seen.push("missing"))
  assert.deepEqual(seen, [Cropper])
  assert.equal(win.pending(), 0)
})

test("a library that lands late is still mounted", () => {
  const win = clockWindow()
  const seen = []
  whenCropperLoads(win, (library) => seen.push(library), () => seen.push("missing"))
  win.advance(LIBRARY_POLL_MS * 3)
  assert.deepEqual(seen, [])
  win.Cropper = function () {}
  win.advance(LIBRARY_POLL_MS)
  assert.deepEqual(seen, [win.Cropper])
})

test("a library that never lands is reported missing, once", () => {
  const win = clockWindow()
  const seen = []
  whenCropperLoads(win, () => seen.push("ready"), () => seen.push("missing"))
  win.advance(LIBRARY_WAIT_MS - LIBRARY_POLL_MS)
  assert.deepEqual(seen, [])
  win.advance(LIBRARY_POLL_MS * 5)
  assert.deepEqual(seen, ["missing"])
  assert.equal(win.pending(), 0)
})

test("a stopped wait calls neither", () => {
  const win = clockWindow()
  const seen = []
  const stop = whenCropperLoads(win, () => seen.push("ready"), () => seen.push("missing"))
  stop()
  win.Cropper = function () {}
  win.advance(LIBRARY_WAIT_MS * 2)
  assert.deepEqual(seen, [])
})

// ---- the modal's scope ------------------------------------------------------

// The scope as Alpine hands it to its methods: the factory's object plus the
// magics it reads. $nextTick runs at once; the store is a one-entry stack.
const mountScope = ({ props = {}, store = "modals", win } = {}) => {
  const entry = { id: "crop-photo", props }
  const modalStore = { closed: 0, current: () => entry, close() { this.closed += 1 } }
  const scope = cropPhotoModal({ store }, { win })
  scope.$store = { [store]: modalStore }
  scope.$refs = { cropImage: { tag: "img" } }
  scope.$nextTick = (fn) => fn()
  return { scope, entry, modalStore }
}

// A Cropper.js that records how it was built and what it was asked to export.
const fakeCropperWindow = () => {
  const built = []
  const events = []
  class Cropper {
    constructor(image, options) { this.image = image; this.options = options; this.destroyed = false; built.push(this) }
    destroy() { this.destroyed = true }
    getCroppedCanvas(options) {
      this.exported = options
      return { toBlob: (done, type) => done({ png: true, type }) }
    }
  }
  const win = clockWindow({
    Cropper,
    CustomEvent: class { constructor(name, init) { this.type = name; this.detail = init.detail } },
    dispatchEvent(event) { events.push(event) }
  })
  return { win, built, events }
}

test("the scope names the store it is mounted in", () => {
  assert.equal(cropPhotoModal({}, { win: {} })._storeName, "modals")
  assert.equal(cropPhotoModal({ store: "dsModals" }, { win: {} })._storeName, "dsModals")
})

test("an entry with an image goes straight to the cropper, at the asked ratio, and locks the modal", () => {
  const { win, built } = fakeCropperWindow()
  const { scope, entry } = mountScope({ win, props: { imageUrl: "data:image/png;base64,AA", aspectRatio: 3, maxWidth: 900 } })
  scope.init()

  assert.equal(scope.fromParent, true)
  assert.equal(scope.imageUrl, "data:image/png;base64,AA")
  assert.equal(built.length, 1)
  assert.equal(built[0].image, scope.$refs.cropImage)
  assert.equal(built[0].options.aspectRatio, 3)
  assert.equal(entry.props.dismissible, false)
  assert.equal(entry.props.cropReady, true)
})

test("an entry with no image is the picker: nothing mounts and the modal stays dismissible", () => {
  const { win, built } = fakeCropperWindow()
  const { scope, entry } = mountScope({ win })
  scope.init()
  assert.equal(scope.imageUrl, null)
  assert.equal(built.length, 0)
  assert.equal("dismissible" in entry.props, false)
})

test("confirm exports a PNG at the capped width, announces it with the owner and closes", () => {
  const { win, built, events } = fakeCropperWindow()
  const { scope, modalStore } = mountScope({ win, props: { imageUrl: "x", maxWidth: 900, transparent: false, owner: "iuh-7" } })
  scope.init()
  scope.confirm()

  assert.deepEqual(built[0].exported, { maxWidth: 900, imageSmoothingQuality: "high", fillColor: "#ffffff" })
  assert.equal(events.length, 1)
  assert.equal(events[0].type, "crop-photo-confirmed")
  assert.deepEqual(events[0].detail, { blob: { png: true, type: "image/png" }, owner: "iuh-7" })
  assert.equal(built[0].destroyed, true)
  assert.equal(scope.cropper, null)
  assert.equal(modalStore.closed, 1)
})

test("in dispatch mode confirm leaves the modal for the opener's saving card", () => {
  const { win, events } = fakeCropperWindow()
  const { scope, modalStore } = mountScope({ win, props: { imageUrl: "x", dispatch: true } })
  scope.init()
  scope.confirm()
  assert.equal(events.length, 1)
  assert.equal(modalStore.closed, 0)
})

test("confirm with no cropper does nothing", () => {
  const { win, events } = fakeCropperWindow()
  const { scope, modalStore } = mountScope({ win })
  scope.init()
  scope.confirm()
  assert.equal(events.length, 0)
  assert.equal(modalStore.closed, 0)
})

test("cancel releases the cropper and closes", () => {
  const { win, built } = fakeCropperWindow()
  const { scope, modalStore } = mountScope({ win, props: { imageUrl: "x" } })
  scope.init()
  scope.cancel()
  assert.equal(built[0].destroyed, true)
  assert.equal(modalStore.closed, 1)
})

test("a page where Cropper.js never arrives says so, and takes no dead press", () => {
  const win = clockWindow()
  const { scope, entry } = mountScope({ win, props: { imageUrl: "x" } })
  scope.init()
  assert.equal(scope.error, null)
  win.advance(LIBRARY_WAIT_MS)
  assert.equal(scope.error, CROPPER_MISSING)
  assert.equal(scope.cropper, null)
  assert.notEqual(entry.props.dismissible, false, "a modal with no cropper is not locked open")
})

test("a card that closes while it waits for the library stops waiting", () => {
  const win = clockWindow()
  const { scope } = mountScope({ win, props: { imageUrl: "x" } })
  scope.init()
  scope.destroy()
  win.advance(LIBRARY_WAIT_MS * 2)
  assert.equal(scope.error, null)
})

test("a refused file sets the error line and reads nothing", () => {
  const { win } = fakeCropperWindow()
  win.FileReader = class { constructor() { throw new Error("a refused file is never read") } }
  const { scope } = mountScope({ win })
  scope.init()
  scope.readFile({ type: "text/plain", name: "notes.txt" })
  assert.equal(scope.error, NOT_AN_IMAGE)
  scope.readFile({ type: "image/gif", name: "party.gif" })
  assert.equal(scope.error, GIF_REFUSED)
})

test("a picked image is read, shown and mounted", () => {
  const { win, built } = fakeCropperWindow()
  win.FileReader = class {
    readAsDataURL(file) { this.onload({ target: { result: `data:${file.type};base64,QQ` } }) }
  }
  const { scope } = mountScope({ win })
  scope.init()
  scope.error = "stale"
  scope.onFilePicked({ target: { files: [{ type: "image/jpeg", name: "me.jpg" }], value: "C:\\me.jpg" } })
  assert.equal(scope.error, null)
  assert.equal(scope.imageUrl, "data:image/jpeg;base64,QQ")
  assert.equal(built.length, 1)
})

test("an allowed GIF is announced as its original file, uncropped, with no canvas in the path", () => {
  const { win, built, events } = fakeCropperWindow()
  const { scope, modalStore } = mountScope({ win, props: { allowGifs: true, owner: "iuh-1", dispatch: true } })
  scope.init()
  const gif = { type: "image/gif", name: "party.gif" }
  scope.onDrop({ dataTransfer: { files: [gif] } })

  assert.equal(scope.dragging, false)
  assert.equal(built.length, 0)
  assert.deepEqual(events[0].detail, { blob: gif, owner: "iuh-1", filename: "party.gif", uncropped: true })
  assert.equal(modalStore.closed, 0)
})
