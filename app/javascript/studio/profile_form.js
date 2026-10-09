// studio/profile_form: the profile edit form's scope (studio/profiles/edit).
//
//   x-data="studioProfileForm({ first_name: 'Pat', email: 'pat@example.com' })"
//
// It holds the fields the inputs bind with x-model and the values the page
// loaded with, says which have changed (the save controls show while any has),
// puts them back on Discard, and asks before the page is left with changes
// unsaved. Its markup carries x-ref="form" on the form it guards.
//
// studio/alpine_scopes publishes it on window, statically: a profile page whose
// factory is missing has no save controls. It imports nothing;
// test/javascript/profile_form.test.mjs loads it as a data: module.

export const LEAVE_PROMPT = "You have unsaved changes. Leave without saving?"

// Whether one field differs from what the page loaded with. Trimmed on both
// sides: whitespace is not a change, and the controller trims on the way in,
// so the bar agrees with what saving would do.
export function fieldChanged(fields, initial, key) {
  return String(fields[key] || "").trim() !== String(initial[key] || "").trim()
}

// How many fields differ.
export function changeCount(fields, initial) {
  return Object.keys(fields).filter((key) => fieldChanged(fields, initial, key)).length
}

// env: { win, doc } for the tests.
export function studioProfileForm(initial, env) {
  const win = (env && env.win) || window
  const doc = (env && env.doc) || document

  return {
    // True once this scope has booted: the page's JS-less controls hide on it.
    alpine: true,
    fields: Object.assign({}, initial),
    initial: Object.assign({}, initial),

    changed(key) {
      return fieldChanged(this.fields, this.initial, key)
    },

    get changeCount() {
      return changeCount(this.fields, this.initial)
    },

    get dirty() {
      return this.changeCount > 0
    },

    discard() {
      this.fields = Object.assign({}, this.initial)
    },

    init() {
      const self = this

      // The exit is guarded both ways. beforeunload covers a hard navigation
      // or a closed tab; turbo:before-visit covers a Turbo Drive visit, which
      // never fires beforeunload.
      this._beforeUnload = function (event) {
        if (!self.dirty) return
        event.preventDefault()
        event.returnValue = ""
      }
      win.addEventListener("beforeunload", this._beforeUnload)

      this._beforeVisit = function (event) {
        if (!self.dirty) return
        if (!win.confirm(LEAVE_PROMPT)) event.preventDefault()
      }
      doc.addEventListener("turbo:before-visit", this._beforeVisit)

      // Submitting is not leaving: both guards drop before the form goes, so
      // saving does not prompt about the changes being saved.
      this.$refs.form.addEventListener("submit", function () { self.teardown() })
    },

    teardown() {
      win.removeEventListener("beforeunload", this._beforeUnload)
      doc.removeEventListener("turbo:before-visit", this._beforeVisit)
    },

    destroy() {
      this.teardown()
    }
  }
}
