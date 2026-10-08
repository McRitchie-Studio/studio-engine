// [unit] studio/board: a drop that moves a card between lanes, a drop that
// ranks it inside one, a card leaving on a Turbo stream, and how SortableJS and
// the board's controller reach the scope. Loaded from source as a data: module,
// like local_path.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/board.js", import.meta.url), "utf8")
const load = () => import(`data:text/javascript,${encodeURIComponent(source)}#${Math.random()}`)
const {
  boardConfig, isLaneMove, rankedIds, reorderBody, moveRequest, sortableOptions,
  exitPlan, exitAnimation, isSortable, sortableShim, withBoardController,
  announceScope, scopeFor, studioBoard
} = await load()

// ---- fakes -----------------------------------------------------------------

const card = (id, zone = "designed") => ({
  attrs: { "data-slug": id, "data-stage": zone },
  classes: [],
  getAttribute(name) { return this.attrs[name] === undefined ? null : this.attrs[name] },
  setAttribute(name, value) { this.attrs[name] = value },
  classList: { add() {}, remove() {} }
})

// A dropzone: its key under data-stage, its cards in DOM order.
const zone = (key, cards = []) => ({
  key,
  cards,
  inserted: [],
  getAttribute(name) { return name === "data-stage" ? key : null },
  querySelectorAll() { return this.cards },
  querySelector() { return null },
  insertBefore(node, anchor) { this.inserted.push([node, anchor]) }
})

function page({ fetch, authedFetch, zones = [], sortable } = {}) {
  const dispatched = []
  const alerted = []
  const requests = []
  const win = {
    dispatched, alerted, requests,
    CustomEvent: function (type, init) { this.type = type; this.detail = (init || {}).detail },
    dispatchEvent(event) { dispatched.push(event) },
    alert(message) { alerted.push(message) },
    requestAnimationFrame(fn) { fn() },
    matchMedia: () => ({ matches: true }),
    MutationObserver: class {
      constructor(callback) { this.callback = callback; this.observed = []; this.disconnected = false }
      observe(target, options) { this.observed.push([target, options]) }
      disconnect() { this.disconnected = true }
    }
  }
  if (fetch) win.fetch = (url, options) => { requests.push({ url, options, body: JSON.parse(options.body) }); return fetch(url, options) }
  if (authedFetch) win.authedFetch = authedFetch
  if (sortable) win.Sortable = sortable
  const listeners = {}
  const doc = {
    listeners,
    byId: {},
    querySelector: () => null,
    querySelectorAll: (selector) => (selector === "[data-board-count]" ? [] : zones),
    getElementById(id) { return this.byId[id] || null },
    addEventListener(name, fn) { (listeners[name] = listeners[name] || []).push(fn) }
  }
  return { win, doc }
}

const response = (status, body) => ({ ok: status >= 200 && status < 300, status, json: () => Promise.resolve(body) })

// An Alpine scope: the factory's object with the two magics it reads.
// A board's element: its own zones and count badges, and nothing of another board's.
function boardElement({ zones = [], badges = [] } = {}) {
  return {
    dataset: {}, attrs: {},
    getAttribute(name) { return this.attrs[name] ?? null },
    setAttribute(name, value) { this.attrs[name] = value },
    querySelectorAll: (selector) => (selector === "[data-board-count]" ? badges : zones)
  }
}

function scope(opts, env, element) {
  const board = studioBoard(opts, env)
  board.$el = element || boardElement()
  board.ticks = []
  board.$nextTick = (fn) => board.ticks.push(fn)
  return board
}

class FakeSortable {
  static created = []
  static create(el, options) {
    const sortable = new FakeSortable(el, options)
    FakeSortable.created.push(sortable)
    return sortable
  }
  constructor(el, options) { this.el = el; this.options = options; this.destroyed = false }
  destroy() { this.destroyed = true }
}

// ---- the opts --------------------------------------------------------------

