// studio/board: the board primitive (studio/board/_board): a kanban whose cards
// move between columns, and a depth chart whose cards rank inside one lane. One
// module drives both; a board reads its selectors and behaviour from its opts.
//
//   <section x-data="studioBoard({...})" data-studio-controller="board">
//
// THREE PARTS, AND WHO LOADS EACH.
//   - studioBoard(opts) is the Alpine scope: the toast list, the chrome state
//     bag, the move and reorder requests, the counts. Alpine evaluates the
//     x-data before any lazy module can arrive, so studio/alpine_shims imports
//     this module and publishes the factory as window.studioBoard.
//   - The board controller (studio/controllers/board_controller) is registered
//     lazily, on a page that renders a board. It loads SortableJS and hands it
//     to wire(), which makes the zones draggable and marks the board ready.
//   - loadSortable() fetches the vendored SortableJS through the "sortablejs"
//     pin, once, on the first board or the first Sortable.create a page makes.
//
// UI ONLY. A board PATCHes an app-supplied move URL, POSTs an app-supplied
// reorder URL and reads a neutral JSON contract; it holds no domain logic. An
// app extends it by listening for the window events it dispatches
// (studio:board-moved, studio:board-reordered, studio:card-added), by naming a
// window[fx] animation module, and by naming window[hook] functions. The
// engine inspects none of them.
//
// It imports nothing; test/javascript/board.test.mjs loads it as a data: module.

const CONTROLLER = "board"
const CONTROLLER_ATTRIBUTE = "data-studio-controller"

// ---- the opts a board is rendered with ------------------------------------

// The board's settings, from the opts studio/board/_board serialises.
//   group false      keeps a drag inside its zone (the depth chart).
//   archiveZone      the column a data-exit-action="archive" remove re-parents
//                    its card into; null removes the card.
//   lockedSelector   pinned cards: they do not drag and no drag crosses one.
export function boardConfig(opts) {
  opts = opts || {}
  return {
    zoneSelector: opts.zoneSelector || ".kanban-dropzone",
    cardSelector: opts.draggable || ".kanban-card",
    emptySelector: opts.emptySelector || null,
    groupName: opts.group === false ? null : (opts.group || "studio-board"),
    handle: opts.handle || null,
    sortFilter: opts.filter || ".kanban-empty",
    idAttr: opts.idAttr || "slug",
    zoneAttr: opts.zoneAttr || "stage",
    domIdPrefix: opts.domIdPrefix || "card-",
    moveUrl: opts.moveUrl || null,
    moveParam: opts.moveParam || null,
    reorderUrl: opts.reorderUrl || "",
    reorderPayload: opts.reorderPayload || "slugs",
    optimistic: opts.optimistic !== false,
    toastsEnabled: opts.toasts !== false,
    live: !!opts.live,
    demo: !!opts.demo,
    fxName: opts.fx || null,
    onMoveHook: opts.onMoveHook || null,
    onDropHook: opts.onDropHook || null,
    labels: opts.labels || {},
    archiveZone: opts.archiveZone || null,
    lockedSelector: opts.lockedSelector || null
  }
}

// ---- the drop: a lane move, or a rank inside a lane ------------------------

// A drop moves a card only when it lands in another zone. The zones decide,
// never the card: a card dropped back into its own zone is a reorder, and a
// reorder never PATCHes the zone.
export function isLaneMove(fromZone, toZone) {
  return fromZone !== toZone
}

// The ids of a zone's cards in DOM order: the rank a reorder saves.
export function rankedIds(zone, cardSelector, idAttr) {
  return Array.prototype.slice
    .call(zone.querySelectorAll(cardSelector))
    .map((card) => card.getAttribute("data-" + idAttr))
}

// The reorder POST body: the ranked ids under the app's key (slugs or ids),
// with the zone they were ranked in.
export function reorderBody(payloadKey, ids, zone) {
  const body = {}
  body[payloadKey] = ids
  body.zone = zone
  return body
}

