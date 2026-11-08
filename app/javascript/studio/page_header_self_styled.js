// studio/page_header_self_styled: the page-header controller's work for an app with no
// Stimulus and no import map (config.page_header_self_styled, docs/PAGE_HEADER.md, "In a
// plain-CSS app"). studio/page_header/_assets loads it by its own module tag, once per
// page, beside the row's scoped CSS.
//
// For every studio/_page_header on the page it:
//   - marks the row data-stuck once it has left its place in the flow, so the CSS gives
//     it the bar;
//   - marks which ends of the tabs hide a tab (data-fade-start, data-fade-end);
//   - scrolls the open tab into view inside the tabs on load;
//   - keeps each Links menu's aria-expanded in step with its popover, walks into the list
//     on ArrowDown, and places the list where the browser has no anchor positioning.
//
// With no pinned stack on the page (window.studioPinnedStack), it also publishes
// --nav-bottom from the document's first <header>, when that header is sticky or fixed,
// so the row sticks under the app's own masthead. An app whose CSS sets --nav-bottom or
// --pin-page-top keeps its own value.
//
// IT IMPORTS NOTHING, because a plain app may have no import map. The five measurements
// below are studio/page_header's, copied; test/javascript/page_header_self_styled.test.mjs
// holds the copies to the originals. It boots only in a browser, so the test can load it
// as a data: module. A module runs once per document, so a Turbo visit rescans on
// turbo:load.

export function isStuck(rowTop, restTop) {
  return rowTop - restTop > 0.5
}

export function sentinelMarksThePlace(parentDisplay) {
  return !/flex|grid/.test(parentDisplay)
}

export function hiddenEnds({ scrollLeft, clientWidth, scrollWidth }) {
  return {
    start: scrollLeft > 1,
    end: scrollLeft + clientWidth < scrollWidth - 1
  }
}

export function revealBy(box, tab, margin = 32) {
  if (tab.left < box.left) return tab.left - box.left - margin
  if (tab.right > box.right) return tab.right - box.right + margin
  return 0
}

export function menuPlacement(button, list, viewport, gap = 8) {
  const below = viewport.height - button.bottom
  const above = button.top
  const top = below < list.height + gap && above > below
    ? Math.max(gap, button.top - list.height - 4)
    : button.bottom + 4
  const left = Math.min(
    Math.max(gap, button.right - list.width),
    Math.max(gap, viewport.width - list.width - gap)
  )
  return { top, left }
}

// The bottom edge, in px, of the app's own masthead: the first header, when it is sticky
// or fixed. 0 for any other header, or none.
export function mastheadBottom(position, bottom) {
  return position === "sticky" || position === "fixed" ? Math.max(0, bottom) : 0
}

function anchorsSupported() {
  return typeof CSS !== "undefined" && !!CSS.supports &&
    CSS.supports("anchor-name: --a") && CSS.supports("position-anchor: --a")
}

function boot() {
  if (window.studioPageHeaderSelfStyled) {
    window.studioPageHeaderSelfStyled.scan()
    return
  }

  const root = document.documentElement
  let rows = []
  let frame = null
  let ownsNavBottom = null

  const publishNavBottom = () => {
    if (window.studioPinnedStack) return
    if (ownsNavBottom === null) {
      const computed = getComputedStyle(root)
      ownsNavBottom = !root.style.getPropertyValue("--nav-bottom") &&
        !computed.getPropertyValue("--nav-bottom").trim() &&
        !computed.getPropertyValue("--pin-page-top").trim()
    }
    if (!ownsNavBottom) return
    const header = document.querySelector("header")
    const bottom = header ? mastheadBottom(getComputedStyle(header).position, header.getBoundingClientRect().bottom) : 0
    const value = `${Math.round(bottom * 100) / 100}px`
    if (root.style.getPropertyValue("--nav-bottom") !== value) root.style.setProperty("--nav-bottom", value)
  }

  // The top of the row's place in the flow. In a flex or grid parent only the row can
  // say, so it is unstuck for one read; no frame paints in between.
  const restTop = ({ sentinel, row }) => {
    if (sentinelMarksThePlace(getComputedStyle(sentinel.parentElement).display)) {
      return sentinel.getBoundingClientRect().top
    }
    row.style.position = "static"
    const top = row.getBoundingClientRect().top
    row.style.position = ""
    return top
  }

  const placeMenu = (button, list) => {
    const place = menuPlacement(button.getBoundingClientRect(), list.getBoundingClientRect(),
      { width: window.innerWidth, height: window.innerHeight })
    list.style.top = `${place.top}px`
    list.style.left = `${place.left}px`
    list.style.right = "auto"
  }

  const sync = () => {
    publishNavBottom()
    rows = rows.filter((item) => item.row.isConnected)
    for (const item of rows) {
      item.row.toggleAttribute("data-stuck", isStuck(item.row.getBoundingClientRect().top, restTop(item)))
      if (!anchorsSupported()) {
        for (const { button, list } of item.menus) {
          if (list.matches(":popover-open")) placeMenu(button, list)
        }
      }
      if (!item.tabs) continue
      const ends = hiddenEnds(item.tabs)
      item.tabs.toggleAttribute("data-fade-start", ends.start)
      item.tabs.toggleAttribute("data-fade-end", ends.end)
    }
  }

  const schedule = () => {
    if (frame) return
    frame = requestAnimationFrame(() => {
      frame = null
      sync()
    })
  }

  // A disclosure, not role="menu": the popover opens, closes on Escape and gives focus
  // back with no script. This keeps aria-expanded honest and adds ArrowDown.
  const wireMenu = (menu) => {
    const button = menu.querySelector("[popovertarget]")
    const list = menu.querySelector("[popover]")
    if (!button || !list) return null
    button.setAttribute("aria-expanded", "false")
    list.addEventListener("toggle", (event) => {
      const open = event.newState === "open"
      button.setAttribute("aria-expanded", String(open))
      if (open) {
        if (!anchorsSupported()) placeMenu(button, list)
        return
      }
      if (document.activeElement === document.body || list.contains(document.activeElement)) button.focus()
    })
    button.addEventListener("keydown", (event) => {
      if (event.key !== "ArrowDown") return
      event.preventDefault()
      if (!list.matches(":popover-open")) list.showPopover?.()
      list.querySelector("a")?.focus()
    })
    return { button, list }
  }

  const wire = (sentinel) => {
    if (sentinel.hasAttribute("data-page-header-live")) return
    const row = sentinel.nextElementSibling
    if (!row || !row.classList.contains("page-header")) return
    sentinel.setAttribute("data-page-header-live", "")
    const tabs = row.querySelector(".page-header-tabs")
    const menus = [...row.querySelectorAll(".page-header-menu")].map(wireMenu).filter(Boolean)
    if (tabs) {
      tabs.addEventListener("scroll", schedule, { passive: true })
      const open = tabs.querySelector("[aria-current]")
      if (open) tabs.scrollLeft += revealBy(tabs.getBoundingClientRect(), open.getBoundingClientRect())
    }
    rows.push({ sentinel, row, tabs, menus })
  }

  const scan = () => {
    document.querySelectorAll(".page-header-sentinel").forEach(wire)
    sync()
  }

  window.studioPageHeaderSelfStyled = { scan }
  window.addEventListener("scroll", schedule, { passive: true })
  window.addEventListener("resize", schedule, { passive: true })
  document.addEventListener("turbo:load", scan)
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", scan)
  else scan()
}

if (typeof window !== "undefined" && typeof document !== "undefined") boot()
