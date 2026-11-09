// [unit] studio/in_page_links: which clicks are a scroll down the page and which are left
// for Turbo or the browser. Loaded from source as a data: module (no document, so the
// module's own install is skipped).
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/in_page_links.js", import.meta.url), "utf8")
const {
  samePageFragment, plainClick, linkOptsOut, findTarget, inPageTarget, pushedState, samePagePop, marginFor, STATE_KEY,
} = await import(`data:text/javascript,${encodeURIComponent(source)}`)

const HERE = "https://app.test/admin/style?tab=1"

function fakeLink(attrs = {}, ancestors = []) {
  return {
    getAttribute: (name) => (name in attrs ? attrs[name] : null),
    hasAttribute: (name) => name in attrs,
    closest: (selector) => {
      const name = selector.slice(1, -1)
      if (name in attrs) return fakeLink(attrs)
      return ancestors.find((el) => el.hasAttribute(name)) || null
    },
  }
}
const click = (over = {}) => ({ button: 0, defaultPrevented: false, metaKey: false, ctrlKey: false, shiftKey: false, altKey: false, ...over })
function fakeDoc(ids = {}, named = {}) {
  return {
    getElementById: (id) => ids[id] || null,
    getElementsByName: (name) => named[name] || [],
  }
}

test("a bare fragment, or the page's own address with one, is this page", () => {
  assert.equal(samePageFragment("#tricks", HERE), "tricks")
  assert.equal(samePageFragment("/admin/style?tab=1#tricks", HERE), "tricks")
  assert.equal(samePageFragment("https://app.test/admin/style?tab=1#tricks", HERE), "tricks")
  assert.equal(samePageFragment("?tab=1#tricks", HERE), "tricks")
})

test("a fragment is decoded, as the browser looks it up", () => {
  assert.equal(samePageFragment("#caf%C3%A9", HERE), "café")
  assert.equal(samePageFragment("#100%", HERE), "100%")
})

test("another path, query or origin is a page change, not a scroll", () => {
  assert.equal(samePageFragment("/admin/models#tricks", HERE), null)
  assert.equal(samePageFragment("/admin/style#tricks", HERE), null, "the query differs")
  assert.equal(samePageFragment("/admin/style?tab=2#tricks", HERE), null)
  assert.equal(samePageFragment("https://other.test/admin/style?tab=1#tricks", HERE), null)
})

test("a link with no fragment, or an empty one, is not an in-page jump", () => {
  assert.equal(samePageFragment("/admin/style?tab=1", HERE), null, "a reload of this page")
  assert.equal(samePageFragment("#", HERE), null)
  assert.equal(samePageFragment("", HERE), null)
  assert.equal(samePageFragment(null, HERE), null)
  assert.equal(samePageFragment("#x", null), null)
})

test("only a plain main-button click counts", () => {
  assert.equal(plainClick(click()), true)
  for (const key of ["metaKey", "ctrlKey", "shiftKey", "altKey"]) {
    assert.equal(plainClick(click({ [key]: true })), false, key)
  }
  assert.equal(plainClick(click({ button: 1 })), false, "the middle button opens a tab")
  assert.equal(plainClick(click({ defaultPrevented: true })), false, "a component already took it")
  assert.equal(plainClick(null), false)
})

test("a link that asks for another window, a download or no Turbo is left alone", () => {
  assert.equal(linkOptsOut(fakeLink({ href: "#a" })), false)
  assert.equal(linkOptsOut(fakeLink({ href: "#a", target: "_self" })), false)
  assert.equal(linkOptsOut(fakeLink({ href: "#a", target: "_blank" })), true)
  assert.equal(linkOptsOut(fakeLink({ href: "#a", target: "preview" })), true)
  assert.equal(linkOptsOut(fakeLink({ href: "#a", download: "" })), true)
  assert.equal(linkOptsOut(fakeLink({ href: "#a", "data-turbo": "false" })), true)
  assert.equal(linkOptsOut(fakeLink({ href: "#a", "data-turbo": "true" })), false)
  assert.equal(linkOptsOut(fakeLink({ href: "#a", "data-turbo-method": "delete" })), true)
  assert.equal(linkOptsOut(fakeLink({ href: "#a", "data-method": "post" })), true)
  assert.equal(linkOptsOut(fakeLink({ href: "#a", "data-turbo-stream": "" })), true)
  assert.equal(linkOptsOut(fakeLink({ href: "#a", "data-turbo-frame": "panel" })), true)
  assert.equal(linkOptsOut(fakeLink({ href: "#a", "data-turbo-frame": "_top" })), false)
})