test("a board with no opts is the kanban: slug ids, stage zones, one shared group", () => {
  const config = boardConfig()
  assert.equal(config.zoneSelector, ".kanban-dropzone")
  assert.equal(config.cardSelector, ".kanban-card")
  assert.equal(config.groupName, "studio-board")
  assert.equal(config.idAttr, "slug")
  assert.equal(config.zoneAttr, "stage")
  assert.equal(config.reorderPayload, "slugs")
  assert.equal(config.optimistic, true)
  assert.equal(config.toastsEnabled, true)
  assert.equal(config.live, false)
  assert.equal(config.archiveZone, null)
  assert.equal(config.lockedSelector, null)
})

test("group false is the depth chart: no group, so a drag stays in its lane", () => {
  assert.equal(boardConfig({ group: false }).groupName, null)
  assert.equal(boardConfig({ group: "depth" }).groupName, "depth")
})

// ---- lane move against within-lane rank ------------------------------------

test("only a drop in another zone is a lane move", () => {
  const building = zone("building")
  assert.equal(isLaneMove(building, zone("submitted")), true)
  assert.equal(isLaneMove(building, building), false)
})

test("the rank is the zone's cards in DOM order", () => {
  const lane = zone("qb", [card("starter"), card("backup"), card("third")])
  assert.deepEqual(rankedIds(lane, ".kanban-card", "slug"), ["starter", "backup", "third"])

  lane.cards.reverse()
  assert.deepEqual(rankedIds(lane, ".kanban-card", "slug"), ["third", "backup", "starter"])
  assert.deepEqual(rankedIds(zone("empty"), ".kanban-card", "slug"), [])
})

test("the reorder body carries the rank under the app's key, with its zone", () => {
  assert.deepEqual(reorderBody("slugs", ["a", "b"], "focus"), { slugs: ["a", "b"], zone: "focus" })
  assert.deepEqual(reorderBody("ids", ["7"], "qb"), { ids: ["7"], zone: "qb" })
})

test("the move request fills the id into the URL and nests the zone under the resource", () => {
  assert.deepEqual(
    moveRequest("/tasks/:id.json", { resource: "task", attr: "stage" }, "a b/c", "building"),
    { url: "/tasks/a%20b%2Fc.json", body: { task: { stage: "building" } } }
  )
  assert.equal(moveRequest(null, { resource: "task", attr: "stage" }, "a", "building"), null)
  assert.equal(moveRequest("/tasks/:id.json", null, "a", "building"), null)
})

test("a within-lane drop saves the rank and PATCHes no zone", async () => {
  const lane = zone("focus", [card("g2"), card("g1")])
  const env = page({ fetch: () => Promise.resolve(response(200, {})) })
  const board = scope({ reorderUrl: "/weeks/1/reorder", moveUrl: "/games/:id.json", moveParam: { resource: "game", attr: "stage" } }, env)

  board.handleSortEnd({ item: lane.cards[0], from: lane, to: lane })
  await new Promise((resolve) => setImmediate(resolve))

  assert.equal(env.win.requests.length, 1, "one request: the reorder")
  assert.equal(env.win.requests[0].url, "/weeks/1/reorder")
  assert.equal(env.win.requests[0].options.method, "POST")
  assert.deepEqual(env.win.requests[0].body, { slugs: ["g2", "g1"], zone: "focus" })
  assert.deepEqual(env.win.dispatched.map((event) => event.type), ["studio:board-reordered"])
})

