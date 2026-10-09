// [unit] studio/image_upload: the props a host opens the cropper with, which
// host a confirmed crop belongs to, the file it uploads, the submit behind the
// saving card, and the two host scopes. Loaded from source as a data: module,
// like cropper.test.mjs; the module imports nothing.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/image_upload.js", import.meta.url), "utf8")
const {
  SAVING_HOLD_MS, uploadCropProps, cropIsFor, uploadFileAttributes, submitToast,
  submitFormWithProgress, imageUploadHost, avatarCropperHost
} = await import(`data:text/javascript,${encodeURIComponent(source)}`)

test("the module imports nothing, so the head can load it by its own tag", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

// ---- pure helpers -----------------------------------------------------------

test("a host opens the cropper at its own ratio, in dispatch mode", () => {
  assert.deepEqual(uploadCropProps({ aspectRatio: 5, maxWidth: 2000, maxHeight: 400, autoCropArea: 1 }, { owner: "iuh-1" }), {
    aspectRatio: 5, transparent: true, dispatch: true, maxWidth: 2000, maxHeight: 400, autoCropArea: 1, owner: "iuh-1"
  })
})

test("a host that names no ratio crops square", () => {
  assert.equal(uploadCropProps({}).aspectRatio, 1)
  assert.equal(uploadCropProps(undefined).aspectRatio, 1)
  assert.equal(uploadCropProps({ aspectRatio: 1200 / 630 }).aspectRatio, 1200 / 630)
})

test("transparency is on unless the host turns it off; allowGifs passes only as a boolean", () => {
  assert.equal(uploadCropProps({}).transparent, true)
  assert.equal(uploadCropProps({ transparent: false }).transparent, false)
  assert.equal("allowGifs" in uploadCropProps({}), false)
  assert.equal(uploadCropProps({ allowGifs: true }).allowGifs, true)
  assert.equal(uploadCropProps({ allowGifs: false }).allowGifs, false)
  assert.equal("allowGifs" in uploadCropProps({ allowGifs: "yes" }), false)
})

test("a confirm belongs to the host that opened the cropper; one with no owner belongs to any", () => {
  assert.equal(cropIsFor({ blob: 1, owner: "iuh-1" }, "iuh-1"), true)
  assert.equal(cropIsFor({ blob: 1, owner: "iuh-2" }, "iuh-1"), false)
  assert.equal(cropIsFor({ blob: 1, owner: null }, "iuh-1"), true)
  assert.equal(cropIsFor({ blob: 1 }, "iuh-1"), true)
  assert.equal(cropIsFor(undefined, "iuh-1"), false)
})

test("a cropped file uploads as the host's PNG; a passed-through file keeps its own name and type", () => {
  assert.deepEqual(uploadFileAttributes({ type: "" }, undefined, { filename: "banner.png" }), { name: "banner.png", type: "image/png" })
  assert.deepEqual(uploadFileAttributes({ type: "image/png" }, undefined, {}), { name: "image.png", type: "image/png" })
  assert.deepEqual(uploadFileAttributes({ type: "image/gif" }, "party.gif", { filename: "banner.png" }), { name: "party.gif", type: "image/gif" })
})

test("the toast reads the host's copy and falls back to the engine's", () => {
  assert.deepEqual(submitToast(true, {}), { type: "notice", title: "Saved", message: "" })
  assert.deepEqual(submitToast(false, {}), { type: "alert", title: "Couldn't save", message: "Please try again." })
  assert.deepEqual(submitToast(true, { success: "Banner updated", successMessage: "Looks good." }),
    { type: "notice", title: "Banner updated", message: "Looks good." })
  assert.deepEqual(submitToast(false, { failure: "No luck", failureMessage: "Try a smaller file." }),
    { type: "alert", title: "No luck", message: "Try a smaller file." })
})

// ---- the submit behind the saving card ---------------------------------------

const fakeForm = () => {
  const listeners = {}
  return {
    submitted: 0,
    listeners,
    addEventListener(name, fn) { (listeners[name] = listeners[name] || []).push(fn) },
    removeEventListener(name, fn) { listeners[name] = (listeners[name] || []).filter((f) => f !== fn) },
    requestSubmit() { this.submitted += 1 },
    end(success) { (listeners["turbo:submit-end"] || []).slice().forEach((fn) => fn({ detail: { success } })) }
  }
}

const fakeStore = () => ({
  opened: [],
  closed: 0,
  open(id, props, opts) { this.opened.push({ id, props, opts }) },
  close() { this.closed += 1 }
})

// A window with named Alpine stores, a hold the test releases by hand, and a
// record of the events dispatched on it.
const fakeWindow = (stores = {}, extra = {}) => {
  const events = []
  const holds = []
  return {
    events,
    holds,
    Alpine: { store: (name) => stores[name] },
    StudioModals: {
      holdAtLeast(ms) {
        const hold = { ms, callbacks: [], then(cb) { this.callbacks.push(cb) }, release() { this.callbacks.forEach((cb) => cb()) } }
        holds.push(hold)
        return hold
      }
    },
    CustomEvent: class { constructor(name, init) { this.type = name; this.detail = init.detail } },
    dispatchEvent(event) { events.push(event) },
    ...extra
  }
}

test("a submit swaps the saving card in, submits, and holds the card before it closes and toasts", () => {
  const modals = fakeStore()
  const win = fakeWindow({ modals })
  const form = fakeForm()
  submitFormWithProgress(form, { saving: "Saving banner…", success: "Banner updated" }, { win })

  assert.deepEqual(modals.opened, [{ id: "saving", props: { dismissible: false, title: "Saving banner…" }, opts: { replace: true } }])
  assert.equal(form.submitted, 1)
  assert.equal(win.holds[0].ms, SAVING_HOLD_MS)

  form.end(true)
  assert.equal(modals.closed, 0, "the card stays up until the hold is over")
  assert.equal(win.events.length, 0)

  win.holds[0].release()
  assert.equal(modals.closed, 1)
  assert.deepEqual(win.events.map((e) => [e.type, e.detail]),
    [["toast", { type: "notice", title: "Banner updated", message: "" }]])
  assert.deepEqual(form.listeners["turbo:submit-end"], [], "the listener is removed after one submit")
})

test("a failed submit toasts an alert", () => {
  const modals = fakeStore()
  const win = fakeWindow({ modals })
  const form = fakeForm()
  submitFormWithProgress(form, {}, { win })
  form.end(false)
  win.holds[0].release()
  assert.equal(win.events[0].detail.type, "alert")
  assert.equal(win.events[0].detail.title, "Couldn't save")
})

test("toast: false closes the card and says nothing; dismissible passes only as true", () => {
  const modals = fakeStore()
  const win = fakeWindow({ modals })
  const form = fakeForm()
  submitFormWithProgress(form, { toast: false, dismissible: true }, { win })
  assert.equal(modals.opened[0].props.dismissible, true)
  assert.equal(modals.opened[0].props.title, "Saving…")
  form.end(true)
  win.holds[0].release()
  assert.equal(modals.closed, 1)
  assert.equal(win.events.length, 0)
})

test("a page-scoped host's store carries the card when the opts name it", () => {
  const modals = fakeStore()
  const emailModals = fakeStore()
  const win = fakeWindow({ modals, emailModals })
  submitFormWithProgress(fakeForm(), { store: "emailModals" }, { win })
  assert.equal(emailModals.opened.length, 1)
  assert.equal(modals.opened.length, 0)
})

test("with no modal store and no hold convention the form still submits and toasts", () => {
  const win = fakeWindow({}, { StudioModals: undefined })
  const form = fakeForm()
  submitFormWithProgress(form, {}, { win })
  assert.equal(form.submitted, 1)
  form.end(true)
  assert.equal(win.events.length, 1)
})

// ---- imageUploadHost ----------------------------------------------------------

// The browser file plumbing the hosts use, recorded.
const fileWindow = (stores, extra = {}) => fakeWindow(stores, {
  File: class { constructor(parts, name, options) { this.parts = parts; this.name = name; this.type = options.type } },
  DataTransfer: class {
    constructor() { const files = []; this.files = files; this.items = { add: (file) => files.push(file) } }
  },
  FileReader: class {
    readAsDataURL(file) { this.onload({ target: { result: `data:${file.type};base64,QQ` } }) }
  },
  ...extra
})

const mountHost = (opts, win) => {
  const host = imageUploadHost(opts, { win })
  host.$refs = { fileInput: { files: null }, form: fakeForm() }
  return host
}

test("each host on a page gets its own owner token", () => {
  const win = fileWindow({ modals: fakeStore() })
  const first = imageUploadHost({}, { win })
  const second = imageUploadHost({}, { win })
  assert.equal(first.ownerId, "iuh-1")
  assert.equal(second.ownerId, "iuh-2")
})

test("open() opens the cropper as the picker, at the host's ratio, stamped with its owner", () => {
  const modals = fakeStore()
  const win = fileWindow({ modals })
  const host = mountHost({ aspectRatio: 5, maxWidth: 2000 }, win)
  host.open()
  assert.equal(modals.opened[0].id, "crop-photo")
  assert.deepEqual(modals.opened[0].props, { aspectRatio: 5, transparent: true, dispatch: true, maxWidth: 2000, owner: host.ownerId })
})

test("open() on a page with no modal store does nothing", () => {
  const win = fileWindow({})
  mountHost({}, win).open()
  assert.equal(win.events.length, 0)
})

test("a file from a native picker opens the cropper on that image and clears the input", () => {
  const modals = fakeStore()
  const win = fileWindow({ modals })
  const host = mountHost({ aspectRatio: 1 }, win)
  const input = { files: [{ type: "image/png", name: "me.png" }], value: "C:\\me.png" }
  host.onFileSelected({ target: input })
  assert.equal(modals.opened[0].props.imageUrl, "data:image/png;base64,QQ")
  assert.equal(modals.opened[0].props.owner, host.ownerId)
  assert.equal(input.value, "", "so the same file can be picked again")
})

test("a confirmed crop goes into the host's hidden input and the form submits behind the saving card", () => {
  const modals = fakeStore()
  const win = fileWindow({ modals })
  const host = mountHost({ filename: "avatar.png", saving: "Saving photo…" }, win)
  host.onCropConfirmed({ blob: { type: "image/png", bytes: 1 }, owner: host.ownerId })

  const staged = host.$refs.fileInput.files
  assert.equal(staged.length, 1)
  assert.equal(staged[0].name, "avatar.png")
  assert.equal(staged[0].type, "image/png")
  assert.equal(host.$refs.form.submitted, 1)
  assert.equal(modals.opened[0].id, "saving")
  assert.equal(modals.opened[0].props.title, "Saving photo…")
})

test("a crop another host opened is left alone", () => {
  const win = fileWindow({ modals: fakeStore() })
  const host = mountHost({}, win)
  host.onCropConfirmed({ blob: { type: "image/png" }, owner: "iuh-99" })
  assert.equal(host.$refs.fileInput.files, null)
  assert.equal(host.$refs.form.submitted, 0)
})

test("a passed-through GIF uploads under its own name and type", () => {
  const win = fileWindow({ modals: fakeStore() })
  const host = mountHost({ filename: "banner.png", allowGifs: true }, win)
  host.onCropConfirmed({ blob: { type: "image/gif" }, owner: host.ownerId, filename: "party.gif", uncropped: true })
  assert.equal(host.$refs.fileInput.files[0].name, "party.gif")
  assert.equal(host.$refs.fileInput.files[0].type, "image/gif")
})

test("the submit goes through window.submitFormWithProgress when a page defines one", () => {
  const calls = []
  const win = fileWindow({ modals: fakeStore() }, { submitFormWithProgress: (form, opts) => calls.push([form, opts]) })
  const opts = { filename: "a.png" }
  const host = mountHost(opts, win)
  host.applyCrop({ type: "image/png" })
  assert.equal(calls.length, 1)
  assert.equal(calls[0][0], host.$refs.form)
  assert.equal(calls[0][1], opts)
  assert.equal(host.$refs.form.submitted, 0)
})

// ---- avatarCropperHost --------------------------------------------------------

const mountAvatar = (win) => {
  const host = avatarCropperHost({ win })
  host.$refs = { hiddenFileInput: { files: null } }
  return host
}

const urlWindow = (stores) => {
  const made = []
  const revoked = []
  const win = fileWindow(stores, {
    URL: {
      createObjectURL: (blob) => { const url = `blob:${made.length + 1}`; made.push(blob); return url },
      revokeObjectURL: (url) => revoked.push(url)
    }
  })
  return { win, made, revoked }
}

test("a picked avatar opens the shared cropper on that image", () => {
  const modals = fakeStore()
  const { win } = urlWindow({ modals })
  const host = mountAvatar(win)
  const input = { files: [{ type: "image/jpeg", name: "me.jpg" }], value: "x" }
  host.onFileSelected({ target: input })
  assert.deepEqual(modals.opened, [{ id: "crop-photo", props: { imageUrl: "data:image/jpeg;base64,QQ" }, opts: undefined }])
  assert.equal(input.value, "")
})

test("a confirmed crop is previewed and staged as avatar.png, and nothing submits", () => {
  const { win, revoked } = urlWindow({ modals: fakeStore() })
  const host = mountAvatar(win)
  assert.equal(host.croppedUrl, null)

  host.applyCrop({ type: "image/png", n: 1 })
  assert.equal(host.croppedUrl, "blob:1")
  assert.equal(host.$refs.hiddenFileInput.files[0].name, "avatar.png")
  assert.equal(host.$refs.hiddenFileInput.files[0].type, "image/png")

  host.applyCrop({ type: "image/png", n: 2 })
  assert.equal(host.croppedUrl, "blob:2")
  assert.deepEqual(revoked, ["blob:1"], "the replaced preview is released")
})

test("removing the photo releases the preview and empties the staged input", () => {
  const { win, revoked } = urlWindow({ modals: fakeStore() })
  const host = mountAvatar(win)
  host.applyCrop({ type: "image/png" })
  host.removePhoto()
  assert.equal(host.croppedUrl, null)
  assert.deepEqual(revoked, ["blob:1"])
  assert.equal(host.$refs.hiddenFileInput.files.length, 0)
})

test("applyCrop with no blob changes nothing", () => {
  const { win } = urlWindow({ modals: fakeStore() })
  const host = mountAvatar(win)
  host.applyCrop(null)
  assert.equal(host.croppedUrl, null)
  assert.equal(host.$refs.hiddenFileInput.files, null)
})