test("data-turbo=false on an ancestor leaves the link alone too", () => {
  const off = fakeLink({ "data-turbo": "false" })
  assert.equal(linkOptsOut(fakeLink({ href: "#a" }, [off])), true)
  const on = fakeLink({ "data-turbo": "true" })
  assert.equal(linkOptsOut(fakeLink({ href: "#a" }, [on])), false)
})

test("the target is the element with the id, else an <a name>, else none", () => {
  const section = { tagName: "SECTION" }
  const anchor = { tagName: "A" }
  const input = { tagName: "INPUT" }
  const doc = fakeDoc({ tricks: section }, { old: [input, anchor], field: [input] })
  assert.equal(findTarget(doc, "tricks"), section)
  assert.equal(findTarget(doc, "old"), anchor)
  assert.equal(findTarget(doc, "field"), null, "a form field's name is not a fragment target")
  assert.equal(findTarget(doc, "missing"), null)
  assert.equal(findTarget(doc, null), null)
})

test("the decision: a plain click on a link to an element on this page", () => {
  const section = { tagName: "SECTION" }
  const doc = fakeDoc({ tricks: section })
  assert.equal(inPageTarget(click(), fakeLink({ href: "#tricks" }), doc, HERE), section)
  assert.equal(inPageTarget(click(), fakeLink({ href: "#nowhere" }), doc, HERE), null, "no element: the browser's call")
  assert.equal(inPageTarget(click(), fakeLink({ href: "/elsewhere#tricks" }), doc, HERE), null, "a page change")
  assert.equal(inPageTarget(click({ metaKey: true }), fakeLink({ href: "#tricks" }), doc, HERE), null)
  assert.equal(inPageTarget(click(), fakeLink({ href: "#tricks", target: "_blank" }), doc, HERE), null)
  assert.equal(inPageTarget(click(), fakeLink({ href: "#tricks", "data-turbo": "false" }), doc, HERE), null)
  assert.equal(inPageTarget(click(), null, doc, HERE), null, "a click off any link")
})

test("a pushed entry keeps Turbo's restoration id and moves its index one on", () => {
  const state = pushedState({ turbo: { restorationIdentifier: "r1", restorationIndex: 3 } })
  assert.deepEqual(state, { turbo: { restorationIdentifier: "r1", restorationIndex: 4 }, [STATE_KEY]: {} })
  assert.deepEqual(pushedState(null), { [STATE_KEY]: {} }, "no Turbo: the module's own mark only")
})

test("a popstate is this page's own only between entries of the page on screen", () => {
  const a = "https://app.test/admin/style#tricks"
  const b = "https://app.test/admin/style"
  const turbo = (id) => ({ turbo: { restorationIdentifier: id, restorationIndex: 1 } })
  assert.equal(samePagePop(turbo("r1"), "r1", b, a), true, "Back to the top of the same page")
  assert.equal(samePagePop(turbo("r0"), "r1", b, a), false, "another restoration id is another render: Turbo's")
  assert.equal(samePagePop(turbo("r1"), "r1", "https://app.test/admin/models", a), false, "another page")
  assert.equal(samePagePop(null, "r1", b, a), false, "an entry Turbo never wrote")
  assert.equal(samePagePop({ [STATE_KEY]: { scrollY: 40 } }, null, b, a), true, "no Turbo: the module's own entry")
})

test("a target's own scroll margin wins; else it stops under the pinned stack", () => {
  assert.equal(marginFor(120, 90), null, "section-target already knows the stack")
  assert.equal(marginFor(0, 90.4), 90)
  assert.equal(marginFor(0, 0), null, "no stack, no margin")
})

