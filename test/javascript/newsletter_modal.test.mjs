// [unit] studio/newsletter_modal: the newsletter cards' JSON mode. What counts
// as an address, what the host's answer means, and the card's submit(): the
// hand-off to an opener's onSubmit, the JSON request, the event and hook on
// success, the step to the next card, and the error line on a failure. Loaded
// from source as a data: module, like birthday.test.mjs; it imports nothing.
//
// CONTROLS, each run against this file:
//   - drop the `typeof props.onSubmit` hand-off: "an opener's onSubmit gets the
//     address and nothing is posted" fails.
//   - read success from response.ok alone: "a 200 that says success: false is a
//     failure" fails.
//   - always close instead of swapping: "a success steps to the next card" fails.
//   - fall back to win.fetch when the named fetcher is missing: "a fetcher the
//     module does not export fails the press" fails.
//   - drop the null-response early return: "a fetcher that answers itself" fails.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/newsletter_modal.js", import.meta.url), "utf8")
const {
  INVALID_EMAIL, SUBSCRIBE_FAILED, UNSUBSCRIBE_FAILED, CHANGED_EVENT,
  HOST_FETCHERS, cleanEmail, outcomeOf, csrfToken, resolveFetcher, studioNewsletterModal
} = await import(`data:text/javascript,${encodeURIComponent(source)}`)

// A window with one store, a fetch that answers as told, and a record of
// everything the card did.
function harness({ status = 200, body = { success: true }, props = {}, throws = false, notJson = false } = {}) {
  const log = { requests: [], events: [], closes: 0, swaps: [], errors: [] }
  const store = {
    current: () => ({ id: "card", props }),
    close: () => { log.closes += 1 },
    swap: (id, p) => { log.swaps.push([id, p]) }
  }
  class CustomEvent { constructor(type, init) { this.type = type; this.detail = init && init.detail } }
  const win = {
    Alpine: { store: (name) => (name === "modals" || name === "hostModals" ? store : undefined) },
    CustomEvent,
    dispatchEvent: (e) => { log.events.push(e) },
    console: { error: (m) => { log.errors.push(m) } },
    document: { querySelector: (sel) => (sel === 'meta[name="csrf-token"]' ? { content: "tok" } : null) },
    fetch: async (url, init) => {
      log.requests.push({ url, init })
      if (throws) throw new Error("offline")
      return {
        ok: status >= 200 && status < 300,
        status,
        json: async () => { if (notJson) throw new SyntaxError("html"); return body }
      }
    }
  }
  return { win, log }
}

