// studio/birthday: the two places a person picks a date of birth from three
// selects (studio/fields/_date_of_birth), and the date arithmetic both share.
//
//   x-data="birthdayModal({ minAge, state, url, store, gateId })"
//       the birthday card (studio/modals/blocks/_birthday): asks for the date
//       and posts it to the app, which decides.
//   x-data="studioBirthdayFields('1991-01-31')"
//       the profile page's birthday row (studio/profiles/_birthday_fields):
//       writes the picked date into the enclosing profile form.
//
// Both bind month, day, year, months, dayOptions, years and onMonthChange().
//
// studio/alpine_scopes publishes both on window, statically: the birthday card
// gates an entry, and a card whose factory is missing has nothing to press.
// It imports nothing; test/javascript/birthday.test.mjs loads it as a data:
// module.

export const MONTHS = [
  { n: 1, label: "January" }, { n: 2, label: "February" }, { n: 3, label: "March" },
  { n: 4, label: "April" }, { n: 5, label: "May" }, { n: 6, label: "June" },
  { n: 7, label: "July" }, { n: 8, label: "August" }, { n: 9, label: "September" },
  { n: 10, label: "October" }, { n: 11, label: "November" }, { n: 12, label: "December" }
]

const ISO_DATE = /^(\d{4})-(\d{2})-(\d{2})$/

// How long the style guide's demo card takes to answer.
export const DEMO_RESOLVE_MS = 450

export const VERIFY_FAILED = "We couldn't verify your age. Please check the date and try again."
export const NETWORK_ERROR = "Network error — please try again."

// The days a month has: 30 in April, 29 in a February only in a leap year. Day
// 0 of the next month is the last day of this one. With no year picked the
// year is 2000, a leap year, so February offers 29. With no month, 31.
export function daysInMonth(month, year) {
  const m = parseInt(month, 10)
  if (!m) return 31
  return new Date(parseInt(year, 10) || 2000, m, 0).getDate()
}

// [1, 2, ... n] for the day select.
export function dayOptions(month, year) {
  return Array.from({ length: daysInMonth(month, year) }, (_, index) => index + 1)
}

// Whether a picked day still exists once the month or year changes (the 31st
// does not survive a move to February).
export function dayExists(day, month, year) {
  return !!day && parseInt(day, 10) <= daysInMonth(month, year)
}

// The years counted down from `newest` years ago to `oldest` years ago.
export function yearsBack(now, newest, oldest) {
  const years = []
  for (let y = now.getFullYear() - newest; y >= now.getFullYear() - oldest; y--) years.push(y)
  return years
}

// Whole years between a date of birth and `now`: a birthday later this year
// has not happened yet.
export function ageOn(year, month, day, now) {
  const dob = new Date(parseInt(year, 10), parseInt(month, 10) - 1, parseInt(day, 10))
  let age = now.getFullYear() - dob.getFullYear()
  const hadBirthday = (now.getMonth() > dob.getMonth()) ||
    (now.getMonth() === dob.getMonth() && now.getDate() >= dob.getDate())
  if (!hadBirthday) age -= 1
  return age
}

// "1991-01-31" as the three strings the selects hold ("1991", "1", "31"), or
// three blanks for anything that is not a full date. Strings, because that is
// what a pick produces: an option renders :value="m.n", the DOM stringifies it
// and x-model writes the string back.
export function partsOfIso(value) {
  const match = ISO_DATE.exec(String(value || ""))
  if (!match) return { year: "", month: "", day: "" }
  return { year: String(+match[1]), month: String(+match[2]), day: String(+match[3]) }
}

// The three parts as "1991-01-31", or "" until all three are picked.
export function isoOfParts(year, month, day) {
  if (!(year && month && day)) return ""
  return year + "-" + String(month).padStart(2, "0") + "-" + String(day).padStart(2, "0")
}

// What the profile form's dirty check compares. A complete date is its ISO
// string, so a finished edit compares against the value the page loaded with.
// An untouched empty field is "", the same as a person with no birthday on
// file. A partial pick is the three parts joined, so choosing only a month
// reads as a change.
export function dateSignature(year, month, day) {
  if (year && month && day) return isoOfParts(year, month, day)
  if (!year && !month && !day) return ""
  return [year, month, day].join("-")
}