// THE JUMP'S END, on a slow main thread. A fake window with its own clock: a smooth scroll
// whose frames come further apart than SETTLE_MS (a phone, or CI at 8x CPU) must not end
// before the browser's scrollend. Measured red at 8x before the fix: the quiet spell ended
// the jump at its first frame, the target then moved and nothing aimed again.
function fakeWindow({ scrollend }) {
  const timers = new Map()
  let now = 0
  let next = 1
  const listeners = {}
  const docListeners = {}
  const dispatched = []
  const scrolledBy = []
  const on = (bag) => (name, fn) => { (bag[name] ||= []).push(fn) }
  const off = (bag) => (name, fn) => { bag[name] = (bag[name] || []).filter((f) => f !== fn) }
  let top = 900
  const target = {
    style: {},
    matches: () => true,
    focus: () => {},
    setAttribute: () => {},
    addEventListener: () => {},
    getBoundingClientRect: () => ({ top }),
    scrollIntoView: () => {},
  }
  const link = { getAttribute: (n) => (n === "href" ? "#tricks" : null), hasAttribute: () => false, closest: () => null, dispatchEvent: () => {} }
  const win = {
    scrollY: 0,
    location: { href: "https://app.test/admin/style" },
    history: { state: null, replaceState() {}, pushState(_s, _t, href) { win.location.href = href } },
    matchMedia: () => ({ matches: false }),
    getComputedStyle: () => ({ scrollMarginTop: "100px" }),
    setTimeout: (fn, ms) => { const id = next++; timers.set(id, { fn, at: now + ms }); return id },
    clearTimeout: (id) => { timers.delete(id) },
    // A frame every 16ms. A scroll's event comes in a later task, as a browser sends it.
    requestAnimationFrame: (fn) => win.setTimeout(fn, 16),
    cancelAnimationFrame: (id) => win.clearTimeout(id),
    scrollBy: ({ top: dy }) => {
      win.scrollY += dy
      top -= dy
      scrolledBy.push(dy)
      win.setTimeout(() => fire(listeners, "scroll"), 0)
    },
    addEventListener: on(listeners),
    removeEventListener: off(listeners),
    dispatchEvent: () => {},
    CustomEvent: class { constructor(type) { this.type = type } },
    HashChangeEvent: class { constructor(type) { this.type = type } },
  }
  if (scrollend) win.onscrollend = null
  const doc = {
    defaultView: win,
    getElementById: (id) => (id === "tricks" ? target : null),
    getElementsByName: () => [],
    addEventListener: on(docListeners),
    dispatchEvent: (event) => { dispatched.push(event.type) },
  }
  const fire = (bag, name, event = {}) => { for (const fn of [...(bag[name] || [])]) fn(event) }
  const advance = (ms) => {
    const until = now + ms
    for (;;) {
      const due = [...timers.entries()].filter(([, t]) => t.at <= until).sort((a, b) => a[1].at - b[1].at)[0]
      if (!due) break
      timers.delete(due[0])
      now = due[1].at
      due[1].fn()
    }
    now = until
  }
  return {
    doc,
    ends: () => dispatched.filter((type) => type === "studio:in-page-scroll-end").length,
    click: () => fire(docListeners, "click", { ...click(), target: { closest: () => link }, preventDefault() {} }),
    frame: (dy) => { win.scrollY += dy; top -= dy; fire(listeners, "scroll") },
    scrollend: () => fire(listeners, "scrollend"),
    // Content above the target grows by dy: the target moves down, scrollY stays (no anchoring).
    grow: (dy) => { top += dy },
    input: (name) => fire(listeners, name),
    top: () => top,
    scrolledBy,
    advance,
  }
}
// installInPageLinks keeps one install per module, so each case loads its own copy.
const freshInstall = async (tag) => (await import(`data:text/javascript,${encodeURIComponent(`${source}\n// ${tag}`)}`)).installInPageLinks

test("with scrollend, a slow frame does not end the jump; the browser's scrollend does", async () => {
  const install = await freshInstall("slow-frames")
  const page = fakeWindow({ scrollend: true })
  assert.equal(install(page.doc), true)
  page.click()
  page.frame(100)
  page.advance(260) // one frame at 8x CPU: longer than SETTLE_MS
  page.frame(300)
  page.advance(260)
  assert.equal(page.ends(), 0, "still scrolling: no end yet")
  page.scrollend()
  assert.equal(page.ends(), 1, "the browser's scrollend ends it")
})

test("without scrollend, a quiet spell of SETTLE_MS ends the jump", async () => {
  const { SETTLE_MS } = await import(`data:text/javascript,${encodeURIComponent(source)}`)
  const install = await freshInstall("no-scrollend")
  const page = fakeWindow({ scrollend: false })
  assert.equal(install(page.doc), true)
  page.click()
  page.frame(100)
  page.advance(SETTLE_MS - 1)
  assert.equal(page.ends(), 0)
  page.advance(1)
  assert.equal(page.ends(), 1)
})

test("a jump that never scrolls still ends at its cap, with scrollend or without", async () => {
  const { START_CAP_MS } = await import(`data:text/javascript,${encodeURIComponent(source)}`)
  for (const scrollend of [true, false]) {
    const install = await freshInstall(`never-moves-${scrollend}`)
    const page = fakeWindow({ scrollend })
    install(page.doc)
    page.click()
    page.advance(START_CAP_MS)
    assert.equal(page.ends(), 1, `scrollend ${scrollend}`)
  }
})

test("with scrollend, a scroll that scrollend never follows ends at the backstop, START_CAP_MS after its last scroll", async () => {
  const { START_CAP_MS } = await import(`data:text/javascript,${encodeURIComponent(source)}`)
  const install = await freshInstall("no-scrollend-after-scroll")
  const page = fakeWindow({ scrollend: true })
  install(page.doc)
  page.click()
  // A page that shortens: the browser pulls the scroll back, one scroll event, no scrollend.
  page.frame(-40)
  page.advance(START_CAP_MS - 1)
  assert.equal(page.ends(), 0, "a frame shorter than the backstop is still the scroll")
  page.advance(1)
  assert.equal(page.ends(), 1, "the backstop ends it")
})

// THE HOLD AFTER THE END (engine-anchor-late-growth). A lazy frame above the target lands
// after the jump's end. With anchoring off, scrollY stays and the target slides down.
async function landedJump(tag) {
  const install = await freshInstall(tag)
  const page = fakeWindow({ scrollend: true })
  install(page.doc)
  page.click()
  page.frame(800)
  page.scrollend()
  assert.equal(page.ends(), 1)
  return page
}

test("after the end, growth above the target moves the page with it, and the target keeps its place", async () => {
  const page = await landedJump("hold-follows")
  const place = page.top()
  page.advance(500)
  page.grow(88)
  page.advance(32)
  assert.deepEqual(page.scrolledBy, [88], "one move, by the growth")
  assert.equal(page.top(), place, "the target is where the jump left it")
  page.advance(500)
  page.grow(40)
  page.advance(32)
  assert.deepEqual(page.scrolledBy, [88, 40], "its own scroll did not end the hold")
})

test("the hold ends at HOLD_MS: growth after it is the reader's page, not the jump's", async () => {
  const { HOLD_MS } = await import(`data:text/javascript,${encodeURIComponent(source)}`)
  const page = await landedJump("hold-window")
  page.advance(HOLD_MS)
  page.grow(88)
  page.advance(100)
  assert.deepEqual(page.scrolledBy, [])
})

test("the reader's scroll or input after the end lets go: growth then moves nothing", async () => {
  for (const how of ["scroll", "wheel", "touchstart", "keydown", "pointerdown"]) {
    const page = await landedJump(`hold-release-${how}`)
    page.advance(100)
    if (how === "scroll") page.frame(-300)
    else page.input(how)
    page.grow(88)
    page.advance(100)
    assert.deepEqual(page.scrolledBy, [], how)
  }
})

test("a jump the reader took over holds nothing after it", async () => {
  const install = await freshInstall("reader-no-hold")
  const page = fakeWindow({ scrollend: true })
  install(page.doc)
  page.click()
  page.frame(300)
  page.input("wheel")
  page.scrollend()
  page.grow(88)
  page.advance(100)
  assert.deepEqual(page.scrolledBy, [])
})

// A STALE SCROLLEND. Measured at 8x CPU on a phone (section_header, red 3 in 10): the feed
// landed in the scroll's last frame, the jump aimed again, and Chrome sent the first scroll's
// scrollend before the new scroll's first frame. That scrollend ended the jump 88px short;
// the new scroll then moved the page, so the hold let go too.
test("after an aim, a scrollend before that aim's first scroll does not end the jump", async () => {
  const install = await freshInstall("stale-scrollend")
  const page = fakeWindow({ scrollend: true })
  install(page.doc)
  page.click()
  page.frame(800)
  page.grow(88)
  page.frame(0) // the scroll's last frame: the target moved, so the jump aims again
  page.scrollend() // the first scroll's end, before the new aim has scrolled
  assert.equal(page.ends(), 0, "the aim's scroll is still to come")
  page.frame(88)
  page.scrollend()
  assert.equal(page.ends(), 1, "the aim's own scrollend ends it")
})
