// [unit] studio/infinite_scroll: what the status line says, which children of a
// landed frame count as new items, which frame waits, and that a frame loads once.
// Loaded from source as a data: module, like loader.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/infinite_scroll.js", import.meta.url), "utf8")
const { announcement, newItems, waitingFrame, loadNext, sentinelOf, NEXT, MORE, NEAR_PX } =
  await import(`data:text/javascript,${encodeURIComponent(source)}`)

function el(matches = [], attrs = {}, children = [], query = {}) {
  return {
    matches: (s) => matches.includes(s),
    hasAttribute: (k) => k in attrs,
    getAttribute: (k) => (k in attrs ? attrs[k] : null),
    setAttribute: (k, v) => { attrs[k] = String(v) },
    querySelector: (s) => query[s] || null,
    children,
    attrs
  }
}

test("the status line counts what came, and says when the list is done", () => {
  assert.equal(announcement("%{count} more posts loaded", 12, false, "That is everything"), "12 more posts loaded")
  assert.equal(announcement("%{count} more posts loaded", 4, true, "That is everything"), "4 more posts loaded. That is everything")
  assert.equal(announcement(null, 3, true, ""), "3 more loaded")
})

test("a landed frame's items are its children, less the next frame and the end line", () => {
  const items = [el(), el()]
  const next = el([NEXT])
  const end = el([".studio-infinite-scroll-end"])
  assert.deepEqual(newItems({ children: [...items, next, end] }), items)
})

test("the waiting frame is the one neither loading nor loaded", () => {
  const loaded = el([], { src: "/p?page=2", complete: "" })
  const waiting = el()
  const root = { querySelectorAll: () => [loaded, waiting] }
  assert.equal(waitingFrame(root), waiting)
  assert.equal(waitingFrame({ querySelectorAll: () => [loaded] }), null)
})

test("a frame loads its link's page once", () => {
  const link = el([], { href: "/posts?page=2" })
  const frame = el([], {}, [], { [MORE]: link })
  assert.equal(loadNext(frame), true)
  assert.equal(frame.attrs.src, "/posts?page=2")
  assert.equal(loadNext(frame), false, "a second ask is no second request")
  assert.equal(loadNext(null), false)
  assert.equal(loadNext(el()), false, "no link, no load")
})

test("the observer watches the button's row, since the frame takes no box", () => {
  const row = el()
  const link = el()
  assert.equal(sentinelOf(el([], {}, [], { ".studio-infinite-scroll-more": row, [MORE]: link })), row)
  assert.equal(sentinelOf(el([], {}, [], { [MORE]: link })), link)
  assert.ok(NEAR_PX >= 300, "the next page starts well before the end shows")
})
