// copy-text: one click puts a value on the clipboard, and says so. It sits on the
// element around the control (studio/marketing_kit/_kit):
//
//   <div data-studio-controller="copy-text" data-copy-text-text-value="#8E82FE">
//     <button type="button" data-studio-action="click->copy-text#copy">...</button>
//     <span role="status" data-copy-text-target="status"></span>
//   </div>
//
// The status is written only after the browser answers, so "Copied" is never
// shown for a copy that failed. navigator.clipboard exists only in a secure
// context and may refuse; the older selection copy then gets one try.
import { Controller } from "@hotwired/stimulus"

const SHOWN_MS = 1600

// True when `text` reached the clipboard. It never rejects.
export async function copyToClipboard(text, nav = navigator, doc = document) {
  try {
    await nav.clipboard.writeText(text)
    return true
  } catch {
    return selectionCopy(text, doc)
  }
}

function selectionCopy(text, doc) {
  const field = doc.createElement("textarea")
  field.value = text
  field.setAttribute("readonly", "")
  field.style.position = "fixed"
  field.style.opacity = "0"
  doc.body.appendChild(field)
  try {
    field.select()
    return doc.execCommand("copy")
  } catch {
    return false
  } finally {
    field.remove()
  }
}

export default class extends Controller {
  static targets = ["status"]
  static values = {
    text: String,
    copied: { type: String, default: "Copied" },
    failed: { type: String, default: "Could not copy" }
  }

  async copy() {
    const copied = await copyToClipboard(this.textValue)
    if (!this.hasStatusTarget) return

    this.statusTarget.textContent = copied ? this.copiedValue : this.failedValue
    clearTimeout(this.timer)
    this.timer = setTimeout(() => { this.statusTarget.textContent = "" }, SHOWN_MS)
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
