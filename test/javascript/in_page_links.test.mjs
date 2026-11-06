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
