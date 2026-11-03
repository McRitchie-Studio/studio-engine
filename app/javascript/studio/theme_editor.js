// studio/theme_editor: the live-preview theme editor, as the Alpine factory its
// template binds.
//
//   dsThemeEditor(seed)    style/_theme, the Theme section of the style guide
//
// It is seeded with the server-resolved role colours and writes the themeable
// role variables on the document as the operator types, so every specimen on
// the page restyles at once. The inputs still carry the real values.
//
// studio/alpine_shims publishes it as a window global before Alpine starts,
// because x-data="dsThemeEditor(...)" is evaluated the moment Alpine does.
//
// It imports nothing; test/javascript/theme_editor.test.mjs loads it as a
// data: module.

// What the style guide's editor writes on the root for `colors`. It sets only
// what has a value and removes nothing.
export function stylePreviewProperties(colors) {
  const properties = [
    ["--color-cta", colors.primary],
    ["--color-cta-fill", colors.primary]
  ]
  if (colors.success) properties.push(["--color-success", colors.success])
  if (colors.warning) properties.push(["--color-warning", colors.warning], ["--color-warning-fill", colors.warning])
  if (colors.danger) properties.push(["--color-danger", colors.danger], ["--color-danger-fill", colors.danger])
  return properties
}

function applyProperties(style, properties) {
  for (const [name, value] of properties) {
    if (value === null) style.removeProperty(name)
    else style.setProperty(name, value)
  }
}

// The method a form really sends, and its body without Rails' _method override.
// The editor's form carries _method=patch, and sending the real method means
// nothing depends on Rack::MethodOverride parsing a multipart fetch body.
//
// It asks for JSON, which the controller answers with a 204 once it has
// written. NO REDIRECT IS FOLLOWED: a fetch that follows a 302 keeps a PATCH a
// PATCH and sends the save again on every hop.
export function formRequest(data) {
  const override = data.get("_method")
  if (override) data.delete("_method")
  return {
    method: override ? String(override).toUpperCase() : "POST",
    body: data,
    headers: { Accept: "application/json" },
    redirect: "manual"
  }
}

// Whether the server took the save: a 2xx from the request itself. A redirect
// (opaque, because none is followed) is the admin gate turning the request
// away, and a refused save is a 422.
export function saved(response) {
  return response.ok === true
}

export const SIGNED_OUT = "Not signed in as an admin. Sign in and save again."

// Why a response that is not a save failed, for the toast.
export function failureReason(response) {
  if (response.type === "opaqueredirect" || response.status === 401) return SIGNED_OUT
  return "HTTP " + response.status
}

// x-data="dsThemeEditor({...})": style/_theme.
//
// SAVE IN PLACE. Save and Regenerate submit by fetch and stay on the style
// guide: the form's @submit.prevent stops the browser navigating to
// its save endpoint, the live preview persists, and the outcome is a toast (the
// engine's `toast` window event). The form's own POST still works when Alpine
// never loads.
export function dsThemeEditor(seed) {
  return {
    colors: Object.assign({
      primary: "#000", dark: "#0f172a", light: "#ffffff",
      success: "#367E3A", warning: "#FF7C47", danger: "#EF4444",
      accent: "#6366F1"
    }, seed || {}),
    saving: false,

    updatePreview() {
      applyProperties(document.documentElement.style, stylePreviewProperties(this.colors))
    },

    persist(form, label) {
      if (this.saving) return
      this.saving = true
      const request = formRequest(new FormData(form))
      fetch(form.action, request)
        .then((res) => {
          if (!saved(res)) throw new Error(failureReason(res))
          return res
        })
        .then(() => { this.toast("notice", label, "Saved in place — the page stayed put.") })
        .catch((err) => { this.toast("alert", "Save failed", String((err && err.message) || err)) })
        .finally(() => { this.saving = false })
    },

    toast(type, title, message) {
      window.dispatchEvent(new CustomEvent("toast", { detail: { type: type, title: title, message: message } }))
    },

    saveTheme(e) { this.persist(e.target, "Theme saved") },
    regenerate(e) { this.persist(e.target, "Theme cache cleared") }
  }
}
