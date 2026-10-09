// studio/link_preview_card: the live card on the site identity manager
// (/admin/link_preview). Typing in the title or the description repaints the
// card before anything is saved, falling back to what a blank field really
// sends.
//
// It imports nothing; test/javascript/link_preview_card.test.mjs loads it as a
// data: module. Bound to the page by the link-preview-card controller.

// What the card shows for a field: its trimmed value, or the fallback when the
// field is blank.
export function cardText(value, fallback) {
  const trimmed = String(value == null ? "" : value).trim()
  return trimmed || fallback || ""
}

// The page's fallbacks, from data-fallback-title and data-fallback-description.
export function fallbacksOf(page) {
  return {
    title: page.dataset.fallbackTitle || "",
    description: page.dataset.fallbackDescription || ""
  }
}

// Repaints the card node that `input` (a [data-link-preview-input]) feeds.
// Answers the text it wrote, or null when the input feeds no card node.
export function paintCard(page, input) {
  const key = input && input.dataset ? input.dataset.linkPreviewInput : null
  if (!key) return null
  const target = page.querySelector("[data-link-preview-card-" + key + "]")
  if (!target) return null
  const text = cardText(input.value, fallbacksOf(page)[key])
  target.textContent = text
  return text
}
