// [unit] studio/leveling_activity: when the action can run, what a save does
// with each answer, who drives what follows it, and the second step. Loaded
// from source as a data: module, like local_path.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/leveling_activity.js", import.meta.url), "utf8")
const { DEFAULT_SAVED_EVENT, actionable, responseStatus, demoSeeds, levelingActionModal } =
  await import(`data:text/javascript,${encodeURIComponent(source)}`)

const settle = () => new Promise((resolve) => setImmediate(resolve))
const answer = (status, body) => ({ ok: status >= 200 && status < 300, json: () => Promise.resolve(body) })

// A page: the modal store with one open modal, a fetch that records, and the
// window events the scope dispatches.
function page({ props, fetch, authedFetch } = {}) {
  const current = props === undefined ? null : { props }
  const requests = []
  const dispatched = []
  const win = {
    requests, dispatched, current,
    Alpine: { store: (name) => (name === "modals" || name === "dsModals" ? { current: () => current } : null) },
    CustomEvent: function (type, init) { this.type = type; this.detail = init.detail },
    dispatchEvent(event) { dispatched.push(event) },
    fetch: (url, options) => { requests.push({ url, options, body: JSON.parse(options.body) }); return fetch(url, options) }
  }
  if (authedFetch) win.authedFetch = authedFetch
  const doc = { querySelector: () => ({ content: "csrf-token-1" }) }
  return { win, doc }
}

test("an input activity runs on a real change of at least the minimum length", () => {
  const input = { hasInput: true, original: "picker", minLength: 3, saved: false }
  assert.equal(actionable({ ...input, value: "picker" }), false, "unchanged")
  assert.equal(actionable({ ...input, value: "  picker  " }), false, "whitespace is not a change")
  assert.equal(actionable({ ...input, value: "pi" }), false, "under the minimum")
  assert.equal(actionable({ ...input, value: "picked" }), true)
  assert.equal(actionable({ ...input, value: null }), false)
})

test("a plain action runs once, and an unticked consent box gates either kind", () => {
  assert.equal(actionable({ hasInput: false, saved: false }), true)
  assert.equal(actionable({ hasInput: false, saved: true }), false)
  assert.equal(actionable({ hasInput: false, saved: false, hasConsent: true, consent: false }), false)
  assert.equal(actionable({ hasInput: false, saved: false, hasConsent: true, consent: true }), true)
})

test("a response's status is the body's own, or saved for a 2xx that names none", () => {
  assert.equal(responseStatus({ ok: true, body: { status: "needs_step" } }), "needs_step")
  assert.equal(responseStatus({ ok: true, body: {} }), "saved")
  assert.equal(responseStatus({ ok: false, body: {} }), "error")
  assert.equal(responseStatus(null), "error")
})

test("the demo's seeds default to a pair that crosses a level", () => {
  assert.deepEqual(demoSeeds(NaN, NaN, 100), { seeds_earned: 30, seeds_total: 100 })
  assert.deepEqual(demoSeeds(25, 25, 100), { seeds_earned: 25, seeds_total: 25 })
})

test("leveling is read from the open modal's props, and falls back to the rendered default", () => {
  const env = page({ props: {} })
  const modal = levelingActionModal({ leveling: true }, env)
  assert.equal(modal.leveling, true, "props do not say: the default stands")
  env.win.current.props.leveling = false
  assert.equal(modal.leveling, false, "the toggle moved")
  assert.equal(levelingActionModal({ leveling: false }, page()).leveling, false, "no modal is open")
  assert.equal(levelingActionModal({ store: "dsModals" }, page({ props: { leveling: true } })).leveling, true)
})

test("props.celebrate opens the modal at the updated state", () => {
  const modal = levelingActionModal({}, page({ props: { celebrate: true, seedsEarned: "25", seedsTotal: "125" } }))
  modal.init()
  assert.deepEqual([modal.saved, modal.celebrate, modal.seedsEarned, modal.seedsTotal], [true, true, 25, 125])

  const fresh = levelingActionModal({}, page({ props: {} }))
  fresh.init()
  assert.deepEqual([fresh.saved, fresh.celebrate], [false, false])
})

test("a save on the default event posts the trimmed value and advances to the celebration", async () => {
  const env = page({ props: {}, fetch: () => Promise.resolve(answer(200, { status: "saved", seeds_earned: 30, seeds_total: 130 })) })
  const modal = levelingActionModal({ hasInput: true, initialValue: "picker", submitUrl: "/account/username" }, env)
  modal.value = "  picked "

  modal.save()
  assert.equal(modal.saving, true)
  await settle()

  assert.equal(env.win.requests[0].url, "/account/username")
  assert.equal(env.win.requests[0].options.method, "POST")
  assert.equal(env.win.requests[0].options.headers["X-CSRF-Token"], "csrf-token-1")
  assert.deepEqual(env.win.requests[0].body, { value: "picked" })
  assert.deepEqual([modal.saving, modal.saved, modal.celebrate, modal.seedsEarned, modal.seedsTotal], [false, true, true, 30, 130])
  assert.equal(modal.original, "picked", "the saved value is the new baseline")
  assert.equal(modal.changed, false)
  assert.equal(env.win.current.props.celebrate, true, "the open modal's props follow, for the style guide's glow")
  assert.deepEqual(env.win.dispatched.map((event) => event.type), [DEFAULT_SAVED_EVENT])
})