test("a lane move PATCHes the zone, then saves the destination's rank", async () => {
  const moved = card("ship-it", "building")
  const from = zone("building")
  const to = zone("submitted", [card("older", "submitted"), moved])
  const env = page({ fetch: () => Promise.resolve(response(200, {})) })
  const board = scope({
    reorderUrl: "/tasks/reorder", moveUrl: "/tasks/:id.json", moveParam: { resource: "task", attr: "stage" },
    labels: { submitted: "Submitted" }
  }, env)

  board.handleSortEnd({ item: moved, from, to })
  await new Promise((resolve) => setImmediate(resolve))

  assert.deepEqual(env.win.requests.map((request) => [request.options.method, request.url]),
    [["PATCH", "/tasks/ship-it.json"], ["POST", "/tasks/reorder"]])
  assert.deepEqual(env.win.requests[0].body, { task: { stage: "submitted" } })
  assert.deepEqual(env.win.requests[1].body, { slugs: ["older", "ship-it"], zone: "submitted" })
  assert.equal(moved.attrs["data-stage"], "submitted")
  assert.equal(board.toasts[0].message, "Moved to Submitted")
  assert.deepEqual(env.win.dispatched[0].detail, { record: "ship-it", from: "building", to: "submitted" })
})

test("a refused lane move goes back where it came from and saves no rank", async () => {
  const moved = card("ship-it", "building")
  const from = zone("building")
  const to = zone("submitted", [moved])
  const env = page({ fetch: () => Promise.resolve(response(422, { error: "Not ready to submit" })) })
  const board = scope({ reorderUrl: "/tasks/reorder", moveUrl: "/tasks/:id.json", moveParam: { resource: "task", attr: "stage" } }, env)

  board.handleSortEnd({ item: moved, from, to })
  await new Promise((resolve) => setImmediate(resolve))

  assert.equal(env.win.requests.length, 1, "the reorder is not sent")
  assert.equal(from.inserted.length, 1, "the card is back in the zone it left")
  assert.equal(moved.attrs["data-stage"], "building")
  assert.deepEqual([board.toasts[0].message, board.toasts[0].type], ["Not ready to submit", "error"])
})

test("a board with no move endpoint snaps a stray cross-zone drop back", () => {
  const moved = card("qb1", "qb")
  const from = zone("qb")
  const env = page({ fetch: () => { throw new Error("no request is expected") } })
  const board = scope({ reorderUrl: "/depth/reorder" }, env)

  assert.equal(board.applyMove(moved, from, zone("rb"), "qb1"), false)
  assert.equal(from.inserted.length, 1)
  assert.equal(env.win.dispatched.length, 0)
})

test("a demo board reflects a move and sends nothing", () => {
  const moved = card("demo", "designed")
  const env = page({ fetch: () => { throw new Error("no request is expected") } })
  const board = scope({ demo: true, moveUrl: "#", moveParam: { resource: "task", attr: "stage" }, labels: { building: "Building" } }, env)

  assert.equal(board.applyMove(moved, zone("designed"), zone("building"), "demo"), true)
  assert.equal(moved.attrs["data-stage"], "building")
  assert.equal(board.toasts[0].message, "Moved to Building")
})

// ---- SortableJS options ----------------------------------------------------

test("a kanban zone shares its group and filters the empty state", () => {
  const handlers = { onStart() {}, onEnd() {} }
  const options = sortableOptions(boardConfig({}), handlers)
  assert.equal(options.group, "studio-board")
  assert.equal(options.draggable, ".kanban-card")
  assert.equal(options.filter, ".kanban-empty")
  assert.equal(options.onStart, handlers.onStart)
  assert.equal(options.onEnd, handlers.onEnd)
  assert.equal("handle" in options, false)
  assert.equal("onMove" in options, false)
})

test("a depth chart has no group, a handle, and pins its locked cards", () => {
  const options = sortableOptions(
    boardConfig({ group: false, handle: ".grip", lockedSelector: ".kanban-locked" }), { onStart() {}, onEnd() {} }
  )
  assert.equal("group" in options, false)
  assert.equal(options.handle, ".grip")
  assert.equal(options.filter, ".kanban-empty, .kanban-locked")

  const sibling = (locked) => ({ matches: (selector) => locked && selector === ".kanban-locked" })
  assert.equal(options.onMove({ related: sibling(true) }), false, "a drag does not cross a locked card")
  assert.equal(options.onMove({ related: sibling(false) }), true)
  assert.equal(options.onMove({}), true)
})

