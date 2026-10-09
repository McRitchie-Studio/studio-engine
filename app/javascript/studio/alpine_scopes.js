// studio/alpine_scopes: the x-data factories the engine's partials and its
// hosts' pages bind, each published on window from the module that owns it.
//
//   x-data="cropPhotoModal({ store: 'modals' })"     studio/cropper
//   x-data="imageUploadHost({ aspectRatio: 5 })"     studio/image_upload
//   x-data="avatarCropperHost()"                     studio/image_upload
//   x-data="birthdayModal({ minAge, url })"          studio/birthday
//   x-data="studioBirthdayFields('1991-01-31')"      studio/birthday
//   x-data="studioProfileForm({ first_name: 'Pat' })" studio/profile_form
//   submitFormWithProgress(form, opts)               studio/image_upload
//
// WHY THESE ARRIVE WITH THE PAGE AND ARE NOT LAZY. Alpine evaluates an x-data
// expression when it meets the element: at start for a page's own markup, at
// mount for a modal card. A factory that is not defined by then leaves its
// element dead, and the element here is a photo upload, the birthday gate or
// the profile form. A dynamic import cannot promise to have resolved, and one
// that fails is final for the document (studio/lazy_controllers). So the
// factories are imported statically and preloaded on every page.
//
// WHY THIS IS ITS OWN ENTRY POINT. layouts/studio/_head imports this module by
// its own nonced module tag as well as through the boot graph
// (studio/alpine_shims imports it), like studio/alpine_stores. Its only imports
// are the modules that own the factories, and those import nothing, so a throw
// or a missing file elsewhere in studio/application's graph still leaves a
// page its uploads, its birthday gate and its profile form. It installs itself
// on evaluation, once.
//
// A name a host defined first is left alone.
import { cropPhotoModal } from "studio/cropper"
import { imageUploadHost, avatarCropperHost, submitFormWithProgress } from "studio/image_upload"
import { birthdayModal, studioBirthdayFields } from "studio/birthday"
import { studioProfileForm } from "studio/profile_form"

// name -> the factory Alpine calls. Alpine passes the expression's own
// arguments and nothing else.
export const SCOPES = {
  cropPhotoModal: (opts) => cropPhotoModal(opts),
  imageUploadHost: (opts) => imageUploadHost(opts),
  avatarCropperHost: () => avatarCropperHost(),
  birthdayModal: (opts) => birthdayModal(opts),
  studioBirthdayFields: (initial) => studioBirthdayFields(initial),
  studioProfileForm: (initial) => studioProfileForm(initial)
}

// Plain functions a page calls by name.
export const FUNCTIONS = {
  submitFormWithProgress: (form, opts) => submitFormWithProgress(form, opts)
}

export function installAlpineScopes(win) {
  for (const name of Object.keys(SCOPES)) {
    if (!win[name]) win[name] = SCOPES[name]
  }
  for (const name of Object.keys(FUNCTIONS)) {
    if (!win[name]) win[name] = FUNCTIONS[name]
  }
}

if (typeof window !== "undefined") installAlpineScopes(window)
