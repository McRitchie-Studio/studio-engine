// [unit] studio/sign_out_prefetch: which links are a sign-out, and that the
// turbo:before-prefetch listener cancels only those. Loaded from source as a data:
// module (no document, so the module's own install is skipped).
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/sign_out_prefetch.js", import.meta.url), "utf8")
const { isSignOutLink, refuseSignOutPrefetch, SIGN_OUT_PATHS } =
  await import(`data:text/javascript,${encodeURIComponent(source)}`)

const ORIGIN = "https://app.test"
const link = (href) => ({ getAttribute: (name) => (name === "href" ? href : null) })
function prefetchOf(href) {
  return { target: link(href), defaultPrevented: false, preventDefault() { this.defaultPrevented = true } }
}

test("the sign-out paths are the engine's /logout", () => {
  assert.deepEqual([ ...SIGN_OUT_PATHS ], [ "/logout" ])
})

test("a same-origin /logout link is a sign-out, relative, absolute or with a trailing slash or query", () => {
  for (const href of [ "/logout", "/logout/", "https://app.test/logout", "/logout?x=1", "logout" ]) {
    assert.equal(isSignOutLink(link(href), ORIGIN), true, href)
  }
})

test("another page, another origin, or no href is not a sign-out", () => {
  for (const href of [ "/", "/login", "/logouts", "/admin/logout", "https://other.test/logout", "#logout", null ]) {
    assert.equal(isSignOutLink(link(href), ORIGIN), false, String(href))
  }
  assert.equal(isSignOutLink(null, ORIGIN), false)
  assert.equal(isSignOutLink({}, ORIGIN), false)
})

test("the listener cancels the prefetch of a sign-out and leaves every other prefetch", () => {
  const out = prefetchOf("/logout")
  refuseSignOutPrefetch(out, ORIGIN)
  assert.equal(out.defaultPrevented, true)

  const page = prefetchOf("/build")
  refuseSignOutPrefetch(page, ORIGIN)
  assert.equal(page.defaultPrevented, false)
})