test("the module imports nothing, so the head can load it by its own tag", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

test("an address needs something before its @", () => {
  assert.equal(cleanEmail("  pat@example.com "), "pat@example.com")
  for (const bad of ["", "   ", "pat", "@example.com", null, undefined]) {
    assert.equal(cleanEmail(bad), "", `${String(bad)} is not an address`)
  }
})

test("a 2xx is a success unless its body says success: false", () => {
  assert.equal(outcomeOf({ ok: true }, { success: true }, "x").ok, true)
  assert.equal(outcomeOf({ ok: true }, {}, "x").ok, true, "a host that sends no success key still succeeded")
  assert.equal(outcomeOf({ ok: true }, null, "x").ok, true)
  assert.equal(outcomeOf({ ok: true, redirected: true }, {}, "Fallback.").error, "Fallback.", "a 200 reached by a redirect (a sign-in page) is not a join")

  const said = outcomeOf({ ok: true }, { success: false, error: "Already on it." }, "x")
  assert.deepEqual([said.ok, said.error], [false, "Already on it."])

  const server = outcomeOf({ ok: false }, {}, "Fallback.")
  assert.deepEqual([server.ok, server.error], [false, "Fallback."])
})

test("the CSRF token comes from the page's meta tag, and a page without one sends none", () => {
  assert.equal(csrfToken({ querySelector: () => ({ content: "abc" }) }), "abc")
  assert.equal(csrfToken({ querySelector: () => null }), "")
  assert.equal(csrfToken(undefined), "")
})

test("a subscribe posts JSON to the host's url, dispatches the event, and closes", async () => {
  const { win, log } = harness({ body: { success: true, seeds_earned: 25 } })
  const card = studioNewsletterModal({ action: "subscribe", url: "/newsletter/subscribe" }, { win })
  await card.submit()

  assert.equal(log.requests.length, 1)
  const { url, init } = log.requests[0]
  assert.equal(url, "/newsletter/subscribe")
  assert.equal(init.method, "POST")
  assert.equal(init.headers["Content-Type"], "application/json")
  assert.equal(init.headers["X-CSRF-Token"], "tok")
  assert.deepEqual(JSON.parse(init.body), { email: null }, "an account with an address on file sends none")

  assert.equal(log.events.length, 1)
  assert.equal(log.events[0].type, CHANGED_EVENT)
  assert.deepEqual(log.events[0].detail, { subscribed: true, email: null, response: { success: true, seeds_earned: 25 } })
  assert.equal(log.closes, 1)
  assert.equal(card.saving, false)
})

test("a success steps to the next card, carrying the host's answer as its props", async () => {
  const { win, log } = harness({ body: { success: true, seeds_earned: 25 } })
  const card = studioNewsletterModal({ url: "/s", nextId: "newsletter-success" }, { win })
  await card.submit()
  assert.deepEqual(log.swaps, [["newsletter-success", { success: true, seeds_earned: 25 }]])
  assert.equal(log.closes, 0)
})

test("the event is the host's when it names one, and the opener's onSuccess hears the answer", async () => {
  const heard = []
  const { win, log } = harness({ props: { onSuccess: (b) => heard.push(b) } })
  const card = studioNewsletterModal({ url: "/s", event: "newsletter-state-changed" }, { win })
  await card.submit()
  assert.equal(log.events[0].type, "newsletter-state-changed")
  assert.deepEqual(heard, [{ success: true }])
})

test("an unsubscribe sends no body, uses the verb it was given, and reports subscribed: false", async () => {
  const { win, log } = harness()
  const card = studioNewsletterModal({ action: "unsubscribe", url: "/u", method: "delete", nextId: "newsletter-goodbye" }, { win })
  await card.submit()
  assert.equal(log.requests[0].init.method, "DELETE")
  assert.equal(log.requests[0].init.body, undefined)
  assert.equal(log.events[0].detail.subscribed, false)
  assert.deepEqual(log.swaps.map(([id]) => id), ["newsletter-goodbye"])
})

test("an opener's onSubmit gets the address and nothing is posted", async () => {
  const handed = []
  const { win, log } = harness({ props: { onSubmit: (e) => handed.push(e) } })
  const card = studioNewsletterModal({ url: "/s", needsEmail: true }, { win })
  card.email = " pat@example.com "
  await card.submit()
  assert.deepEqual(handed, ["pat@example.com"])
  assert.equal(log.requests.length, 0)
  assert.equal(log.closes, 1, "the card closes before the opener takes over")
  assert.equal(log.events.length, 0, "the opener's request, not this card, says when it succeeded")
})

test("an unsubscribe never hands off, even when the opener passed onSubmit", async () => {
  const { win, log } = harness({ props: { onSubmit: () => assert.fail("handed off an unsubscribe") } })
  await studioNewsletterModal({ action: "unsubscribe", url: "/u" }, { win }).submit()
  assert.equal(log.requests.length, 1)
})

test("an address that cannot be one stays on the card with its error line", async () => {
  const { win, log } = harness()
  const card = studioNewsletterModal({ url: "/s", needsEmail: true }, { win })
  card.email = "pat"
  await card.submit()
  assert.equal(card.error, INVALID_EMAIL)
  assert.equal(log.requests.length, 0)

  card.email = "pat@example.com"
  await card.submit()
  assert.equal(card.error, "", "a good address clears the line")
  assert.deepEqual(JSON.parse(log.requests[0].init.body), { email: "pat@example.com" })
})

test("an unticked consent box sends nothing", async () => {
  const { win, log } = harness()
  const card = studioNewsletterModal({ url: "/s", requiresConsent: true }, { win })
  assert.equal(card.consent, true, "the box starts ticked")
  card.consent = false
  assert.equal(card.ready, false)
  await card.submit()
  assert.equal(log.requests.length, 0)
})

test("a 200 that says success: false is a failure, shown in the host's words", async () => {
  const { win, log } = harness({ body: { success: false, error: "That address bounced." } })
  const card = studioNewsletterModal({ url: "/s", nextId: "next" }, { win })
  await card.submit()
  assert.equal(card.error, "That address bounced.")
  assert.equal(card.saving, false, "the button comes back")
  assert.deepEqual([log.events.length, log.closes, log.swaps.length], [0, 0, 0])
})

test("a server error, a body that is not JSON, and no network each leave the plain line", async () => {
  for (const [opts, action, line] of [
    [{ status: 500, body: {} }, "subscribe", SUBSCRIBE_FAILED],
    [{ status: 502, notJson: true }, "unsubscribe", UNSUBSCRIBE_FAILED],
    [{ throws: true }, "subscribe", SUBSCRIBE_FAILED]
  ]) {
    const { win, log } = harness(opts)
    const card = studioNewsletterModal({ action, url: "/x" }, { win })
    await card.submit()
    assert.equal(card.error, line)
    assert.equal(card.saving, false)
    assert.equal(log.closes, 0)
  }
})

test("a second press while the first is in flight sends nothing more", async () => {
  const { win, log } = harness()
  const card = studioNewsletterModal({ url: "/s" }, { win })
  const first = card.submit()
  assert.equal(card.saving, true)
  await card.submit()
  await first
  assert.equal(log.requests.length, 1)
})

test("the card closes the store it was given", async () => {
  const { win, log } = harness()
  await studioNewsletterModal({ url: "/s", store: "hostModals" }, { win }).submit()
  assert.equal(log.closes, 1)
  const missing = studioNewsletterModal({ url: "/s", store: "nowhere" }, { win })
  assert.deepEqual(missing.props, {}, "no such store reads as no props, not a throw")
})

// --- the host's fetcher (studio/host_fetchers) --------------------------------

test("the engine's studio/host_fetchers is an empty seam that imports nothing", async () => {
  const seam = readFileSync(new URL("../../app/javascript/studio/host_fetchers.js", import.meta.url), "utf8")
  assert.doesNotMatch(seam, /^\s*import\s/m)
  const mod = await import(`data:text/javascript,${encodeURIComponent(seam)}`)
  assert.deepEqual(Object.keys(mod), [])
  assert.equal(HOST_FETCHERS, "studio/host_fetchers")
  assert.match(source, /import\("studio\/host_fetchers"\)/, "the default importer loads the seam by its pinned name")
})

test("resolveFetcher finds a named function export, and nothing else", async () => {
  const fn = async () => {}
  const importer = async () => ({ authedFetch: fn, notAFunction: 3 })
  assert.equal(await resolveFetcher("authedFetch", importer), fn)
  assert.equal(await resolveFetcher("notAFunction", importer), null)
  assert.equal(await resolveFetcher("missing", importer), null)
  assert.equal(await resolveFetcher("", importer), null)
  assert.equal(await resolveFetcher("a.b", importer), null, "a name that is not an identifier is never looked up")
  assert.equal(await resolveFetcher("authedFetch", async () => { throw new Error("404") }), null)
})

test("a named fetcher carries the request, and plain fetch is not called", async () => {
  const { win, log } = harness()
  const hostCalls = []
  const importer = async () => ({
    authedFetch: async (url, init) => {
      hostCalls.push({ url, init })
      return { ok: true, status: 200, json: async () => ({ success: true }) }
    }
  })
  const card = studioNewsletterModal({ url: "/s", fetcher: "authedFetch" }, { win, importer })
  await card.submit()
  assert.equal(hostCalls.length, 1)
  assert.equal(hostCalls[0].url, "/s")
  assert.equal(hostCalls[0].init.headers["X-CSRF-Token"], "tok", "the host's fetcher gets the same request")
  assert.equal(log.requests.length, 0, "plain fetch was not used")
  assert.equal(log.closes, 1)
})

test("a fetcher that answers itself (null) stops the spinner and shows nothing", async () => {
  const { win, log } = harness()
  const importer = async () => ({ authedFetch: async () => null })
  const card = studioNewsletterModal({ url: "/s", fetcher: "authedFetch", nextId: "next" }, { win, importer })
  await card.submit()
  assert.equal(card.saving, false)
  assert.equal(card.error, "", "the host's own card speaks; this one says nothing")
  assert.deepEqual([log.events.length, log.closes, log.swaps.length], [0, 0, 0])
})

test("a fetcher the module does not export fails the press, loudly, and never falls back", async () => {
  const { win, log } = harness()
  const card = studioNewsletterModal({ url: "/s", fetcher: "authedFetch" }, { win, importer: async () => ({}) })
  await card.submit()
  assert.equal(card.error, SUBSCRIBE_FAILED)
  assert.equal(card.saving, false)
  assert.equal(log.requests.length, 0, "plain fetch would drop the host's 401 handling")
  assert.equal(log.errors.length, 1)
  assert.match(log.errors[0], /authedFetch/)
})

test("with no fetcher named, the seam is never imported", async () => {
  const { win, log } = harness()
  const card = studioNewsletterModal({ url: "/s" }, { win, importer: async () => assert.fail("imported the seam") })
  await card.submit()
  assert.equal(log.requests.length, 1)
})