// The move PATCH: ":id" in the URL template becomes the card's id, and the
// body is { resource: { attr: zone } }. Null when the board has no move
// endpoint, which is how a reorder-only board refuses a move.
export function moveRequest(moveUrl, moveParam, id, zone) {
  if (!moveUrl || !moveParam) return null

  const body = {}
  body[moveParam.resource] = {}
  body[moveParam.resource][moveParam.attr] = zone
  return { url: moveUrl.replace(":id", encodeURIComponent(id)), body }
}

// What SortableJS is created with for one zone. No group keeps a drag inside
// its zone. A locked card joins the undraggable filter, and onMove refuses a
// drag that would cross one, so a pinned card keeps its slot.
export function sortableOptions(config, { onStart, onEnd }) {
  const locked = config.lockedSelector
  const options = {
    animation: 150,
    ghostClass: "opacity-30",
    draggable: config.cardSelector,
    filter: locked ? `${config.sortFilter}, ${locked}` : config.sortFilter,
    onStart,
    onEnd
  }
  if (config.groupName) options.group = config.groupName
  if (config.handle) options.handle = config.handle
  if (locked) {
    options.onMove = (event) => !(event.related && event.related.matches && event.related.matches(locked))
  }
  return options
}

// ---- a card leaving on a Turbo `remove` stream -----------------------------

// What a `remove` stream does to a card:
//   "ignore"    not this board's stream: another action, another dom id
//               prefix, or no data-exit-action. Turbo renders it untouched.
//   "reparent"  an archive exit on a board whose archive column is on the
//               page: the card moves into that column and stays.
//   "remove"    the card animates out and Turbo removes it.
export function exitPlan({ action, target, exitAction, domIdPrefix, archiveZone, archiveZonePresent }) {
  if (action !== "remove") return "ignore"
  if (!exitAction || String(target || "").indexOf(domIdPrefix) !== 0) return "ignore"
  if (exitAction === "archive" && archiveZone && archiveZonePresent) return "reparent"
  return "remove"
}

// The exit animation: an archive sinks and shrinks, a delete shrinks.
export function exitAnimation(kind) {
  const archive = kind === "archive"
  return {
    frames: archive
      ? [{ opacity: 1, transform: "translateY(0) scale(1)" }, { opacity: 0, transform: "translateY(18px) scale(0.86)" }]
      : [{ opacity: 1, transform: "scale(1)" }, { opacity: 0, transform: "scale(0.6)" }],
    timing: { duration: archive ? 500 : 420, easing: "cubic-bezier(.35,0,.2,1)", fill: "forwards" }
  }
}

// ---- SortableJS, fetched once ----------------------------------------------

// SortableJS itself is a constructor. window.Sortable can also hold the
// loading shim below, which is a plain object.
export function isSortable(candidate) {
  return typeof candidate === "function" && typeof candidate.create === "function"
}

let sortableLoad = null

// Resolves with SortableJS. The vendored build is a classic script that assigns
// window.Sortable; a host that pins its own "sortablejs" may export it instead.
// A failed load is forgotten, so the next board tries again.
export function loadSortable({ win = window, importer = () => import("sortablejs") } = {}) {
  if (isSortable(win.Sortable)) return Promise.resolve(win.Sortable)
  if (sortableLoad) return sortableLoad

  sortableLoad = Promise.resolve()
    .then(importer)
    .then((module) => {
      const loaded = [module && module.default, module && module.Sortable, win.Sortable].find(isSortable)
      if (!loaded) throw new Error("SortableJS loaded without defining Sortable")
      if (!isSortable(win.Sortable)) win.Sortable = loaded
      return loaded
    })
    .catch((error) => {
      sortableLoad = null
      throw error
    })
  return sortableLoad
}

