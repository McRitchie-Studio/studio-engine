// studio/email_banner: the two Alpine factories behind the email manager.
//
//   emailBannerEditor(config)   studio/emails/show: the live banner editor.
//                               Typing repaints the banner, and ONE Save button
//                               reports whether there is anything to save.
//   emailRecipients(config)     studio/emails/index: repaints EVERY row when
//                               the example recipient changes.
//
// studio/alpine_shims publishes both before Alpine starts, because
// x-data="emailBannerEditor(...)" is evaluated the moment Alpine does.
//
// WHY THE PREVIEW IS PAINTED IN THE BROWSER AND NOT RE-RENDERED. The banner is
// already server-rendered by the mailer's own partial, which is what makes it
// trustworthy. The editor does not replace it: it edits the text nodes, the
// logo and the tint of that same rendered banner in place. The shape, the
// typography and the scaling stay the server's. A second banner rendered in
// JavaScript would be a second implementation of the email, and it would drift.
//
// WHY THE PLACEHOLDER RULE IS REPEATED HERE. Studio::Banner fills {name} and
// {app} server-side. Repeating that in script is a real duplication: the
// alternative is a round trip per keystroke. The rule is small and pinned on
// both sides: banner_copy_test.rb for Ruby, test/javascript/email_banner.test.mjs
// and e2e/email_banner_editor.spec.js for the browser. If they ever disagree,
// the server is right.
//
// It imports nothing; the Node test loads it as a data: module.

// The first word of a recipient's name, or "" when there is none.
export function firstNameOf(name) {
  return (name || "").trim().split(/\s+/)[0] || ""
}

// A banner header for a recipient. {app} is substituted on both paths because
// it does not depend on the recipient: a header reading "Welcome to {app}" must
// not show a raw brace here while the inbox shows the app's name. With no first
// name, a template that greets by name gives way to its fallback.
export function resolveBannerText(template, fallback, first, app) {
  const text = (template || "").replace(/\{app\}/g, app || "")
  if (first) return text.replace(/\{name\}/g, first)
  if (text.indexOf("{name}") !== -1) return (fallback || "").replace(/\{app\}/g, app || "")
  return text
}

// A subject line for a recipient. A subject has no second field for the
// nameless case, so an unresolved placeholder is removed along with the
// punctuation holding it: the same two passes Studio::Banner.interpolate makes,
// so "Sign in, {name}" reads "Sign in" here exactly as it would in an inbox.
export function resolveSubjectText(template, first, app) {
  const text = (template || "").replace(/\{app\}/g, app || "")
  if (first) return text.replace(/\{name\}/g, first)
  return text.replace(/[,;:—-]?\s*\{name\}/g, "")
             .replace(/^\s*[,;:—-]\s*/, "")
             .replace(/\s+/g, " ")
             .trim()
}

// The tint as a whole percentage from 0 to 100; an unreadable value is the
// default.
export function scrimPercent(value, fallback) {
  let percent = parseInt(value, 10)
  if (isNaN(percent)) percent = fallback
  return Math.min(Math.max(percent, 0), 100)
}

// Whether any field of `form` differs from `initial`. Field by field and not
// JSON.stringify, whose output depends on key order: two equal objects can
// stringify differently.
//
// No type coercion, deliberately. The payload sends real booleans for the two
// checkboxes and strings for everything else, and a mutation run showed that
// normalising them changed nothing. Unproven defensive code in a comparison
// that decides whether a Save button appears is worse than none.
export function formDirty(form, initial) {
  return Object.keys(initial).some((key) => (form[key] ?? "") !== (initial[key] ?? ""))
}

// The logo has THREE states, and a URL field alone can only express two.
// "standard" inherits, "custom" uses what this app uploaded, "hidden" is the
// deliberate no-logo answer that blank cannot say.
export function logoMode(hideLogo, uploadedLogo) {
  if (hideLogo === true || hideLogo === "1") return "hidden"
  if (uploadedLogo) return "custom"
  return "standard"
}

export const FRAMED_PREVIEW = "iframe[data-email-banner-preview]"

// A node of the banner rendered inside `scope`. The banner lives in an IFRAME
// wherever studio/emails/_banner_preview isolates it (its default): the email's
// table is its own document, so it cannot nest rows inside the list. The frame
// is a same-origin srcdoc, so its nodes are reachable; contentDocument is null
// until the frame has parsed, which is why whenFrameLoads exists.
export function bannerNodeIn(scope, selector) {
  const frame = scope.querySelector(FRAMED_PREVIEW)
  if (frame) {
    try { return frame.contentDocument && frame.contentDocument.querySelector(selector) }
    catch (_) { return null }
  }
  return scope.querySelector(selector)
}

// Runs `repaint` each time the banner's frame in `scope` loads. Bound once per
// frame, however often it is asked.
export function whenFrameLoads(scope, repaint) {
  const frame = scope.querySelector(FRAMED_PREVIEW)
  if (!frame || frame.dataset.repaintBound) return
  frame.dataset.repaintBound = "1"
  frame.addEventListener("load", repaint)
}

