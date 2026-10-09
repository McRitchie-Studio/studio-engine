// [unit] studio/birthday: the date arithmetic the three selects share, the
// birthday card's scope (the app's answer, the handoff to the age-gate card and
// the return trip) and the profile row's scope (what it publishes to the form
// and how Discard reaches it). Loaded from source as a data: module, like
// cropper.test.mjs; the module imports nothing.
//
// The age-gate card's own back() and the seam between the two cards run in
// test/views/birthday_return_trip_test.rb, against the card's rendered x-data.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/birthday.js", import.meta.url), "utf8")
const {
  MONTHS, DEMO_RESOLVE_MS, VERIFY_FAILED, NETWORK_ERROR,
  daysInMonth, dayOptions, dayExists, yearsBack, ageOn, partsOfIso, isoOfParts, dateSignature,
  returnedDob, refusalLine, verdictOf, birthdayModal, studioBirthdayFields
} = await import(`data:text/javascript,${encodeURIComponent(source)}`)

test("the module imports nothing, so the head can load it by its own tag", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

// ---- the calendar -----------------------------------------------------------

test("a month has its own days, and February has 29 only in a leap year", () => {
  assert.equal(daysInMonth("1", "1990"), 31)
  assert.equal(daysInMonth("4", "1990"), 30)
  assert.equal(daysInMonth("2", "2003"), 28)
  assert.equal(daysInMonth("2", "2004"), 29)
  assert.equal(daysInMonth("2", "1900"), 28, "a century year is not a leap year")
  assert.equal(daysInMonth("2", "2000"), 29, "unless it divides by 400")
})

test("with no year February offers 29, and with no month every day is offered", () => {
  assert.equal(daysInMonth("2", ""), 29)
  assert.equal(daysInMonth("", "1990"), 31)
  assert.deepEqual(dayOptions("2", "2003"), Array.from({ length: 28 }, (_, i) => i + 1))
  assert.equal(dayOptions("", "").length, 31)
})

test("a picked day survives a month change only when the new month has it", () => {
  assert.equal(dayExists("31", "1", "1990"), true)
  assert.equal(dayExists("31", "2", "1990"), false)
  assert.equal(dayExists("29", "2", "2004"), true)
  assert.equal(dayExists("29", "2", "2003"), false)
  assert.equal(dayExists("", "2", "2003"), false)
})

test("the year lists count down between two offsets from today", () => {
  const now = new Date(2026, 5, 15)
  const gate = yearsBack(now, 13, 100)
  assert.equal(gate[0], 2013)
  assert.equal(gate[gate.length - 1], 1926)
  const profile = yearsBack(now, 0, 120)
  assert.equal(profile[0], 2026, "a birthday is not in the future")
  assert.equal(profile.length, 121)
})

test("an age counts a birthday only once it has happened this year", () => {
  const now = new Date(2026, 5, 15)
  assert.equal(ageOn("2005", "6", "15", now), 21, "today is the birthday")
  assert.equal(ageOn("2005", "6", "16", now), 20, "tomorrow is")
  assert.equal(ageOn("2005", "7", "1", now), 20)
  assert.equal(ageOn("2005", "5", "31", now), 21)
  assert.equal(ageOn("1990", "1", "1", now), 36)
})

test("an ISO date becomes the three strings the selects hold, and back", () => {
  assert.deepEqual(partsOfIso("1991-01-31"), { year: "1991", month: "1", day: "31" })
  assert.deepEqual(partsOfIso(""), { year: "", month: "", day: "" })
  assert.deepEqual(partsOfIso("31/01/1991"), { year: "", month: "", day: "" })
  assert.deepEqual(partsOfIso(undefined), { year: "", month: "", day: "" })
  assert.equal(isoOfParts("1991", "1", "31"), "1991-01-31")
  assert.equal(isoOfParts("1991", "", "31"), "")
})

test("the signature is the ISO date when complete, blank when untouched, and visible when partial", () => {
  assert.equal(dateSignature("1991", "1", "31"), "1991-01-31")
  assert.equal(dateSignature("", "", ""), "", "an untouched empty field does not arrive dirty")
  assert.equal(dateSignature("", "4", ""), "-4-", "choosing only a month is a change")
  assert.notEqual(dateSignature("", "4", ""), dateSignature("", "", ""))
})

test("a returned date needs all three parts and clamps a day its month does not have", () => {
  assert.deepEqual(returnedDob({ dobYear: 2010, dobMonth: 6, dobDay: 15 }), { year: "2010", month: "6", day: "15" })
  assert.equal(returnedDob({ dobYear: 2010, dobMonth: 6 }), null)
  assert.equal(returnedDob({}), null)
  assert.equal(returnedDob(undefined), null)
  assert.deepEqual(returnedDob({ dobYear: 2003, dobMonth: 2, dobDay: 30 }), { year: "2003", month: "2", day: "" })
  assert.deepEqual(returnedDob({ dobYear: 2004, dobMonth: 2, dobDay: 29 }), { year: "2004", month: "2", day: "29" })
})

test("the refusal line names the bar and the state when there is one", () => {
  assert.equal(refusalLine(21, "CA"), "You must be 21+ in CA.")
  assert.equal(refusalLine(18, ""), "You must be 18+.")
})

test("the app's answer is verified, refused or an error", () => {
  assert.deepEqual(verdictOf({ ok: true, status: 200, body: { verified: true } }), { verdict: "verified" })
  assert.deepEqual(verdictOf({ ok: false, status: 422, body: { underage: true, error: "Too young." } }),
    { verdict: "refused", message: "Too young." })
  assert.deepEqual(verdictOf({ ok: false, status: 403, body: {} }), { verdict: "refused", message: "" })
  assert.deepEqual(verdictOf({ ok: false, status: 403, body: { message: "Not yet." } }), { verdict: "refused", message: "Not yet." })
  assert.deepEqual(verdictOf({ ok: false, status: 422, body: { error: "Bad date." } }), { verdict: "error", message: "Bad date." })
  assert.deepEqual(verdictOf({ ok: false, status: 500, body: null }), { verdict: "error", message: VERIFY_FAILED })
  assert.deepEqual(verdictOf({ ok: true, status: 200, body: { verified: false } }), { verdict: "error", message: VERIFY_FAILED },
    "a 200 that does not say verified is not a pass")
})

// ---- the birthday card --------------------------------------------------------

const NOW = new Date(2026, 5, 15)

const fakeStore = (props = {}) => ({
  entry: { id: "birthday", props },
  swapped: null,
  closed: 0,
  current() { return this.entry },
  swap(id, swappedProps) { this.swapped = { id, props: swappedProps } },
  close() { this.closed += 1 }
})

// A window with named Alpine stores, a clock the test turns by hand, a fetch
// the test answers, and a record of the events dispatched on it.
const fakeWindow = (stores = {}, answer) => {
  const events = []
  const requests = []
  let timers = []
  return {
    events,
    requests,
    Alpine: { store: (name) => stores[name] },
    CustomEvent: class { constructor(name) { this.type = name } },
    dispatchEvent(event) { events.push(event.type) },
    document: { querySelector: () => ({ content: "csrf-token-value" }) },
    setTimeout(fn, ms) { timers.push({ fn, ms }) },
    runTimers() { const due = timers; timers = []; due.forEach((t) => t.fn()) },
    timers: () => timers.map((t) => t.ms),
    fetch(url, init) {
      requests.push({ url, init })
      return answer(url, init)
    }
  }
}

const respond = (status, body) => () => Promise.resolve({ ok: status >= 200 && status < 300, status, json: () => Promise.resolve(body) })
const settle = () => new Promise((resolve) => setImmediate(resolve))

const mountCard = ({ props, opts, answer, session } = {}) => {
  const modals = fakeStore(props)
  const stores = { modals }
  if (session) stores.session = session
  const win = fakeWindow(stores, answer || respond(200, { verified: true }))
  const card = birthdayModal({ minAge: 21, state: "CA", url: "/age", gateId: "age-gate", ...opts }, { win, now: NOW })
  card.init()
  return { card, modals, win }
}

const pick = (card, year, month, day) => { card.year = String(year); card.month = String(month); card.day = String(day) }

test("the card holds no policy of its own: no minimum age unless the app supplies one", () => {
  const card = birthdayModal({}, { win: fakeWindow(), now: NOW })
  assert.equal(card.minAge, 0)
  assert.equal(card.store, "modals")
  assert.equal(card.gateId, "")
  pick(card, 2020, 1, 1)
  assert.equal(card.isUnderage, false, "with no bar nothing is under it")
})

test("the selects offer twelve months, the plausible years and the chosen month's days", () => {
  const { card } = mountCard()
  assert.equal(card.months, MONTHS)
  assert.equal(card.years[0], 2013)
  assert.equal(card.years[card.years.length - 1], 1926)
  card.month = "2"; card.year = "2003"
  assert.equal(card.dayOptions.length, 28)
})

test("changing the month clears a day it does not have, and the error line", () => {
  const { card } = mountCard()
  pick(card, 1990, 1, 31)
  card.error = "stale"
  card.month = "2"
  card.onMonthChange()
  assert.equal(card.day, "")
  assert.equal(card.error, "")
  assert.equal(card.complete, false)
})

test("an incomplete date does not submit", () => {
  const { card, win } = mountCard()
  card.month = "6"
  card.submit()
  assert.equal(card.submitting, false)
  assert.equal(win.requests.length, 0)
})

test("a complete date posts its three parts to the app with the CSRF token", async () => {
  const { card, win } = mountCard()
  pick(card, 1990, 6, 15)
  card.submit()
  assert.equal(card.submitting, true)
  assert.equal(win.requests[0].url, "/age")
  assert.equal(win.requests[0].init.method, "POST")
  assert.equal(win.requests[0].init.headers["X-CSRF-Token"], "csrf-token-value")
  assert.deepEqual(JSON.parse(win.requests[0].init.body), { year: "1990", month: "6", day: "15" })
  await settle()
  assert.equal(card.submitting, false)
})

test("an under-age date still goes to the app: the client refuses nothing", async () => {
  const { card, win } = mountCard({ answer: respond(403, { underage: true }) })
  pick(card, 2012, 6, 15)
  assert.equal(card.isUnderage, true)
  card.submit()
  assert.equal(win.requests.length, 1)
})

test("a second press while submitting posts nothing more", () => {
  const { card, win } = mountCard()
  pick(card, 1990, 6, 15)
  card.submit()
  card.submit()
  assert.equal(win.requests.length, 1)
})

test("verified: the session flag flips, the card closes and age-verified fires", async () => {
  const session = { ageVerified: false }
  const { card, modals, win } = mountCard({ session })
  pick(card, 1990, 6, 15)
  card.submit()
  await settle()
  assert.equal(session.ageVerified, true)
  assert.equal(modals.closed, 1)
  assert.deepEqual(win.events, ["age-verified"])
  assert.equal(modals.swapped, null)
})

test("refused: the age-gate card opens by swap, carrying the bar, the state, the message and the date", async () => {
  const session = { ageVerified: false }
  const { card, modals, win } = mountCard({ session, answer: respond(422, { underage: true, error: "You must be 21." }) })
  pick(card, 2010, 6, 15)
  card.submit()
  await settle()
  assert.deepEqual(modals.swapped, {
    id: "age-gate",
    props: { minAge: 21, state: "CA", message: "You must be 21.", dobYear: 2010, dobMonth: 6, dobDay: 15 }
  })
  assert.equal(card.error, "", "a refusal is a handoff, not an error line")
  assert.equal(session.ageVerified, false)
  assert.equal(modals.closed, 0)
  assert.deepEqual(win.events, [])
})

test("refused with no gate card registered: the refusal is said on the card's own line", async () => {
  const { card, modals } = mountCard({ opts: { gateId: "" }, answer: respond(403, {}) })
  pick(card, 2010, 6, 15)
  card.submit()
  await settle()
  assert.equal(modals.swapped, null)
  assert.equal(card.error, "You must be 21+ in CA.")
})

test("refused on a store with no swap: the refusal falls back to the card's own line", async () => {
  const { card, modals } = mountCard({ answer: respond(403, { error: "Too young." }) })
  modals.swap = () => { throw new Error("no swap here") }
  pick(card, 2010, 6, 15)
  card.submit()
  await settle()
  assert.equal(card.error, "Too young.")
})

test("an error that is not a refusal stays on the card", async () => {
  const { card, modals } = mountCard({ answer: respond(422, { error: "That date is not valid." }) })
  pick(card, 1990, 6, 15)
  card.submit()
  await settle()
  assert.equal(card.error, "That date is not valid.")
  assert.equal(modals.swapped, null)
  assert.equal(modals.closed, 0)
})

test("a dropped connection says so and the card can be pressed again", async () => {
  const { card } = mountCard({ answer: () => Promise.reject(new Error("offline")) })
  pick(card, 1990, 6, 15)
  card.submit()
  await settle()
  assert.equal(card.error, NETWORK_ERROR)
  assert.equal(card.submitting, false)
})

test("the style guide's demo answers locally and posts nothing", () => {
  const { card, modals, win } = mountCard({ opts: { demo: true } })
  pick(card, 1990, 6, 15)
  card.submit()
  assert.deepEqual(win.timers(), [DEMO_RESOLVE_MS])
  win.runTimers()
  assert.equal(win.requests.length, 0)
  assert.equal(modals.closed, 1)

  const refused = mountCard({ opts: { demo: true, demoUnderage: true } })
  pick(refused.card, 1990, 6, 15)
  refused.card.submit()
  refused.win.runTimers()
  assert.equal(refused.modals.swapped.id, "age-gate")
})

test("the return trip restores the date, as strings, and not the verdict", () => {
  const { card } = mountCard({ props: { dobYear: 2010, dobMonth: 6, dobDay: 15 } })
  assert.deepEqual([card.year, card.month, card.day], ["2010", "6", "15"])
  assert.equal(card.complete, true)
  assert.equal(card.error, "")
  assert.equal(card.isUnderage, true, "the restored date is still under the bar")
})

test("a cold card starts blank, and a page with no such store does not throw", () => {
  const { card } = mountCard()
  assert.deepEqual([card.year, card.month, card.day], ["", "", ""])
  const orphan = birthdayModal({ store: "missing" }, { win: fakeWindow(), now: NOW })
  orphan.init()
  assert.equal(orphan.complete, false)
})

// ---- the profile row ----------------------------------------------------------

// The scope as Alpine hands it over: `fields` reached through the scope chain,
// and a $watch the test fires by hand.
const mountFields = (initial, fields) => {
  const scope = studioBirthdayFields(initial, { now: NOW })
  const watchers = {}
  if (fields) scope.fields = fields
  scope.$watch = (path, fn) => { watchers[path] = fn }
  scope.init()
  return { scope, watchers }
}

test("the row opens on the date on file and offers this year back 120", () => {
  const { scope } = mountFields("1991-01-31", { birthday: "1991-01-31" })
  assert.deepEqual([scope.year, scope.month, scope.day], ["1991", "1", "31"])
  assert.equal(scope.isoValue, "1991-01-31")
  assert.equal(scope.years[0], 2026)
  assert.equal(scope.years.length, 121)
})

test("an untouched row publishes exactly what the form loaded with, so the page does not arrive dirty", () => {
  const filled = { birthday: "1991-01-31" }
  mountFields("1991-01-31", filled)
  assert.equal(filled.birthday, "1991-01-31")

  const empty = { birthday: "" }
  mountFields("", empty)
  assert.equal(empty.birthday, "")
})

test("choosing only a month on an empty birthday is a change the form can see", () => {
  const fields = { birthday: "" }
  const { scope } = mountFields("", fields)
  scope.month = "4"
  scope.onMonthChange()
  assert.notEqual(fields.birthday, "")
  assert.equal(scope.isoValue, "", "though the hidden input still carries no date")
})

test("a month change drops a day the month does not have before it publishes", () => {
  const fields = { birthday: "1991-01-31" }
  const { scope } = mountFields("1991-01-31", fields)
  scope.month = "2"
  scope.onMonthChange()
  assert.equal(scope.day, "")
  assert.equal(fields.birthday, "1991-2-")
})

test("Discard reaches the selects: the form's restored value is adopted", () => {
  const fields = { birthday: "1991-01-31" }
  const { scope, watchers } = mountFields("1991-01-31", fields)
  scope.year = "1985"; scope.month = "7"; scope.day = "4"
  scope.publish()
  assert.equal(fields.birthday, "1985-07-04")

  watchers["fields.birthday"]("1991-01-31")
  assert.deepEqual([scope.year, scope.month, scope.day], ["1991", "1", "31"])
})

test("the watch ignores the value the row itself just published", () => {
  const fields = { birthday: "" }
  const { scope, watchers } = mountFields("", fields)
  scope.month = "4"
  scope.publish()
  watchers["fields.birthday"](fields.birthday)
  assert.equal(scope.month, "4", "a partial pick is not wiped by its own echo")
})

test("a cleared birthday empties all three selects", () => {
  const { scope, watchers } = mountFields("1991-01-31", { birthday: "1991-01-31" })
  watchers["fields.birthday"]("")
  assert.deepEqual([scope.year, scope.month, scope.day], ["", "", ""])
})

test("outside a profile form the row publishes nowhere and does not throw", () => {
  const { scope } = mountFields("1991-01-31")
  scope.onMonthChange()
  assert.equal(scope.isoValue, "1991-01-31")
})