// The date a modal entry's props carry back from the age-gate card
// (dobYear, dobMonth, dobDay), as select strings, or null when any part is
// missing. A day the restored month does not have comes back blank: a select
// holding a value its options do not contain reads as complete and would
// submit a date nobody picked.
export function returnedDob(props) {
  props = props || {}
  const y = parseInt(props.dobYear, 10)
  const m = parseInt(props.dobMonth, 10)
  const d = parseInt(props.dobDay, 10)
  if (!y || !m || !d) return null
  return { year: String(y), month: String(m), day: d <= daysInMonth(m, y) ? String(d) : "" }
}

// The line a refusal reads when no age-gate card is registered.
export function refusalLine(minAge, stateCode) {
  return "You must be " + minAge + "+" + (stateCode ? " in " + stateCode : "") + "."
}

// What the app's answer means. The app tells "too young" from "bad request":
// body.underage or a 403 is a refusal, which goes to the age-gate card; any
// other failure is an error, which stays on the card's own line.
export function verdictOf(response) {
  const body = (response && response.body) || {}
  if (response && response.ok && body.verified) return { verdict: "verified" }
  if (body.underage === true || (response && response.status === 403)) {
    return { verdict: "refused", message: body.error || body.message || "" }
  }
  return { verdict: "error", message: body.error || VERIFY_FAILED }
}

// x-data for the birthday card. The factory holds no policy: minAge is the
// app's (0 means the app supplied none), the age it computes is a hint, and
// the app's answer at `url` is the verdict.
//
// opts:
//   minAge        the app's minimum age.
//   state         a jurisdiction label, shown and never edited.
//   url           the app endpoint the date posts to.
//   store         the Alpine store the card is mounted in (default "modals").
//   gateId        the modal a refusal opens (the age-gate card). Blank, the
//                 refusal is the card's own error line.
//   demo          the style guide: answer locally, post nothing.
//   demoUnderage  the style guide: take the refused branch.
//
// env: { win, now } for the tests.
export function birthdayModal(opts, env) {
  opts = opts || {}
  const win = (env && env.win) || window
  const now = (env && env.now) || new Date()

  return {
    month: "", day: "", year: "",
    submitting: false,
    error: "",
    minAge: parseInt(opts.minAge, 10) || 0,
    stateCode: opts.state || "",
    url: opts.url || "",
    store: opts.store || "modals",
    demo: !!opts.demo,
    demoUnderage: !!opts.demoUnderage,
    gateId: opts.gateId || "",
    months: MONTHS,
    // From 13 years ago back 100: a sane range to pick from, not an age bar.
    years: yearsBack(now, 13, 100),

    get dayOptions() {
      return dayOptions(this.month, this.year)
    },
    get complete() {
      return !!(this.month && this.day && this.year)
    },
    get computedAge() {
      if (!this.complete) return null
      return ageOn(this.year, this.month, this.day, now)
    },
    get isUnderage() {
      return this.computedAge !== null && !!this.minAge && this.computedAge < this.minAge
    },

    onMonthChange() {
      if (this.day && !dayExists(this.day, this.month, this.year)) this.day = ""
      this.error = ""
    },

    // THE RETURN TRIP. _reject writes the date onto the store on its way to the
    // age-gate card, and that card's back() hands the same three parts back, so
    // a card mounted from a return trip finds the person's date on its own
    // entry. Read off the store, where this factory already meets it.
    _returnedDob() {
      try {
        const entry = win.Alpine.store(this.store).current()
        return returnedDob(entry && entry.props)
      } catch (_) {
        return null
      }
    },

    // Alpine calls init() at mount, before it walks the three selects, so the
    // restored date is their first state. The DATE is restored, never the
    // verdict: the app decides again on the next submit.
    init() {
      const dob = this._returnedDob()
      if (!dob) return
      this.year = dob.year
      this.month = dob.month
      this.day = dob.day
    },

    // Accepted: flip the session flag if the page has one, close, and let the
    // app resume what it was gating (it listens for `age-verified`).
    _finish() {
      try {
        const session = win.Alpine && win.Alpine.store && win.Alpine.store("session")
        if (session) session.ageVerified = true
      } catch (_) {}
      try { win.Alpine.store(this.store).close() } catch (_) {}
      win.dispatchEvent(new win.CustomEvent("age-verified"))
    },

    // Refused: hand off to the age-gate card, which owns what to do next. A
    // handoff and not an error, so the person is never left on a red card with
    // nothing to press. swap(), so that card's back link returns here. The date
    // crosses the store as three numbers, which a reactive proxy carries intact.
    _reject(message) {
      if (!this.gateId) {
        this.error = message || this._refusalLine()
        return
      }
      try {
        win.Alpine.store(this.store).swap(this.gateId, {
          minAge: this.minAge,
          state: this.stateCode,
          message: message || "",
          dobYear: parseInt(this.year, 10) || null,
          dobMonth: parseInt(this.month, 10) || null,
          dobDay: parseInt(this.day, 10) || null
        })
      } catch (_) {
        this.error = message || this._refusalLine()
      }
    },

    _refusalLine() {
      return refusalLine(this.minAge, this.stateCode)
    },

    // No refusal on the client: every complete date goes to the app, and its
    // answer routes here.
    submit() {
      if (!this.complete || this.submitting) return
      this.error = ""
      this.submitting = true
      const self = this

      if (this.demo) {
        win.setTimeout(function () {
          self.submitting = false
          if (self.demoUnderage || self.isUnderage) self._reject()
          else self._finish()
        }, DEMO_RESOLVE_MS)
        return
      }

      const csrf = (win.document.querySelector('meta[name="csrf-token"]') || {}).content || ""
      win.fetch(this.url, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf, "Accept": "application/json" },
        body: JSON.stringify({ year: this.year, month: this.month, day: this.day })
      })
        .then(function (response) {
          return response.json().then(function (body) { return { ok: response.ok, status: response.status, body } })
        })
        .then(function (response) {
          self.submitting = false
          const answer = verdictOf(response)
          if (answer.verdict === "verified") self._finish()
          else if (answer.verdict === "refused") self._reject(answer.message)
          else self.error = answer.message
        })
        .catch(function () {
          self.submitting = false
          self.error = NETWORK_ERROR
        })
    }
  }
}