// ---- the exit fallback -----------------------------------------------------

const exit = (overrides) => exitPlan({
  action: "remove", target: "card-ship-it", exitAction: "archive", domIdPrefix: "card-",
  archiveZone: "archived", archiveZonePresent: true, ...overrides
})

test("an archive exit re-parents into the archive column when the board has one on the page", () => {
  assert.equal(exit(), "reparent")
  assert.equal(exit({ archiveZonePresent: false }), "remove")
  assert.equal(exit({ archiveZone: null }), "remove")
})

test("a delete exit removes the card", () => {
  assert.equal(exit({ exitAction: "delete" }), "remove")
})

test("a stream that is not this board's exit is left to Turbo", () => {
  assert.equal(exit({ action: "replace" }), "ignore")
  assert.equal(exit({ exitAction: undefined }), "ignore")
  assert.equal(exit({ target: "news-ship-it" }), "ignore")
  assert.equal(exit({ target: null }), "ignore")
})

test("an archive sinks for 500ms and a delete shrinks for 420ms", () => {
  assert.equal(exitAnimation("archive").timing.duration, 500)
  assert.match(exitAnimation("archive").frames[1].transform, /translateY\(18px\)/)
  assert.equal(exitAnimation("delete").timing.duration, 420)
  assert.equal(exitAnimation("delete").frames[1].transform, "scale(0.6)")
})

function exitStream(env, { action = "remove", target = "card-ship-it", exitAction } = {}) {
  const rendered = []
  const event = {
    target: { getAttribute: (name) => ({ action, target })[name], dataset: { exitAction } },
    detail: { render: (el) => rendered.push(el) }
  }
  const original = event.detail.render
  env.doc.listeners["turbo:before-stream-render"].forEach((listener) => listener(event))
  return { event, rendered, intercepted: event.detail.render !== original }
}

function exitingCard() {
  return { ...card("ship-it", "building"), dataset: {}, style: {}, cancelled: 0,
    getAnimations() { return [{ cancel: () => { this.cancelled++ } }] } }
}

test("the fallback is installed once per page and animates an archive into the archive column", async () => {
  const env = page()
  const archive = zone("archived")
  const leaving = exitingCard()
  env.doc.byId = { "dropzone-archived": archive, "card-ship-it": leaving }
  const board = scope({ live: true, archiveZone: "archived" }, env)

  board.installExitStreamFallback()
  board.installExitStreamFallback()
  assert.equal(env.doc.listeners["turbo:before-stream-render"].length, 1)

  const stream = exitStream(env, { exitAction: "archive" })
  assert.equal(stream.intercepted, true)
  stream.event.detail.render("stream")
  await new Promise((resolve) => setImmediate(resolve))

  assert.deepEqual(stream.rendered, [], "Turbo does not remove a re-parented card")
  assert.equal(archive.inserted[0][0], leaving)
  assert.equal(leaving.attrs["data-stage"], "archived")
  assert.equal(leaving.cancelled, 1, "its exit animation is cleared")
  assert.equal("exitAction" in leaving.dataset, false)
})

test("the fallback lets Turbo remove a deleted card after its exit, and ignores other streams", async () => {
  const env = page()
  const leaving = exitingCard()
  env.doc.byId = { "card-ship-it": leaving }
  scope({ live: true }, env).installExitStreamFallback()

  assert.equal(exitStream(env, { action: "append", exitAction: "delete" }).intercepted, false)
  assert.equal(exitStream(env, {}).intercepted, false, "a remove with no data-exit-action")

  const stream = exitStream(env, { exitAction: "delete" })
  stream.event.detail.render("stream")
  await new Promise((resolve) => setImmediate(resolve))
  assert.deepEqual(stream.rendered, ["stream"])
  assert.equal(leaving.dataset.exitAction, "delete", "the marker is set even with reduced motion")
})

// ---- SortableJS, loaded once -----------------------------------------------