// window.Sortable until SortableJS is on the page: a page script that calls
// Sortable.create(el, options) loads the library with that call, and the
// sortable is created when it arrives. SortableJS replaces this object when it
// loads. create() returns nothing; a caller that needs the instance awaits
// load(), which resolves with SortableJS.
export function sortableShim(load, report) {
  const complain = report || ((error) => console.error("[studio] SortableJS failed to load", error))
  return {
    studioShim: true,
    load,
    create(element, options) {
      load().then((Sortable) => Sortable.create(element, options)).catch(complain)
    }
  }
}

// ---- the scope and its controller find each other --------------------------

// A data-studio-controller value that names the board controller once.
export function withBoardController(value) {
  const names = String(value || "").split(/\s+/).filter(Boolean)
  if (names.indexOf(CONTROLLER) === -1) names.push(CONTROLLER)
  return names.join(" ")
}

const scopes = new WeakMap()
const waiting = new WeakMap()

// The factory's init announces its scope for the element it sits on.
export function announceScope(element, scope) {
  scopes.set(element, scope)
  const resolvers = waiting.get(element) || []
  waiting.delete(element)
  resolvers.forEach((resolve) => resolve(scope))
}

// Resolves with the element's board scope, now or when Alpine initialises it.
// The controller may connect before or after Alpine reaches the element.
export function scopeFor(element) {
  if (scopes.has(element)) return Promise.resolve(scopes.get(element))
  return new Promise((resolve) => {
    waiting.set(element, (waiting.get(element) || []).concat(resolve))
  })
}

// ---- the Alpine scope ------------------------------------------------------