test("a caller with its own saved event gets the event and no engine celebration", async () => {
  const env = page({ props: {}, fetch: () => Promise.resolve(answer(200, { status: "saved", seeds_earned: 30 })) })
  const modal = levelingActionModal({ submitUrl: "/quest", savedEvent: "studio:username-saved" }, env)
  assert.equal(modal.appDrivenFollowOn, true)

  modal.save()
  await settle()

  assert.equal(env.win.dispatched[0].type, "studio:username-saved")
  assert.deepEqual(env.win.dispatched[0].detail, { status: "saved", seeds_earned: 30 })
  assert.deepEqual([modal.saved, modal.celebrate, modal.seedsEarned], [true, false, 0])
  assert.equal(env.win.current.props.celebrate, undefined)
  assert.deepEqual(env.win.requests[0].body, {}, "a plain action posts no value")
})

test("a demo is never app-driven, posts nothing and dispatches nothing", async () => {
  const env = page({ props: {}, fetch: () => { throw new Error("a demo sends no request") } })
  const modal = levelingActionModal({ demo: true, savedEvent: "studio:username-saved", demoSeedsEarned: 25, demoSeedsTotal: 25 }, env)
  assert.equal(modal.appDrivenFollowOn, false)

  modal.save()
  await new Promise((resolve) => setTimeout(resolve, 650))

  assert.deepEqual([modal.saved, modal.celebrate, modal.seedsEarned, modal.seedsTotal], [true, true, 25, 25])
  assert.deepEqual(env.win.dispatched, [])
})

test("an error answer shows its message, and a failed request the error's", async () => {
  const refused = page({ fetch: () => Promise.resolve(answer(422, { status: "error", message: "That name is taken" })) })
  const modal = levelingActionModal({ submitUrl: "/q" }, refused)
  modal.save()
  await settle()
  assert.deepEqual([modal.error, modal.saving, modal.saved], ["That name is taken", false, false])

  const bare = levelingActionModal({ submitUrl: "/q" }, page({ fetch: () => Promise.resolve(answer(500, {})) }))
  bare.save()
  await settle()
  assert.equal(bare.error, "Something went wrong. Please try again.")

  const offline = levelingActionModal({ submitUrl: "/q" }, page({ fetch: () => Promise.reject(new Error("Failed to fetch")) }))
  offline.save()
  await settle()
  assert.deepEqual([offline.error, offline.saving], ["Failed to fetch", false])
})

test("a save that cannot run sends nothing", () => {
  const env = page({ fetch: () => { throw new Error("no request is expected") } })
  const unchanged = levelingActionModal({ hasInput: true, initialValue: "picker", submitUrl: "/q" }, env)
  unchanged.save()
  assert.equal(unchanged.saving, false)

  const busy = levelingActionModal({ submitUrl: "/q" }, env)
  busy.saving = true
  busy.save()
  assert.equal(env.win.requests.length, 0)
})

test("the second step hands the challenge to the app's hook and posts its proof back", async () => {
  const answers = [
    answer(200, { status: "needs_step", challenge: "opaque-challenge", token: "t-1" }),
    answer(200, { status: "saved", seeds_earned: 10, seeds_total: 60 })
  ]
  const env = page({ props: {}, fetch: () => Promise.resolve(answers.shift()) })
  const seen = []
  env.win.appStep = (challenge, { token, onProgress }) => {
    onProgress("Approving")
    seen.push([challenge, token])
    return Promise.resolve("opaque-proof")
  }
  const modal = levelingActionModal({ submitUrl: "/q", finalizeUrl: "/q/finalize", finalizeHook: "appStep" }, env)

  modal.save()
  await settle()
  await settle()

  assert.deepEqual(seen, [["opaque-challenge", "t-1"]])
  assert.equal(env.win.requests[1].url, "/q/finalize")
  assert.deepEqual(env.win.requests[1].body, { token: "t-1", proof: "opaque-proof" })
  assert.deepEqual([modal.saved, modal.celebrate, modal.seedsTotal, modal.progressLabel], [true, true, 60, ""])
})

test("a second step with no hook, a refused proof and a throwing hook each show an error", async () => {
  const needsStep = () => Promise.resolve(answer(200, { status: "needs_step", challenge: "c", token: "t" }))

  const unwired = levelingActionModal({ submitUrl: "/q" }, page({ fetch: needsStep }))
  unwired.save()
  await settle()
  assert.deepEqual([unwired.error, unwired.saving], ["This step isn't available.", false])

  const answers = [answer(200, { status: "needs_step", challenge: "c", token: "t" }), answer(422, { status: "error" })]
  const refusedEnv = page({ fetch: () => Promise.resolve(answers.shift()) })
  refusedEnv.win.appStep = () => "proof"
  const refused = levelingActionModal({ submitUrl: "/q", finalizeUrl: "/f", finalizeHook: "appStep" }, refusedEnv)
  refused.save()
  await settle()
  await settle()
  assert.deepEqual([refused.error, refused.saving, refused.saved], ["Couldn't complete the step.", false, false])

  const throwingEnv = page({ fetch: needsStep })
  throwingEnv.win.appStep = () => Promise.reject(new Error("Declined in the app"))
  const throwing = levelingActionModal({ submitUrl: "/q", finalizeUrl: "/f", finalizeHook: "appStep" }, throwingEnv)
  throwing.save()
  await settle()
  await settle()
  assert.deepEqual([throwing.error, throwing.saving], ["Declined in the app", false])
})

test("the host's authedFetch is preferred when it defines one", async () => {
  const calls = []
  const env = page({ fetch: () => { throw new Error("authedFetch wins") }, authedFetch: (url) => { calls.push(url); return Promise.resolve(answer(200, {})) } })
  const modal = levelingActionModal({ submitUrl: "/q" }, env)
  modal.save()
  await settle()
  assert.deepEqual(calls, ["/q"])
  assert.equal(modal.saved, true)
})