test("SortableJS is a constructor; the loading shim is not", () => {
  assert.equal(isSortable(FakeSortable), true)
  assert.equal(isSortable(sortableShim(() => Promise.resolve(FakeSortable))), false)
  assert.equal(isSortable(undefined), false)
  assert.equal(isSortable(() => {}), false)
})

test("loadSortable resolves at once with a Sortable already on the page", async () => {
  const { loadSortable } = await load()
  const loaded = await loadSortable({ win: { Sortable: FakeSortable }, importer: () => { throw new Error("no import is expected") } })
  assert.equal(loaded, FakeSortable)
})

test("loadSortable imports the classic build once and replaces the shim", async () => {
  const { loadSortable, sortableShim: shim } = await load()
  const win = {}
  win.Sortable = shim(() => loadSortable({ win, importer }))
  let imports = 0
  const importer = () => { imports++; win.Sortable = FakeSortable; return Promise.resolve({}) }

  const [first, second] = await Promise.all([loadSortable({ win, importer }), loadSortable({ win, importer })])
  assert.equal(first, FakeSortable)
  assert.equal(second, FakeSortable)
  assert.equal(imports, 1)
})

test("loadSortable takes a host's module export and publishes it over the shim", async () => {
  const { loadSortable } = await load()
  const win = { Sortable: { studioShim: true } }
  assert.equal(await loadSortable({ win, importer: () => Promise.resolve({ default: FakeSortable }) }), FakeSortable)
  assert.equal(win.Sortable, FakeSortable)
})

test("a failed load rejects and the next call tries again", async () => {
  const { loadSortable } = await load()
  const win = {}
  let attempts = 0
  const importer = () => { attempts++; return attempts === 1 ? Promise.reject(new Error("offline")) : Promise.resolve({ default: FakeSortable }) }

  await assert.rejects(loadSortable({ win, importer }), /offline/)
  await assert.rejects(loadSortable({ win: {}, importer: () => Promise.resolve({}) }), /without defining Sortable/)
  assert.equal(await loadSortable({ win, importer }), FakeSortable)
})

test("the shim's create loads SortableJS and then creates the sortable", async () => {
  FakeSortable.created = []
  const reported = []
  const shim = sortableShim(() => Promise.resolve(FakeSortable), (error) => reported.push(error))

  assert.equal(shim.create("zone", { group: "kanban" }), undefined)
  assert.equal(FakeSortable.created.length, 0, "nothing is created until the library arrives")
  await new Promise((resolve) => setImmediate(resolve))
  assert.deepEqual([FakeSortable.created[0].el, FakeSortable.created[0].options], ["zone", { group: "kanban" }])

  sortableShim(() => Promise.reject(new Error("offline")), (error) => reported.push(error.message)).create("zone", {})
  await new Promise((resolve) => setImmediate(resolve))
  assert.deepEqual(reported, ["offline"])
})

// ---- the scope and its controller ------------------------------------------

test("the board controller is named once on the element", () => {
  assert.equal(withBoardController(null), "board")
  assert.equal(withBoardController("board"), "board")
  assert.equal(withBoardController("  tabs   board "), "tabs board")
  assert.equal(withBoardController("dashboard"), "dashboard board")
})

test("the controller finds the scope whether it connects before or after Alpine", async () => {
  const early = {}
  const waitingForIt = scopeFor(early)
  announceScope(early, "scope-a")
  assert.equal(await waitingForIt, "scope-a")

  const late = {}
  announceScope(late, "scope-b")
  assert.equal(await scopeFor(late), "scope-b")
})

test("init names the controller on a hand-written board and announces the scope", async () => {
  const board = scope({}, page())
  board.init()
  assert.equal(board.$el.attrs["data-studio-controller"], "board")
  assert.equal(await scopeFor(board.$el), board)
  assert.equal(board.$el.dataset.alpineReady, undefined, "a board is not ready until it is wired")
})