// x-data="emailBannerEditor({...})".
//
// TOUCHED VS DIRTY: different questions, and the button answers both. `touched`
// is "has anyone typed here", and it decides whether the button is SHOWN.
// `dirty` is "is anything actually different from what is saved", and it
// decides whether the button is ENABLED. Typing "A" into the subject and
// deleting it again leaves touched true and dirty false: the button stays
// visible and goes back to disabled, which tells the operator their edit was
// undone and not silently swallowed.
export function emailBannerEditor(config) {
  return {
    form: Object.assign({}, config.values),
    initial: Object.assign({}, config.values),
    targets: config.targets || [],
    targetId: config.targetId,
    touched: false,
    pickerOpen: false,

    init() {
      this.paint()
      this.$watch("form", () => { this.touched = true; this.paint() })
      this.$watch("targetId", () => this.paint())
    },

    target() {
      return this.targets.find((t) => t.id === this.targetId) || this.targets[0] || {}
    },

    firstName() {
      return firstNameOf(this.target().name)
    },

    resolve(template, fallback) {
      return resolveBannerText(template, fallback, this.firstName(), config.appName)
    },

    headerText() { return this.resolve(this.form.header, this.form.header_fallback) },
    subjectText() { return this.resolve(this.form.subject, this.form.subject) },

    dirty() {
      return formDirty(this.form, this.initial)
    },

    logoMode() {
      return logoMode(this.form.hide_logo, config.uploadedLogo)
    },

    setLogoMode(mode) {
      this.form.hide_logo = mode === "hidden"
    },

    currentLogo() {
      if (this.logoMode() === "hidden") return ""
      return config.uploadedLogo || config.inheritedLogo || ""
    },

    // The slider's own fill, as a percentage string for --range-fill.
    scrimFill() {
      return scrimPercent(this.form.scrim_percent, config.defaultScrim) + "%"
    },

    scrimCss() {
      return "rgba(24,16,64," + (scrimPercent(this.form.scrim_percent, config.defaultScrim) / 100) + ")"
    },

    paint() {
      const root = this.$root
      const header = bannerNodeIn(root, "[data-banner-header]")
      const subtext = bannerNodeIn(root, "[data-banner-subtext]")
      const logo = bannerNodeIn(root, "[data-banner-logo]")
      const scrim = bannerNodeIn(root, "[data-banner-scrim]")
      whenFrameLoads(root, () => this.paint())

      if (header) header.textContent = this.headerText()
      if (subtext) subtext.textContent = this.form.subtext || ""
      if (scrim) scrim.style.backgroundColor = this.scrimCss()
      if (logo) {
        const url = this.currentLogo()
        if (url) {
          if (logo.getAttribute("src") !== url) logo.setAttribute("src", url)
          logo.style.display = "block"
        } else {
          logo.style.display = "none"
        }
      }
    },

    // Every visible field is x-model bound and carries no name; the hidden
    // form mirrors them. One submit writes the whole page.
    save() {
      if (!this.dirty()) return
      this.$refs.saveForm.requestSubmit()
    }
  }
}

// x-data="emailRecipients({...})".
//
// The list shows each email's banner and subject as they would arrive. Both are
// per-recipient (the banner greets by first name and the subject may too), so a
// list rendered for one person is a list of half-truths about everyone else.
//
// WHY THE TEMPLATES RIDE ON THE ROW. Each row carries its own header, fallback
// and subject templates as data attributes, read from the DOM. A second JSON
// payload listing every email would have to be kept in step with the rows, and
// a row whose payload entry went missing would silently stop repainting while
// still looking correct for whoever was selected at page load.
export function emailRecipients(config) {
  return {
    targets: config.targets || [],
    targetId: config.targetId,
    pickerOpen: false,

    init() {
      this.paint()
      this.$watch("targetId", () => this.paint())
    },

    target() {
      return this.targets.find((t) => t.id === this.targetId) || this.targets[0] || {}
    },

    firstName() {
      return firstNameOf(this.target().name)
    },

    resolve(template, fallback) {
      return resolveBannerText(template, fallback, this.firstName(), config.appName)
    },

    resolveSubject(template) {
      return resolveSubjectText(template, this.firstName(), config.appName)
    },

    bannerNode(row, selector) {
      return bannerNodeIn(row, selector)
    },

    paintRow(row) {
      const header = this.bannerNode(row, "[data-banner-header]")
      const subject = row.querySelector("[data-row-subject]")
      if (header) {
        header.textContent = this.resolve(row.dataset.header, row.dataset.headerFallback)
      }
      if (subject) subject.textContent = this.resolveSubject(row.dataset.subject)
    },

    paint() {
      this.$root.querySelectorAll("[data-email-row]").forEach((row) => {
        this.paintRow(row)
        whenFrameLoads(row, () => { this.paintRow(row) })
      })
    },

    // Anything interactive keeps its own behaviour; everything else opens the
    // email. Without the closest() guard, clicking Upload would both open the
    // cropper and navigate away from it.
    openRow(event, row) {
      // The listener sits on the tbody, so a click can land between rows and
      // arrive with no row at all.
      if (!row) return
      if (event.target.closest("a, button, input, label, form")) return
      const path = row.dataset.emailPath
      if (path) window.location = path
    }
  }
}
