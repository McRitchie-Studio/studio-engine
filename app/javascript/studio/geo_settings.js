// studio/geo_settings: the live preview on the geo manager (/admin/geo). Tick
// your own region and the navbar badge (and the Blocked? tile) answer at once,
// before anything is saved, so an operator sees what a rule does to a real
// visitor without saving to find out.
//
// geoBlocked mirrors Studio::Geo.blocked? on the client, deliberately and
// narrowly: the same three rules, in the same order, with the same fail-closed
// narrowing. It decides nothing: the server decides again on save and on every
// request afterwards. A mirror can still drift, so turf-monster's browser lane
// asserts the painted result against a policy the server also enforces.
//
// It imports nothing; test/javascript/geo_settings.test.mjs loads it as a
// data: module. Bound to the page by the geo-settings controller.

export const COUNTRY_BOXES = 'input[name="geo_setting[banned_countries][]"]'
export const SUBDIVISION_BOXES = 'input[name="geo_setting[banned_subdivisions][]"]'
export const ENABLED_BOX = 'input[type="checkbox"][name="geo_setting[enabled]"]'

// Whether the policy in `rules` blocks `visitor`.
//   rules:   { enabled, countries: [], subdivisions: [] }
//   visitor: { country, subdivision, home, failClosed }
export function geoBlocked(rules, visitor) {
  if (!rules.enabled) return false

  const { country, subdivision, home, failClosed } = visitor
  if (country && rules.countries.indexOf(country) !== -1) return true
  if (subdivision && country === home && rules.subdivisions.indexOf(subdivision) !== -1) return true

  // Fail closed, narrowed exactly as the server narrows it: only a home-country
  // visitor with NO region, and only when region rules exist.
  if (!failClosed) return false
  if (subdivision) return false
  if (country !== home) return false
  return rules.subdivisions.length > 0
}

// The visitor the page reports, from its data-geo-* attributes.
export function visitorOf(page) {
  return {
    home: page.dataset.geoHome,
    country: page.dataset.geoCountry,
    subdivision: page.dataset.geoSubdivision,
    failClosed: page.dataset.geoFailClosed === "true"
  }
}

function checkedValues(page, selector) {
  return Array.from(page.querySelectorAll(selector + ":checked"), (el) => el.value)
}

// The policy the editor's own boxes describe right now.
export function rulesOf(page) {
  const enabledBox = page.querySelector(ENABLED_BOX)
  return {
    enabled: !!(enabledBox && enabledBox.checked),
    countries: checkedValues(page, COUNTRY_BOXES),
    subdivisions: checkedValues(page, SUBDIVISION_BOXES)
  }
}

// The summary chips are rebuilt from the editor's own squares, so they describe
// the policy about to be saved and not the one on disk. Each chip is built from
// its square's own flag, so there is no second copy of the artwork to keep in
// step.
export function refreshSummary(page, doc, kind, selector) {
  const row = page.querySelector('[data-geo-summary="' + kind + '"]')
  const counts = page.querySelectorAll('[data-geo-summary-count="' + kind + '"]')
  if (!row) return

  row.querySelectorAll(".geo-chip").forEach((chip) => chip.remove())

  const boxes = Array.from(page.querySelectorAll(selector)).filter((box) => box.checked)
  boxes.sort((a, b) => a.value.localeCompare(b.value))

  boxes.forEach((box) => {
    const square = box.closest("label")
    const chip = doc.createElement("span")
    chip.className = "geo-chip inline-flex items-center gap-1.5 px-2 py-1 rounded-lg text-xs font-mono"
    const art = square && square.querySelector("img, span[role='img']")
    if (art) chip.appendChild(art.cloneNode(true))
    chip.appendChild(doc.createTextNode(box.value))
    row.insertBefore(chip, row.querySelector(".geo-summary-empty"))
  })

  // The tab label and the summary heading carry the same number.
  counts.forEach((el) => { el.textContent = boxes.length })
}

// Repaints the summaries, the root's data-geo-preview and the badge that shows
// THIS visitor's location. A specimen badge rendered with other locals keeps
// whatever it was given. Answers whether the visitor is blocked.
export function paintGeo(page, doc) {
  refreshSummary(page, doc, "states", SUBDIVISION_BOXES)
  refreshSummary(page, doc, "countries", COUNTRY_BOXES)

  const visitor = visitorOf(page)
  const blocked = geoBlocked(rulesOf(page), visitor)
  doc.documentElement.setAttribute("data-geo-preview", blocked ? "blocked" : "allowed")
  doc.querySelectorAll("[data-geo-badge]").forEach((badge) => {
    if (badge.dataset.country === visitor.country && (badge.dataset.subdivision || "") === (visitor.subdivision || "")) {
      badge.setAttribute("data-blocked", blocked ? "true" : "false")
    }
  })
  return blocked
}