test("wire makes each zone sortable, marks the board ready, and its return undoes both", () => {
  FakeSortable.created = []
  const zones = [zone("designed"), zone("building")]
  const env = page({ zones: [zone("another-boards-zone")] })
  const board = scope({ group: "tasks" }, env, boardElement({ zones }))

  const unwire = board.wire(FakeSortable)
  assert.deepEqual(FakeSortable.created.map((sortable) => sortable.el), zones)
  assert.equal(FakeSortable.created[0].options.group, "tasks")
  assert.equal(board.$el.dataset.alpineReady, undefined, "ready is set after the tick, not during the walk")
  board.ticks.forEach((tick) => tick())
  assert.equal(board.$el.dataset.alpineReady, "true")

  FakeSortable.created[0].options.onStart()
  assert.equal(env.win.__studioBoardDragging, true)

  unwire()
  assert.equal("alpineReady" in board.$el.dataset, false)
  assert.equal(FakeSortable.created.every((sortable) => sortable.destroyed), true)
})

test("a board unwired before its tick never claims to be ready", () => {
  const board = scope({}, page())
  board.wire(FakeSortable)()
  board.ticks.forEach((tick) => tick())
  assert.equal("alpineReady" in board.$el.dataset, false)
})

test("a live board watches its zones, and a board without SortableJS is still ready", () => {
  FakeSortable.created = []
  const zones = [zone("designed")]
  const env = page({ zones: [zone("another-boards-zone")] })
  const board = scope({ live: true }, env, boardElement({ zones }))

  const unwire = board.wire(null)
  assert.equal(FakeSortable.created.length, 0)
  assert.equal(env.doc.listeners["turbo:before-stream-render"].length, 1)
  board.ticks.forEach((tick) => tick())
  assert.equal(board.$el.dataset.alpineReady, "true")

  const observers = scope({}, env, boardElement({ zones })).observeLive()
  assert.deepEqual(observers.map((observer) => observer.observed[0][0]), zones)
  unwire()
})

test("a board counts its own zones into its own badges", () => {
  const badge = (key) => ({ key, textContent: "", getAttribute: () => key })
  const lane = (key, count) => ({ ...zone(key, new Array(count).fill(card("c"))), id: "dropzone-" + key, empty: { style: {} },
    querySelector() { return this.empty } })
  const mine = { zones: [lane("designed", 2), lane("building", 0)], badges: [badge("designed"), badge("building"), badge("elsewhere")] }
  // Another board on the page carries the same column keys.
  const env = page({ zones: [lane("designed", 9)] })
  const board = scope({ emptySelector: ".kanban-empty" }, env, boardElement(mine))

  board.updateCounts()

  assert.deepEqual(mine.badges.map((entry) => entry.textContent), [2, 0, ""])
  assert.equal(mine.zones[0].empty.style.display, "none")
  assert.equal(mine.zones[1].empty.style.display, "flex", "an empty zone shows its empty state")
})

// ---- chrome state and toasts -----------------------------------------------

test("the state bag toggles flags and list members", () => {
  const board = scope({ state: { showArchived: false, hiddenApps: ["rolio"] } }, page())
  board.toggleState("showArchived")
  assert.equal(board.state.showArchived, true)
  assert.equal(board.listHas("hiddenApps", "rolio"), true)
  board.toggleInState("hiddenApps", "rolio")
  board.toggleInState("hiddenApps", "turf")
  assert.deepEqual(board.state.hiddenApps, ["turf"])
  board.toggleInState("focused", "building")
  assert.deepEqual(board.state.focused, ["building"])
  assert.deepEqual(scope({}, page()).state, {})
})

test("a board without toasts alerts an error and stays quiet on success", () => {
  const env = page()
  const board = scope({ toasts: false }, env)
  board.toast("Saved", "success")
  board.toast("Depth chart is locked", "error")
  assert.deepEqual(env.win.alerted, ["Depth chart is locked"])
  assert.deepEqual(board.toasts, [])
})
