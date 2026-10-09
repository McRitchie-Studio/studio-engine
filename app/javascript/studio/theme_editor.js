// studio/theme_editor: the two live-preview theme editors, as the Alpine
// factories their templates bind.
//
//   themeEditor(colors)    theme_settings/edit, the standalone /admin/theme page
//   dsThemeEditor(seed)    style/_theme, the Theme section of the style guide
//
// Both are seeded with the server-resolved role colours and write the themeable
// role variables on the document as the operator types, so every specimen on
// the page restyles at once. The inputs still carry the real values.
//
// studio/alpine_shims publishes both as window globals before Alpine starts,
// because x-data="themeEditor(...)" is evaluated the moment Alpine does.
//
// It imports nothing; test/javascript/theme_editor.test.mjs loads it as a
// data: module.

// The seven roles the standalone editor edits, in the order it lists them.
export const ROLES = ["primary", "success", "accent", "warning", "danger", "dark", "light"]

// A typed colour as #rrggbb: a missing # is added and a 3-digit hex is doubled.
// Answers null for anything that is not a 3- or 6-digit hex.
export function normalizeHex(value) {
  let hex = String(value == null ? "" : value).trim()
  if (!hex.startsWith("#")) hex = "#" + hex
  if (/^#[0-9a-fA-F]{3}$/.test(hex)) {
    hex = "#" + hex[1] + hex[1] + hex[2] + hex[2] + hex[3] + hex[3]
  }
  return /^#[0-9a-fA-F]{6}$/.test(hex) ? hex : null
}

// `hex` (#rrggbb) moved `amount` (0..1) of the way to white.
export function lightenColor(hex, amount) {
  hex = hex.replace("#", "")
  const r = parseInt(hex.substring(0, 2), 16)
  const g = parseInt(hex.substring(2, 4), 16)
  const b = parseInt(hex.substring(4, 6), 16)
  const nr = Math.round(r + (255 - r) * amount)
  const ng = Math.round(g + (255 - g) * amount)
  const nb = Math.round(b + (255 - b) * amount)
  return "#" + [nr, ng, nb].map((c) => c.toString(16).padStart(2, "0")).join("")
}

// The standalone editor's colours: every role present, blank when the server
// resolved none.
export function seededColors(seed) {
  const colors = {}
  ROLES.forEach((role) => { colors[role] = (seed && seed[role]) || "" })
  return colors
}

// What the standalone editor writes on the root for `colors`, as
// [property, value] pairs; a null value removes the property.
//
// btn-warning and btn-danger paint --color-<role>-fill first (the resolver
// emits it for the engine defaults), so a typed colour sets it too or the
// specimens keep the default fill. A cleared colour drops the override.
export function previewProperties(colors) {
  const properties = [
    ["--color-cta", colors.primary],
    ["--color-success", colors.success],
    ["--color-warning", colors.warning || "#FF7C47"],
    ["--color-danger", colors.danger || "#EF4444"]
  ]
  for (const role of ["warning", "danger"]) {
    properties.push([`--color-${role}-fill`, colors[role] ? colors[role] : null])
  }
  return properties
}

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

// x-data="themeEditor({...})": theme_settings/edit.
export function themeEditor(seed) {
  return {
    colors: seededColors(seed),

    resetColor(role, defaultVal) {
      this.colors[role] = defaultVal
      this.updatePreview()
    },

    normalizeHex(role) {
      const hex = normalizeHex(this.colors[role])
      if (hex) this.colors[role] = hex
      this.updatePreview()
    },

    // Live CSS variables on the document, for immediate feedback.
    updatePreview() {
      applyProperties(document.documentElement.style, previewProperties(this.colors))
    },

    darkPreviewStyle() {
      return { backgroundColor: this.colors.dark, borderRadius: "0" }
    },

    darkSurfaceStyle() {
      return {
        backgroundColor: this.lightenColor(this.colors.dark, 0.3),
        border: "1px solid rgba(255,255,255,0.1)"
      }
    },

    lightPreviewStyle() {
      return { backgroundColor: this.colors.light, borderRadius: "0" }
    },

    lightSurfaceStyle() {
      return { backgroundColor: "#ffffff", border: "1px solid #e2e8f0" }
    },

    lightenColor(hex, amount) {
      return lightenColor(hex, amount)
    }
  }
}

// The method a form really sends, and its body without Rails' _method override.
// The editor's form carries _method=patch, and sending the real method means
// nothing depends on Rack::MethodOverride parsing a multipart fetch body.
export function formRequest(data) {
  const override = data.get("_method")
  if (override) data.delete("_method")
  return { method: override ? String(override).toUpperCase() : "POST", body: data }
}

// x-data="dsThemeEditor({...})": style/_theme.
//
// SAVE IN PLACE. Save and Regenerate submit by fetch and stay on the style
// guide: the form's @submit.prevent stops the browser navigating to
// /admin/theme, the live preview persists, and the outcome is a toast (the
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
          if (!res.ok) throw new Error("HTTP " + res.status)
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
