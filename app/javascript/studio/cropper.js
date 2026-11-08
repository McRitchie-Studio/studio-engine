// studio/cropper: the crop-photo modal (studio/modals/_crop_photo), the one
// cropper every upload in the engine and its hosts goes through.
//
//   x-data="cropPhotoModal({ store: 'modals' })"
//
// The modal hands the result to its opener by the `crop-photo-confirmed` window
// event; the opener owns the upload (studio/image_upload: imageUploadHost saves
// at once, avatarCropperHost stages the file on its form). The image gets in
// two ways:
//
//   imageUrl prop     the opener already picked a file and passes its data URL;
//                     the modal goes straight to the cropper.
//   no imageUrl       the modal is the picker: click or drop a file, then crop.
//
// Open it with the crop a page wants:
//
//   Alpine.store('modals').open('crop-photo',
//     { imageUrl, aspectRatio: 3, maxWidth: 900, transparent: false })
//
// Cropper.js is the page's own global (studio/_cropper_assets loads it from
// cdnjs on a page that can open the modal). A page where it never arrives says
// so in the modal's error line; the button never takes a press that does
// nothing.
//
// The factory is published by studio/alpine_shims as window.cropPhotoModal and
// Alpine.data("cropPhotoModal"), statically, because Alpine evaluates the
// x-data when the card mounts and a card whose factory is missing is dead.
// It imports nothing; test/javascript/cropper.test.mjs loads it as a data:
// module.

// The crop an opener gets when it names nothing: a square 256px avatar on a
// transparent ground.
export const CROP_DEFAULTS = {
  aspectRatio: 1,
  maxWidth: 256,
  maxHeight: 256,
  transparent: true,
  allowGifs: false,
  autoCropArea: 0.9,
  dispatch: false,
  owner: null
}

export const NOT_AN_IMAGE = "Please choose an image file."
export const GIF_REFUSED = "GIFs aren't accepted here. Use a PNG, JPG or WebP."
export const CROPPER_MISSING = "The photo cropper did not load. Reload the page and try again."

// How long a mount waits for Cropper.js before it reports the library missing,
// and how often it looks. The script is deferred, so on a Turbo visit it can
// land a moment after the card opens.
export const LIBRARY_WAIT_MS = 3000
export const LIBRARY_POLL_MS = 100

// The crop a modal entry's props ask for, over the defaults.
//   dispatch  the modal stays open after confirm, and the opener's host runs
//             its own saving card in its place. Without it the modal closes.
//   owner     carried through and echoed on confirm, so only the host that
//             opened the cropper acts on the result.
export function cropSettings(props) {
  props = props || {}
  const settings = { ...CROP_DEFAULTS }
  if (props.aspectRatio) settings.aspectRatio = props.aspectRatio
  if (props.maxWidth) settings.maxWidth = props.maxWidth
  if (props.maxHeight) settings.maxHeight = props.maxHeight
  if (typeof props.transparent === "boolean") settings.transparent = props.transparent
  if (typeof props.allowGifs === "boolean") settings.allowGifs = props.allowGifs
  if (props.dispatch) settings.dispatch = true
  settings.owner = props.owner || null
  if (props.autoCropArea) settings.autoCropArea = props.autoCropArea
  return settings
}

// What Cropper.js is constructed with: the crop box holds the asked ratio.
export function cropperOptions(settings) {
  return {
    aspectRatio: settings.aspectRatio,
    viewMode: 1,
    dragMode: "move",
    autoCropArea: settings.autoCropArea,
    cropBoxResizable: true,
    cropBoxMovable: true,
    background: false,
    guides: true
  }
}

// What getCroppedCanvas is asked for. The WIDTH alone is capped: a fixed ratio
// already bounds the height (width / aspectRatio), and passing maxHeight too
// makes Cropper.js scale the whole source down to fit it when the source is
// taller, which costs the crop its resolution.
export function canvasOptions(settings) {
  const options = { maxWidth: settings.maxWidth, imageSmoothingQuality: "high" }
  if (!settings.transparent) options.fillColor = "#ffffff"
  return options
}

// By type, not extension: a file renamed to .gif is still a PNG and belongs in
// the cropper, and a .GIF from a Windows machine is still a GIF.
export function isAnimatedCandidate(file) {
  return ((file && file.type) || "").toLowerCase() === "image/gif"
}

// What a picked file does: "crop" it, "pass" it through untouched, or the
// error line it earns.
//
// A GIF never goes through the cropper: the crop is painted on a canvas and
// exported as a PNG, which keeps frame one and drops the animation. Where GIFs
// are allowed the original bytes pass through, uncropped; where they are not,
// the file is refused.
export function fileRoute(file, settings) {
  if (!file.type || file.type.indexOf("image/") !== 0) return { error: NOT_AN_IMAGE }
  if (!isAnimatedCandidate(file)) return { route: "crop" }
  return settings.allowGifs ? { route: "pass" } : { error: GIF_REFUSED }
}

