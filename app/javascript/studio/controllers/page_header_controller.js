// page-header: says when components/_page_header is stuck, marks which ends of its
// tabs hide a tab, and shows the open tab on a narrow screen. It sits on the row's
// sentinel, so the row keeps its data-studio-controller for the page's own.
//
//   <div class="page-header-sentinel" data-studio-controller="page-header"></div>
//   <nav class="page-header sticky" data-pin="page">...</nav>
//
// A lazy controller (studio/stimulus): only a page with the row fetches it. The
// row's tabs are links, so they work without it. If it fails to load, the sentinel
// carries data-studio-controller-failed and engine.css gives the row its bar at
// all times, so a stuck row never lays a transparent title over the page.
import { Controller } from "@hotwired/stimulus"
import { hiddenEnds, isStuck, revealBy } from "studio/page_header"

export default class extends Controller {
  connect() {
    this.row = this.element.nextElementSibling
    if (!this.row) return
    this.tabs = this.row.querySelector(".page-header-tabs")
    this.schedule = this.schedule.bind(this)
    window.addEventListener("scroll", this.schedule, { passive: true })
    window.addEventListener("resize", this.schedule, { passive: true })
    this.tabs?.addEventListener("scroll", this.schedule, { passive: true })
    this.revealOpenTab()
    this.sync()
  }

  disconnect() {
    window.removeEventListener("scroll", this.schedule)
    window.removeEventListener("resize", this.schedule)
    this.tabs?.removeEventListener("scroll", this.schedule)
    if (this.frame) cancelAnimationFrame(this.frame)
    this.frame = null
  }

  schedule() {
    if (this.frame) return
    this.frame = requestAnimationFrame(() => {
      this.frame = null
      this.sync()
    })
  }

  sync() {
    const stuck = isStuck(this.row.getBoundingClientRect().top, this.element.getBoundingClientRect().top)
    const ends = this.tabs ? hiddenEnds(this.tabs) : null

    this.row.toggleAttribute("data-stuck", stuck)
    if (!ends) return
    this.tabs.toggleAttribute("data-fade-start", ends.start)
    this.tabs.toggleAttribute("data-fade-end", ends.end)
  }

  // Moves the tabs only: scrollIntoView would also move the page.
  revealOpenTab() {
    const open = this.tabs?.querySelector("[aria-current]")
    if (!open) return
    this.tabs.scrollLeft += revealBy(this.tabs.getBoundingClientRect(), open.getBoundingClientRect())
  }
}