// x-data for the profile page's birthday row: three selects in place of a date
// picker, so there is no popover to place and none to restore open. `initial`
// is the ISO date on file, or blank.
//
// It sits inside the profile form's scope (studio/profile_form), and reaches
// that scope's `fields` through Alpine's scope chain: publishing the picked
// date into fields.birthday is what raises the save bar.
export function studioBirthdayFields(initial, env) {
  const today = () => (env && env.now) || new Date()
  const parts = partsOfIso(initial)

  return {
    year: parts.year,
    month: parts.month,
    day: parts.day,
    months: MONTHS,

    // This year back 120: a birthday is not in the future, and 120 covers
    // every living person.
    get years() {
      return yearsBack(today(), 0, 120)
    },
    get dayOptions() {
      return dayOptions(this.month, this.year)
    },
    get complete() {
      return !!(this.year && this.month && this.day)
    },
    get isoValue() {
      return isoOfParts(this.year, this.month, this.day)
    },
    get signature() {
      return dateSignature(this.year, this.month, this.day)
    },

    // Named for what the shared field binds. Clears a day the new month or
    // year does not have, then publishes.
    onMonthChange() {
      if (this.day && !dayExists(this.day, this.month, this.year)) this.day = ""
      this.publish()
    },

    publish() {
      if (this.fields) this.fields.birthday = this.signature
    },

    // DISCARD REACHES THE SELECTS through this watch. The form's discard
    // reassigns its `fields`, which restores every input bound with x-model;
    // the selects are bound to this scope's own parts, so they follow
    // fields.birthday instead. The early return when the value already matches
    // is what stops publish and watch from looping.
    init() {
      const self = this
      this.publish()
      this.$watch("fields.birthday", function (value) {
        if (value === self.signature) return
        self.adopt(value)
      })
    },

    // Puts the selects on an ISO date; anything else empties all three.
    adopt(value) {
      Object.assign(this, partsOfIso(value))
    }
  }
}