// The detail of `crop-photo-confirmed`. The owner rides with the blob: the
// event is a window event, so every upload host on the page hears it, and a
// page can mount one host per row. A passed-through file carries its own name
// and says it is uncropped.
export function confirmedDetail(blob, owner, original) {
  const detail = { blob, owner: owner || null }
  if (original) {
    detail.filename = original.name
    detail.uncropped = true
  }
  return detail
}

// Calls `ready(Cropper)` once the page has Cropper.js, now or within
// LIBRARY_WAIT_MS, and `missing()` when it never arrives. Returns a function
// that stops the wait.
export function whenCropperLoads(win, ready, missing) {
  if (typeof win.Cropper !== "undefined") {
    ready(win.Cropper)
    return () => {}
  }
  let waited = 0
  let stopped = false
  const look = () => {
    if (stopped) return
    if (typeof win.Cropper !== "undefined") { ready(win.Cropper); return }
    waited += LIBRARY_POLL_MS
    if (waited >= LIBRARY_WAIT_MS) { missing(); return }
    win.setTimeout(look, LIBRARY_POLL_MS)
  }
  win.setTimeout(look, LIBRARY_POLL_MS)
  return () => { stopped = true }
}

// x-data for studio/modals/_crop_photo. opts.store names the Alpine store the
// modal is mounted in: "modals" for the shared host, a page-scoped host's own
// name otherwise. env.win is the window (the tests pass their own).
export function cropPhotoModal(opts, env) {
  opts = opts || {}
  const win = (env && env.win) || window

  return {
    _storeName: opts.store || "modals",
    cropper: null,
    imageUrl: null,
    fromParent: false,
    dragging: false,
    error: null,
    aspectRatio: CROP_DEFAULTS.aspectRatio,
    maxWidth: CROP_DEFAULTS.maxWidth,
    maxHeight: CROP_DEFAULTS.maxHeight,
    transparent: CROP_DEFAULTS.transparent,
    allowGifs: CROP_DEFAULTS.allowGifs,
    autoCropArea: CROP_DEFAULTS.autoCropArea,
    dispatch: CROP_DEFAULTS.dispatch,
    owner: null,

    init() {
      const current = this.$store[this._storeName].current()
      const props = (current && current.props) || {}
      Object.assign(this, cropSettings(props))
      if (props.imageUrl) {
        this.fromParent = true
        this.imageUrl = props.imageUrl
        this.mountCropper()
      }
    },

    destroy() {
      this.releaseCropper()
    },

    releaseCropper() {
      if (this._stopWaiting) { this._stopWaiting(); this._stopWaiting = null }
      if (this.cropper) { this.cropper.destroy(); this.cropper = null }
    },

    mountCropper() {
      const self = this
      this.$nextTick(function () {
        self.releaseCropper()
        self._stopWaiting = whenCropperLoads(win, function (Cropper) {
          self._stopWaiting = null
          if (!self.$refs.cropImage) return
          self.cropper = new Cropper(self.$refs.cropImage, cropperOptions(self))
          // A crop in progress locks the modal (no click-outside, no Escape), so
          // a stray click does not discard it; Cancel still closes. cropReady
          // tells an observer of the store the picker has become the cropper:
          // imageUrl is this scope's own and never reaches the entry's props.
          const entry = self.$store[self._storeName].current()
          if (entry && entry.props) { entry.props.dismissible = false; entry.props.cropReady = true }
        }, function () {
          self._stopWaiting = null
          self.error = CROPPER_MISSING
        })
      })
    },

    readFile(file) {
      if (!file) return
      const verdict = fileRoute(file, this)
      if (verdict.error) { this.error = verdict.error; return }
      if (verdict.route === "pass") {
        this.error = null
        this.passThrough(file)
        return
      }

      const self = this
      const reader = new win.FileReader()
      reader.onload = function (event) {
        self.error = null
        self.imageUrl = event.target.result
        self.mountCropper()
      }
      reader.readAsDataURL(file)
    },

    isAnimatedCandidate(file) {
      return isAnimatedCandidate(file)
    },

    announce(detail) {
      try {
        win.dispatchEvent(new win.CustomEvent("crop-photo-confirmed", { detail }))
      } catch (_) {}
    },

    // The original file goes straight to the opener, with no canvas in the path.
    passThrough(file) {
      this.announce(confirmedDetail(file, this.owner, file))
      this.releaseCropper()
      if (!this.dispatch) this.$store[this._storeName].close()
    },

    onFilePicked(event) {
      const file = event.target.files[0]
      event.target.value = ""
      this.readFile(file)
    },

    onDrop(event) {
      this.dragging = false
      const file = event.dataTransfer && event.dataTransfer.files && event.dataTransfer.files[0]
      this.readFile(file)
    },

    cancel() {
      this.releaseCropper()
      this.$store[this._storeName].close()
    },

    confirm() {
      if (!this.cropper) return
      const self = this
      const canvas = this.cropper.getCroppedCanvas(canvasOptions(this))
      canvas.toBlob(function (blob) {
        self.announce(confirmedDetail(blob, self.owner))
        self.releaseCropper()
        // In dispatch mode the opener's host swaps its saving card in over
        // this one, so the modal does not pop the stack itself.
        if (!self.dispatch) self.$store[self._storeName].close()
      }, "image/png")
    }
  }
}
