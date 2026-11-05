// style-section-nav: the style guide's sticky row (style/index). Its tabs follow
// the section the reader is in, by scroll and by a tab's own jump.
//
//   <nav data-studio-controller="style-section-nav">
//     <div data-style-section-nav-target="scroller">
//       <a href="#theme" data-style-section-nav-target="link">Theme</a>
//
// Registered by studio/style_guide, which only the style guide loads.
import { Controller } from "@hotwired/stimulus"
import { activeIndex } from "studio/style_section_nav"

const ACTIVE = "btn-primary"
const REST = "btn-neutral"
// A jump lands a section by its scroll-margin (--pin-section-top), read while the
// row may still be at rest and the header tall; the row then sticks and the header
// collapses, so the row rises and the section does not. The slack keeps the clicked
// section past the line, with that rise to spare, for any later scroll or resize.
const LINE_SLACK = 80

export default class extends Controller {
  static targets = ["link", "scroller"]

  connect() {
    this.schedule = this.schedule.bind(this)
    window.addEventListener("scroll", this.schedule, { passive: true })
    window.addEventListener("resize", this.schedule)
    this.sync()
  }

  disconnect() {
    window.removeEventListener("scroll", this.schedule)
    window.removeEventListener("resize", this.schedule)
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
    const links = this.linkTargets
    const tops = links.map((link) => {
      const section = document.getElementById(link.getAttribute("href").slice(1))
      return section ? section.getBoundingClientRect().top : Infinity
    })
    const line = this.element.getBoundingClientRect().bottom + LINE_SLACK
    const page = document.documentElement
    const atPageEnd = page.scrollTop > 0 && window.innerHeight + page.scrollTop >= page.scrollHeight - 2
    this.highlight(links[activeIndex(tops, line, atPageEnd)])
  }

  highlight(current) {
    if (!current || current === this.current) return
    this.current = current
    this.linkTargets.forEach((link) => {
      const on = link === current
      link.classList.toggle(ACTIVE, on)
      link.classList.toggle(REST, !on)
      if (on) link.setAttribute("aria-current", "true")
      else link.removeAttribute("aria-current")
    })
    this.reveal(current)
  }

  // Keeps the active tab in view on a narrow screen. Moves the row only:
  // scrollIntoView would also move the page the reader is scrolling.
  reveal(link) {
    if (!this.hasScrollerTarget) return
    const row = this.scrollerTarget
    const box = row.getBoundingClientRect()
    const tab = link.getBoundingClientRect()
    if (tab.left < box.left) row.scrollLeft -= box.left - tab.left + 32
    else if (tab.right > box.right) row.scrollLeft += tab.right - box.right + 32
  }
}