// x-data="studioBoard({...})". Every name on the returned object is one a
// consumer's markup or script may read: a board's header slot binds `state`
// and the three state helpers, and a host reaches toast(), updateCounts() and
// animateCardExit() through Alpine.$data.
export function studioBoard(opts, { win = window, doc = document } = {}) {
  opts = opts || {}
  return {
    ...boardConfig(opts),

    toasts: [],
    // Board-level chrome state: a header slot's controls and a column's
    // show_expr bind to it, so a board with filters needs no wrapper component.
    state: (opts.state && typeof opts.state === "object") ? opts.state : {},

    // Alpine runs this while it is still walking the subtree. It only makes the
    // scope findable: the board controller wires the zones (wire, below).
    init() {
      const element = this.$el
      const named = withBoardController(element.getAttribute(CONTROLLER_ATTRIBUTE))
      if (element.getAttribute(CONTROLLER_ATTRIBUTE) !== named) element.setAttribute(CONTROLLER_ATTRIBUTE, named)
      announceScope(element, this)
    },

    // Makes the board interactive: the zones become sortable, a live board
    // starts watching its zones, and the element is marked ready. `Sortable` is
    // null when the library failed to load; the board then still renders, counts
    // and follows live updates.
    //
    // data-alpine-ready is set after the next tick, so it means "the directives
    // are bound and the zones drag". A test waits on it before it drags.
    //
    // Returns the function that undoes it.
    wire(Sortable) {
      const element = this.$el
      const sortables = this.initSortables(Sortable)
      const observers = this.live ? this.observeLive() : []
      if (this.live && !this.fx()) this.installExitStreamFallback()

      let wired = true
      this.$nextTick(() => { if (wired) element.dataset.alpineReady = "true" })

      return () => {
        wired = false
        delete element.dataset.alpineReady
        sortables.forEach((sortable) => { if (sortable && sortable.destroy) sortable.destroy() })
        observers.forEach((observer) => observer.disconnect())
      }
    },

    // This board's own zones. A page may hold several boards, and each wires,
    // watches and counts only the zones inside its element.
    zones() {
      return Array.prototype.slice.call((this.$el || doc).querySelectorAll(this.zoneSelector))
    },

    fx() { return this.fxName ? win[this.fxName] : null },
    cardId(el) { return el ? el.getAttribute("data-" + this.idAttr) : null },
    zoneKey(el) { return el ? el.getAttribute("data-" + this.zoneAttr) : null },
    label(zone) { return this.labels[zone] || zone },

    // ---- chrome state helpers --------------------------------------------
    toggleState(key) { this.state[key] = !this.state[key] },
    listHas(key, value) {
      return Array.isArray(this.state[key]) && this.state[key].indexOf(value) !== -1
    },
    toggleInState(key, value) {
      if (!Array.isArray(this.state[key])) this.state[key] = []
      const index = this.state[key].indexOf(value)
      if (index === -1) { this.state[key].push(value) } else { this.state[key].splice(index, 1) }
    },

    // ---- SortableJS --------------------------------------------------------
    // One sortable per zone. Returns them, so wire() can destroy them.
    initSortables(Sortable) {
      Sortable = Sortable || win.Sortable
      if (!isSortable(Sortable)) return []

      const options = sortableOptions(this, {
        onStart: () => { win.__studioBoardDragging = true },
        onEnd: (event) => {
          this.handleSortEnd(event)
          win.requestAnimationFrame(() => { win.__studioBoardDragging = false })
        }
      })
      return this.zones().map((zone) => Sortable.create(zone, { ...options }))
    },

    // A drop in another zone moves the card and then saves that zone's order. A
    // drop in the same zone only saves the order. A refused move is reverted
    // and saves nothing.
    handleSortEnd(event) {
      const card = event.item
      const fromZone = event.from
      const toZone = event.to
      const moved = isLaneMove(fromZone, toZone)

      const afterMove = (ok) => {
        if (moved && !ok) return
        this.saveOrder(toZone)
        this.updateCounts()
      }

      if (moved) {
        Promise.resolve(this.applyMove(card, fromZone, toZone, this.cardId(card))).then(afterMove)
      } else {
        afterMove(true)
      }
    },

    // A move between zones. Resolves true when the card stays in its new zone.
    applyMove(card, fromZone, toZone, id) {
      const newZone = this.zoneKey(toZone)
      const fromKey = this.zoneKey(fromZone)
      const request = moveRequest(this.moveUrl, this.moveParam, id, newZone)

      // No move endpoint: a demo board still reflects the move, and any other
      // board snaps the card back, so a stray drag cannot mismove it.
      if (!request) {
        if (this.demo) {
          this.setCardZone(card, newZone)
          this.emit("board-moved", id, fromKey, newZone)
          return true
        }
        this.revert(card, fromZone)
        return false
      }

      const landed = () => {
        this.setCardZone(card, newZone)
        this.toast("Moved to " + this.label(newZone), "success")
        this.emit("board-moved", id, fromKey, newZone)
        this.hook(this.onMoveHook, { record: id, from: fromKey, to: newZone })
        return true
      }

      if (this.demo) return landed()

      // request() rejects on a refusal with the server's own message, so the
      // catch is the one failure path.
      return this.request(request.url, "PATCH", request.body).then(landed).catch((error) => {
        if (this.optimistic) this.revert(card, fromZone)
        this.toast((error && error.message) || "Move failed", "error")
        this.updateCounts()
        return false
      })
    },

    // Saves a zone's order: POSTs its ranked ids under the app's key.
    //
    // A REFUSAL IS SHOWN. request() rejects on a 4xx and the catch toasts what
    // the server said ("That order does not match this week's games — reload
    // and try again").
    //
    // NOTHING IS REVERTED. The whole column re-ranked, and SortableJS hands
    // over the drop with the order before it already gone. A reorder endpoint's
    // refusal tells the operator to reload, which restores the stored order; the
    // board's job is that the instruction is read.
    //
    // RESOLVES true or false and never rejects, so the call in handleSortEnd,
    // which nothing awaits, cannot raise an unhandled rejection.
    saveOrder(toZone) {
      const ids = rankedIds(toZone, this.cardSelector, this.idAttr)
      const zone = this.zoneKey(toZone)
      this.emit("board-reordered", null, zone, zone, { ids, zone })
      this.hook(this.onDropHook, { ids, zone })
      if (this.demo || !this.reorderUrl) return Promise.resolve(true)

      return this.request(this.reorderUrl, "POST", reorderBody(this.reorderPayload, ids, zone))
        .then(() => true)
        .catch((error) => {
          this.toast((error && error.message) || "Order save failed — reload and try again.", "error")
          return false
        })
    },

    setCardZone(card, zone) { card.setAttribute("data-" + this.zoneAttr, zone) },

    // A refused move: the card goes back into the zone it left, above the empty
    // state, and flashes a red ring.
    revert(card, fromZone) {
      const anchor = this.emptySelector ? fromZone.querySelector(this.emptySelector) : null
      fromZone.insertBefore(card, anchor)
      card.classList.add("ring-2", "ring-red-500")
      setTimeout(() => { card.classList.remove("ring-2", "ring-red-500") }, 1500)
    },

    // A host may wrap this on its own scope (the hub's task board adds the
    // cards a capped column keeps off the page).
    updateCounts() {
      const zones = {}
      this.zones().forEach((zone) => { zones[zone.id] = zone })

      const badges = (this.$el || doc).querySelectorAll("[data-board-count]")
      badges.forEach((badge) => {
        const zone = zones["dropzone-" + badge.getAttribute("data-board-count")]
        if (!zone) return
        const count = zone.querySelectorAll(this.cardSelector).length
        badge.textContent = count
        if (this.emptySelector) {
          const empty = zone.querySelector(this.emptySelector)
          if (empty) empty.style.display = count === 0 ? "flex" : "none"
        }
      })
    },

    // ---- live updates (Turbo Streams) --------------------------------------
    // The board subscribes with turbo_stream_from, and Turbo patches the DOM on
    // every broadcast. These observers add what Turbo does not: an entrance on
    // each card it patches in (window[fx].onAdd when the app names one) and a
    // recount after any change to a zone. Returns the observers.
    observeLive() {
      const onChange = (mutations) => {
        mutations.forEach((mutation) => {
          mutation.addedNodes.forEach((node) => {
            if (node.nodeType !== 1 || !node.matches || !node.matches(this.cardSelector)) return
            const fx = this.fx()
            if (fx && fx.onAdd) { fx.onAdd(node) } else { this.animateIn(node) }
            this.emit("card-added", this.cardId(node), null, this.zoneKey(node.parentElement))
          })
        })
        this.updateCounts()
      }
      return this.zones().map((zone) => {
        const observer = new win.MutationObserver(onChange)
        observer.observe(zone, { childList: true })
        return observer
      })
    },

    animateIn(el) {
      el.style.opacity = "0"
      el.style.transform = "scale(0.96)"
      el.classList.add("ring-2", "ring-primary")
      win.requestAnimationFrame(() => {
        el.style.transition = "opacity 300ms ease, transform 300ms ease"
        el.style.opacity = ""
        el.style.transform = ""
      })
      setTimeout(() => { el.classList.remove("ring-2", "ring-primary"); el.style.transition = "" }, 900)
    },

    // A Turbo `remove` stream carrying data-exit-action animates its card out
    // (exitPlan says which way). Installed once per page, by the first live
    // board with no fx module; a board with one leaves exits to it.
    installExitStreamFallback() {
      if (win.__studioBoardExitFallback) return
      win.__studioBoardExitFallback = true

      doc.addEventListener("turbo:before-stream-render", (event) => {
        const stream = event.target
        const target = stream.getAttribute("target") || ""
        const exitAction = stream.dataset.exitAction
        const archive = this.archiveZone ? doc.getElementById("dropzone-" + this.archiveZone) : null
        const plan = exitPlan({
          action: stream.getAttribute("action"),
          target,
          exitAction,
          domIdPrefix: this.domIdPrefix,
          archiveZone: this.archiveZone,
          archiveZonePresent: !!archive
        })
        if (plan === "ignore") return

        const renderNow = event.detail.render
        event.detail.render = (streamElement) => {
          const card = doc.getElementById(target)
          if (!card) { renderNow(streamElement); return }

          this.animateCardExit(card, exitAction).then(() => {
            if (plan === "reparent") {
              const anchor = this.emptySelector ? archive.querySelector(this.emptySelector) : null
              archive.insertBefore(card, anchor)
              this.setCardZone(card, this.archiveZone)
              this.resetCardExit(card)
            } else {
              renderNow(streamElement)
            }
            this.updateCounts()
          })
        }
      })
    },

    // Marks which exit is running (data-exit-action) before anything else, so
    // the marker is there even when reduced motion skips the animation.
    animateCardExit(card, kind) {
      if (!card) return Promise.resolve()
      card.dataset.exitAction = kind
      if (win.matchMedia("(prefers-reduced-motion: reduce)").matches) return Promise.resolve()

      card.style.pointerEvents = "none"
      const { frames, timing } = exitAnimation(kind)
      return card.animate(frames, timing).finished.catch(() => {})
    },

    // Clears an exit animation and its marker, so a re-parented card is fully
    // visible in the archive column.
    resetCardExit(card) {
      if (!card) return
      card.getAnimations({ subtree: false }).forEach((animation) => animation.cancel())
      delete card.dataset.exitAction
      card.style.pointerEvents = ""
      card.style.opacity = ""
      card.style.transform = ""
      card.style.filter = ""
    },

    // ---- toasts ------------------------------------------------------------
    // A board rendered with toasts: false alerts an error instead, so a refusal
    // still reaches the operator.
    toast(message, type) {
      if (!this.toastsEnabled) {
        if (type === "error" && typeof win.alert === "function") win.alert(message)
        return
      }
      const id = Date.now() + Math.random()
      this.toasts.push({ id, message, type, visible: true })
      setTimeout(() => {
        const toast = this.toasts.find((entry) => entry.id === id)
        if (toast) toast.visible = false
        setTimeout(() => { this.toasts = this.toasts.filter((entry) => entry.id !== id) }, 300)
      }, 3000)
    },

    // ---- the one HTTP seam -------------------------------------------------
    // REJECTS ON A SERVER REFUSAL, which neither fetcher underneath does:
    //   - window.fetch resolves on a 4xx or 5xx, so a bare catch sees a network
    //     failure and nothing else;
    //   - window.authedFetch (turf-monster's, used when the host defines it)
    //     resolves with the response for anything but a 401, and with null on
    //     an expired session or a rate-limited tier.
    // Both are normalised here, so a caller ignores a refusal only by saying so
    // in its own catch. The message is the server's own { error: "…" }, which
    // every board endpoint writes for the operator to read.
    request(url, method, body) {
      const csrf = (doc.querySelector('meta[name="csrf-token"]') || {}).content || ""
      const fetcher = win.authedFetch || win.fetch
      return fetcher(url, {
        method,
        headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf, "Accept": "application/json" },
        body: JSON.stringify(body || {})
      }).then((response) => {
        if (!response) throw new Error("Session expired — please sign in again.")
        if (response.ok) return response
        return response.json().catch(() => ({})).then((refusal) => {
          throw new Error(refusal.error || ("Failed (" + response.status + ")"))
        })
      })
    },

    // The extension seam: an app listens for these on window.
    emit(name, record, from, to, extra) {
      try {
        const detail = Object.assign({ record, from, to }, extra || {})
        win.dispatchEvent(new win.CustomEvent("studio:" + name, { detail }))
      } catch (error) {}
    },

    hook(hookName, detail) {
      if (!hookName) return
      const fn = win[hookName]
      if (typeof fn === "function") { try { fn(detail) } catch (error) {} }
    }
  }
}
