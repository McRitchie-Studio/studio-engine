// studio/image_upload: what an upload does around the crop-photo modal
// (studio/cropper). Three names a page binds:
//
//   x-data="imageUploadHost({ aspectRatio: 5, maxWidth: 2000, filename: 'banner.png' })"
//       crop, then save at once: the cropped file goes into the host's own
//       hidden form and the form submits behind a saving card.
//   x-data="avatarCropperHost()"
//       crop, then wait: the cropped file is staged on a hidden input and the
//       enclosing form submits it later (components/_avatar_cropper).
//   submitFormWithProgress(form, opts)
//       a Turbo form submit behind the `saving` card, with a toast at the end.
//
// A host hears the crop through the page's own listener:
//
//   @crop-photo-confirmed.window="onCropConfirmed($event.detail)"
//
// studio/alpine_shims publishes all three on window, statically: Alpine
// evaluates the x-data when the page starts, and a host whose factory is
// missing cannot upload. It imports nothing; test/javascript/image_upload.test.mjs
// loads it as a data: module.

// How long the saving card stays up at the least, so it does not flash.
export const SAVING_HOLD_MS = 450

// The props a host opens the crop-photo modal with: its crop, in dispatch
// mode (the modal stays open and the host's saving card replaces it), plus
// `extra` (the picked image, the host's owner token).
export function uploadCropProps(opts, extra) {
  opts = opts || {}
  const props = {
    aspectRatio: opts.aspectRatio || 1,
    transparent: opts.transparent !== false,
    dispatch: true
  }
  if (opts.maxWidth) props.maxWidth = opts.maxWidth
  if (opts.maxHeight) props.maxHeight = opts.maxHeight
  if (opts.autoCropArea) props.autoCropArea = opts.autoCropArea
  if (typeof opts.allowGifs === "boolean") props.allowGifs = opts.allowGifs
  return Object.assign(props, extra || {})
}

// Whether a confirmed crop is this host's to act on. Many hosts can be mounted
// on one page and all hear the same window event, so a confirm names the host
// that opened the cropper. A confirm with no owner applies to any host.
export function cropIsFor(detail, ownerId) {
  if (!detail) return false
  return !detail.owner || detail.owner === ownerId
}

// The name and type the file is uploaded under. A passed-through file (a GIF)
// keeps its own name and type; a cropped one is the PNG the canvas exported,
// under the host's filename.
export function uploadFileAttributes(blob, filename, opts) {
  return {
    name: filename || (opts && opts.filename) || "image.png",
    type: (blob && blob.type) || "image/png"
  }
}

// The toast a finished submit raises.
export function submitToast(ok, opts) {
  opts = opts || {}
  return {
    type: ok ? "notice" : "alert",
    title: ok ? (opts.success || "Saved") : (opts.failure || "Couldn't save"),
    message: ok ? (opts.successMessage || "") : (opts.failureMessage || "Please try again.")
  }
}

// Submits `form` (a Turbo form) behind the saving card: the card replaces
// whatever is open, stays at least SAVING_HOLD_MS, then closes, and a toast
// reports the result. opts: saving, success, successMessage, failure,
// failureMessage, dismissible (default false), toast (default true), store
// (the Alpine store the card is mounted in, default "modals").
export function submitFormWithProgress(form, opts, env) {
  opts = opts || {}
  const win = (env && env.win) || window
  const store = win.Alpine && win.Alpine.store(opts.store || "modals")
  const hold = (win.StudioModals && win.StudioModals.holdAtLeast)
    ? win.StudioModals.holdAtLeast(SAVING_HOLD_MS)
    : { then: function (callback) { callback() } }

  if (store) {
    store.open("saving", { dismissible: opts.dismissible === true, title: opts.saving || "Saving…" }, { replace: true })
  }

  const onEnd = function (event) {
    form.removeEventListener("turbo:submit-end", onEnd)
    const ok = !!(event.detail && event.detail.success)
    hold.then(function () {
      if (store) store.close()
      if (opts.toast !== false) {
        win.dispatchEvent(new win.CustomEvent("toast", { detail: submitToast(ok, opts) }))
      }
    })
  }
  form.addEventListener("turbo:submit-end", onEnd)
  form.requestSubmit()
}

// x-data for a crop-then-save uploader. The host's markup carries
// x-ref="fileInput" (the hidden file field) inside x-ref="form". opts is the
// crop (aspectRatio, maxWidth, maxHeight, transparent, autoCropArea,
// allowGifs), the save copy submitFormWithProgress reads, `filename`, and
// `store`: the Alpine store the crop-photo and saving cards are mounted in,
// for a page that mounts them on its own scoped host.
//
// Two ways in:
//   open()            the crop modal is the picker (click or drop a file).
//   onFileSelected()  a native file input hands the image in.
export function imageUploadHost(opts, env) {
  opts = opts || {}
  const win = (env && env.win) || window
  const storeName = opts.store || "modals"
  const ownerId = "iuh-" + (win.__studioImageUploadHostSeq = (win.__studioImageUploadHostSeq || 0) + 1)

  return {
    ownerId,

    open() {
      if (!win.Alpine || !win.Alpine.store(storeName)) return
      win.Alpine.store(storeName).open("crop-photo", uploadCropProps(opts, { owner: ownerId }))
    },

    onCropConfirmed(detail) {
      if (!cropIsFor(detail, ownerId)) return
      this.applyCrop(detail.blob, detail.filename)
    },

    onFileSelected(event) {
      const file = event.target.files[0]
      if (!file) return
      const reader = new win.FileReader()
      reader.onload = function (loaded) {
        win.Alpine.store(storeName).open("crop-photo", uploadCropProps(opts, { imageUrl: loaded.target.result, owner: ownerId }))
      }
      reader.readAsDataURL(file)
      event.target.value = ""
    },

    applyCrop(blob, filename) {
      if (!blob) return
      const file = uploadFileAttributes(blob, filename, opts)
      const transfer = new win.DataTransfer()
      transfer.items.add(new win.File([blob], file.name, { type: file.type }))
      this.$refs.fileInput.files = transfer.files
      const submit = win.submitFormWithProgress || ((form, options) => submitFormWithProgress(form, options, env))
      submit(this.$refs.form, opts)
    }
  }
}

// x-data for components/_avatar_cropper: a cropped avatar as a form field.
// The crop runs in the shared crop-photo modal; the 256px PNG it confirms is
// previewed and staged on x-ref="hiddenFileInput", and the enclosing form
// (sign-up, profile completion) submits it later.
export function avatarCropperHost(env) {
  const win = (env && env.win) || window

  return {
    croppedUrl: null,

    onFileSelected(event) {
      const file = event.target.files[0]
      if (!file) return
      const reader = new win.FileReader()
      reader.onload = function (loaded) {
        win.Alpine.store("modals").open("crop-photo", { imageUrl: loaded.target.result })
      }
      reader.readAsDataURL(file)
      event.target.value = ""
    },

    applyCrop(blob) {
      if (!blob) return
      if (this.croppedUrl) win.URL.revokeObjectURL(this.croppedUrl)
      this.croppedUrl = win.URL.createObjectURL(blob)
      const transfer = new win.DataTransfer()
      transfer.items.add(new win.File([blob], "avatar.png", { type: "image/png" }))
      this.$refs.hiddenFileInput.files = transfer.files
    },

    removePhoto() {
      if (this.croppedUrl) win.URL.revokeObjectURL(this.croppedUrl)
      this.croppedUrl = null
      this.$refs.hiddenFileInput.files = new win.DataTransfer().files
    }
  }
}
