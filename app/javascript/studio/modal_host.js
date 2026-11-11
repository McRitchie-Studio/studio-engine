// studio/modal_host: the modal stack behind studio/modals/_host ($store.modals)
// and studio/modals/_scoped_host ($store.<name>), the focus trap both share, the
// animation and card-width registries, and the load-hold convention.
//
// WHAT USED TO BE HERE. Each partial carried this as an inline <script>: the
// shared host four of them (its store, its registry, its cleanup, and the
// load convention it rendered), the scoped host one more copy of the stack. An
// inline script carries no CSP nonce, and two copies of one focus trap drift.
// The partials now render markup only; each host's <template> carries
//
//   data-studio-controller="modal-host"
//   data-modal-host-store-value="modals"     (the scoped host: its own name)
//   data-modal-host-scoped-value="true"      (the scoped host only)
//
// and studio/controllers/modal_host_controller registers the host's store when
// the element connects.
//
// WHEN A STORE REGISTERS, AND WHY NOT IN connect(). Alpine evaluates
// $store.<name>.current() as it starts, which is BEFORE Stimulus connects any
// controller (Alpine starts in a microtask after its deferred script; Stimulus
// waits for DOMContentLoaded). So the stores register from this module, by
// three paths, and each registers only a store Alpine does not already have
// (a host's own wins, and a host rendered twice registers once):
//
//   1. alpine:init, on a full load: every host element in the parsed document.
//      The only path that is early enough there.
//   2. turbo:before-render and turbo:before-frame-render: every host element
//      in the incoming body or frame, before Alpine sees it. Alpine fires
//      alpine:init once per document, so a page that brings its own scoped
//      host on a Turbo visit needs a later path.
//   3. the controller's connect(), for a Turbo visit too and for markup
//      inserted any other way.
//
// MEASURED on a consumer (moms-app, a Turbo visit from /profile to
// /profile/edit, which brings profileModals): path 2 alone and path 3 alone
// each register the store before Alpine reads it; with both removed the visit
// throws "Cannot read properties of undefined (reading 'current')".
//
// THE WINDOW GLOBALS. window.ModalAnimations and window.StudioModals
// (CARD_WIDTHS, DEFAULT_CARD_WIDTH, MIN_LOAD_MS, holdAtLeast) are published
// here on every page, each merged over whatever a host defined first, so an
// app's own entries survive.
//
// WHY THIS IS ITS OWN ENTRY POINT. layouts/studio/_head imports this module by
// its own nonced module tag as well as through the boot graph (the controller
// imports it), like studio/alpine_stores, so a boot that fails to load does
// not take the modal stack with it. It imports nothing, and
// test/javascript/modal_host.test.mjs holds it to that.

// The exit keyframes' duration: a closing entry is spliced off the stack this
// long after close(). Keep it equal to .modal-card-unmount and
// .modal-card-swap-out[-back] in studio/modals/_host and engine-motion.css.
export const CLOSE_ANIM_MS = 220
// The slide-in keyframe's duration, .modal-card-swap-in[-back].
export const SWAP_IN_MS = 220

// The engine's named animations. Each key maps to a CSS class (the keyframes
// ship in studio/modals/_host and in engine-motion.css) and its duration in ms,
// which close() waits before splicing. Open a modal with
// { enterAnim: 'shake' } or { exitAnim: 'slide' }; omitted, it uses 'pop'.
// The directional swap()/advance() slide is separate and always uses the
// modal-card-swap-* classes.
export const ANIMATION_DEFAULTS = {
  enter: {
    pop:   { cls: 'modal-card-mount',    ms: 320 },  // spring bounce in
    shake: { cls: 'modal-card-shake-in', ms: 600 },  // a "not quite yet" nope
    slide: { cls: 'modal-card-swap-in',  ms: 220 }   // slide in from the left
  },
  exit: {
    pop:   { cls: 'modal-card-unmount',  ms: 220 },  // anticipation, then fall
    slide: { cls: 'modal-card-swap-out', ms: 220 }   // slide out to the right
  }
}

// The card width an id gets when CARD_WIDTHS names no width for it. A literal
// floor too: a width that fails to resolve renders a full-bleed card.
export const DEFAULT_CARD_WIDTH = 'max-w-sm'

// The standard minimum a load spinner stays up, in ms. Below about a second it
// flashes and reads as a glitch. See studio/modals/blocks/_processing_card.
export const MIN_LOAD_MS = 1400

// An app's animation entries merged OVER the engine defaults, per channel, so
// adding an animation never means redefining pop, shake or slide.
export function mergeAnimations(overrides) {
  var o = overrides || {}
  return {
    enter: Object.assign({}, ANIMATION_DEFAULTS.enter, o.enter || {}),
    exit:  Object.assign({}, ANIMATION_DEFAULTS.exit,  o.exit  || {})
  }
}

// The animation for a key, read from win.ModalAnimations at CALL time and never
// undefined. A script loading after this one may replace the registry
// wholesale; a miss would make close() throw on .ms and strand the modal open,
// so an unknown key, or a gutted registry, falls back to the built-in 'pop'.
export function modalAnim(win, channel, key) {
  var table = (win.ModalAnimations && win.ModalAnimations[channel]) || {}
  return table[key] || table.pop || ANIMATION_DEFAULTS[channel].pop
}

// The card width for a modal id: CARD_WIDTHS by id, else DEFAULT_CARD_WIDTH,
// else the literal floor. BY ID, NOT BY PROP: a card opened from several places
// would otherwise have to carry the prop at every opener (turf-monster's
// wallet-setup opens from three), and one miss renders it at two widths.
export function modalCardWidth(win, id) {
  var sm = win.StudioModals || {}
  return (sm.CARD_WIDTHS && sm.CARD_WIDTHS[id]) || sm.DEFAULT_CARD_WIDTH || DEFAULT_CARD_WIDTH
}

// holdAtLeast(minMs).then(cb) fires cb at max(minMs, time since the call):
// stamp it when a loading view appears, so a fast operation still shows its
// spinner and a slow one is never cut short.
export function holdAtLeast(minMs, clock) {
  var now = (clock && clock.now) || Date.now
  var later = (clock && clock.later) || function (fn, ms) { setTimeout(fn, ms) }
  var startedAt = now()
  return {
    then: function (callback) {
      var remaining = Math.max(0, minMs - (now() - startedAt))
      if (remaining === 0) { callback(); return }
      later(callback, remaining)
    }
  }
}

// Publishes the registries and the load-hold convention on win, each merged
// over (or kept from) what the host already defined.
export function installModalGlobals(win) {
  win.ModalAnimations = mergeAnimations(win.ModalAnimations)

  var sm = win.StudioModals = win.StudioModals || {}
  sm.CARD_WIDTHS = Object.assign({}, sm.CARD_WIDTHS || {})
  sm.DEFAULT_CARD_WIDTH = sm.DEFAULT_CARD_WIDTH || DEFAULT_CARD_WIDTH
  sm.MIN_LOAD_MS = sm.MIN_LOAD_MS || MIN_LOAD_MS
  sm.holdAtLeast = sm.holdAtLeast || function (minMs) { return holdAtLeast(minMs) }
}

// ---- the focus trap, shared by both stores --------------------------------
//
// THE RETURN TARGET AND THE BACKDROP LIVE IN A CLOSURE, NOT ON THE STORE.
// Alpine.store() wraps its object in a reactive Proxy, so a DOM node assigned
// to a store property reads back as a proxy of that node, and every identity
// check against it (===, contains(), Set membership) is false forever. Focus
// code is full of identity checks.
//
// THE RE-MOUNT SEAMS. captureFocus runs from x-init on the backdrop, which
// lives inside <template x-if="current()">. Any change that keeps current()
// truthy (a swap, an advance, a push onto a non-empty stack, a close down to
// an underlying card, a dismissible sweep that leaves a card) never re-mounts
// that outer template, so x-init never runs again, while the INNER content
// template does re-mount and unmounts whatever was focused. Focus falls to the
// document body, which is not a descendant of the backdrop, the Tab handler
// bound there stops seeing the key, and native tabbing walks out to the page
// behind. Each of those seams calls refocus().
function focusTrap(env, held) {
  var doc = env.doc
  var win = env.win
  return {
    // Focuses the backdrop itself rather than the first control: landing on a
    // button means a stray Enter fires it, and a destructive card should not
    // be one keystroke from confirming.
    captureFocus: function (el) {
      held.returnFocusTo = doc.activeElement
      held.backdrop = el
      if (el && el.focus) el.focus()
    },

    // Puts focus back on the backdrop after the top entry changes, without
    // re-capturing the return target: re-capturing would overwrite the opener
    // with a node inside the dialog. Deferred a tick, because the re-mount that
    // unfocuses the old node happens during Alpine's update.
    refocus: function () {
      var run = function () {
        if (held.backdrop && held.backdrop.focus && doc.contains(held.backdrop)) held.backdrop.focus()
      }
      if (win.Alpine && win.Alpine.nextTick) win.Alpine.nextTick(run)
      else win.setTimeout(run, 0)
    },

    // Restores focus only to a node still in the document: a Turbo visit can
    // replace the page under an open modal, and focusing a detached node moves
    // focus to the body, which is worse than leaving it alone.
    releaseFocus: function () {
      var target = held.returnFocusTo
      held.returnFocusTo = null
      held.backdrop = null
      if (target && target.focus && doc.contains(target)) target.focus()
    },

    // Every tabbable node inside the dialog, in document order, recomputed per
    // keypress: a card can add or remove controls while open.
    focusables: function (el) {
      if (!el) return []
      var sel = 'a[href], button:not([disabled]), input:not([disabled]), ' +
                'select:not([disabled]), textarea:not([disabled]), [tabindex]'
      return Array.prototype.slice.call(el.querySelectorAll(sel)).filter(function (n) {
        return n.tabIndex >= 0 && n.offsetParent !== null
      })
    },

    // Tab is intercepted on the backdrop (.prevent) and re-dispatched here.
    // That holds only while focus is inside the backdrop, which is why
    // refocus() exists.
    cycleFocus: function (el, event) {
      var items = this.focusables(el)
      if (items.length === 0) { if (el && el.focus) el.focus(); return }

      var idx = items.indexOf(doc.activeElement)
      var next
      if (event && event.shiftKey) {
        next = idx <= 0 ? items[items.length - 1] : items[idx - 1]
      } else {
        next = (idx === -1 || idx === items.length - 1) ? items[0] : items[idx + 1]
      }
      next.focus()
    },

    // The dialog's accessible name: props.ariaLabel, else props.title, else the
    // id. TRIMMED, not merely truthy: a whitespace-only title trims to empty in
    // the accessible-name computation and announces a bare "dialog".
    dialogLabel: function () {
      var entry = this.current()
      if (!entry) return 'Dialog'
      var p = entry.props || {}
      var named = function (v) { return (typeof v === 'string' && v.trim() !== '') ? v : null }
      return named(p.ariaLabel) || named(p.title) || String(entry.id).replace(/[-_]/g, ' ')
    },

    // isOpen(id): on the stack in ANY lifecycle state. A card mid-close still
    // counts, for the whole exit window; callers asking "is the node still
    // mounted" depend on that. isLive() is the "is it still up" question.
    isOpen: function (id) {
      for (var i = 0; i < this.stack.length; i++) {
        if (this.stack[i].id === id) return true
      }
      return false
    },

    // isLive(id) / isLive([id, ...]): on the stack and NOT on its way out.
    // Tests _closing ALONE. close() sets _closing; the entry a swap() replaces
    // carries _swappingOut AND _closing; advance() sets only _swappingOut, and
    // that card, sliding between steps of its own flow, stays live.
    isLive: function (id) {
      var ids = Array.isArray(id) ? id : [id]
      for (var i = 0; i < this.stack.length; i++) {
        var entry = this.stack[i]
        if (entry && !entry._closing && ids.indexOf(entry.id) !== -1) return true
      }
      return false
    },

    current: function () {
      return this.stack.length ? this.stack[this.stack.length - 1] : null
    },

    // No animation: the Turbo and bfcache teardown, where the page is going
    // away, so the return target is dropped rather than restored into it.
    closeAll: function () {
      held.returnFocusTo = null
      this.stack = []
      this._sync()
    },

    // Drops every entry that does not opt out with dismissible: false. A card
    // guarding an in-flight operation (an on-chain transaction) survives a
    // back/forward navigation, so the promise still resolves against it; a
    // celebratory card is cleared. A surviving card is refocused (the dropped
    // cards took focus with them); nothing is restored when the stack empties,
    // since this is the teardown path.
    closeAllDismissible: function () {
      this.stack = this.stack.filter(function (entry) {
        return entry.props && entry.props.dismissible === false
      })
      this._sync()
      if (this.stack.length > 0) this.refocus()
    },

    // The scroll lock: body.modal-open while the stack is non-empty.
    _sync: function () {
      if (this.stack.length) doc.body.classList.add('modal-open')
      else doc.body.classList.remove('modal-open')
    }
  }
}

// ---- on-demand modals (Studio.modals) ---------------------------------------
//
// A host whose app registers modals with Studio.modals advertises them on its
// template:
//
//   data-modal-host-remote-value='{"url":"/_studio/modals/__id__",
//                                  "ids":["contest-rules",…],"prefetch":["auth"]}'
//
// and marks its card data-modal-host-card. open(id) for an advertised id whose
// registration is not in the host yet fetches GET /_studio/modals/<id> once,
// wraps the fragment in the same <template x-if> a layout would have rendered,
// appends it to the card (in the host template's content, so every later mount
// has it, and in a card already on screen), then opens. An id the host does not
// advertise takes the plain open() path untouched.
//
// THE WAIT. A fetch that answers inside LOAD_DELAY_MS opens with no loading
// state at all. A slower one opens the card with $store.modals._remote[id] =
// 'loading' (the host's processing card), held at least MIN_LOAD_MS so it never
// flashes, then clears the flag and the content takes its place. A failure sets
// 'error' (the host's error card) and forgets the fetch, so the next open
// retries. So for the first LOAD_DELAY_MS of a first open, isOpen(id) is false.
//
// THE TIMEOUT. A fetch that has not answered in cfg.timeout_ms (the server's
// Studio.modals.fetch_timeout_ms, else DEFAULT_FETCH_TIMEOUT_MS) is aborted and
// shows the error card. Its Try again (retryRemote) re-runs the fetch with the
// card in place; its Close calls close() directly, so a card opened
// dismissible: false still has a way out.
//
// THE CACHE: fragments by id, beside the store, not on it, keyed on the
// session. A Turbo visit brings a fresh host without the inserted templates
// (or a snapshot clone with them), so insertion checks the host every time and
// inserts only what is missing; that check is what keeps a Turbo visit from
// inserting a modal twice. A fetch that resolves after a Turbo visit replaced
// the body (doc.body changed) opens nothing on the new page.
//
// THE SESSION KEY. A fragment can carry the viewer's data and a form's CSRF
// token, and a Turbo visit across sign-in, sign-out or a user switch keeps the
// document, and with it this cache. So the host advertises cfg.session, a
// digest of the session id and the signed-in user id (Studio::Modals.
// session_marker), and every open and every turbo:load compares it: a change
// drops every cached fragment, every fetch in flight, and every template
// already inserted on this page. Why that signal: the session id is what
// reset_session rotates, and the CSRF secret rotates with it, so a cached form
// token goes stale exactly when it changes; the user id catches a sign-in
// that keeps the session. The page's csrf-token meta would not do: it is
// masked afresh on every render, so it would empty the cache on every visit.
//
// THE SCRIPT RULE. A fragment containing a <script> is refused, never
// inserted: an inserted script would run (or not) by accident of how Alpine
// clones the template, and it carries no CSP nonce. It shows the error card;
// with cfg.debug (development and test) the card names the reason. There is
// no console output in either case.
//
// PREFETCH runs when the browser idles after the first load AND after every
// Turbo visit (turbo:load), so a page reached by Turbo prefetches what it
// flags, for the viewer it was rendered for.

export const REMOTE_MODAL_ATTR = 'data-studio-remote-modal'
export const LOAD_DELAY_MS = 150
export const DEFAULT_FETCH_TIMEOUT_MS = 8000
export const REMOTE_ERROR_TEXT = 'Check your connection and try again.'

// The host template advertising on-demand modals, if this page has one.
export function remoteHost(doc) {
  return doc.querySelector ? doc.querySelector('template[data-modal-host-remote-value]') : null
}

// The advertised config, or null on a page without one (or with bad JSON).
export function remoteConfig(doc) {
  var el = remoteHost(doc)
  if (!el) return null
  try {
    var cfg = JSON.parse(el.getAttribute('data-modal-host-remote-value'))
    if (!cfg || typeof cfg.url !== 'string' || !Array.isArray(cfg.ids)) return null
    if (!Array.isArray(cfg.prefetch)) cfg.prefetch = []
    if (!(cfg.timeout_ms > 0)) cfg.timeout_ms = DEFAULT_FETCH_TIMEOUT_MS
    if (typeof cfg.session !== 'string') cfg.session = ''
    return cfg
  } catch (e) {
    return null
  }
}

// The <template x-if> a layout would have rendered around the partial. Ids are
// held to [a-z0-9_-] by Studio::Modals, so splicing one into the expression
// needs no escaping; anything else is refused before it gets here.
export function remoteTemplate(doc, id, markup) {
  var t = doc.createElement('template')
  t.setAttribute(REMOTE_MODAL_ATTR, id)
  t.setAttribute('x-if', "$store.modals.current()?.id === '" + id + "' && !$store.modals._remote['" + id + "']")
  t.innerHTML = markup
  return t
}

// Every card the fragment belongs in: the one inside the host template's
// content, and any mounted on screen.
function remoteCards(doc) {
  var cards = []
  var host = remoteHost(doc)
  var inner = host && host.content && host.content.querySelector('[data-modal-host-card]')
  if (inner) cards.push(inner)
  var live = doc.querySelectorAll ? doc.querySelectorAll('[data-modal-host-card]') : []
  for (var i = 0; i < live.length; i++) cards.push(live[i])
  return cards
}

function hasRemote(card, id) {
  var kids = card.children || []
  for (var i = 0; i < kids.length; i++) {
    if (kids[i].getAttribute && kids[i].getAttribute(REMOTE_MODAL_ATTR) === id) return true
  }
  return false
}

// Appends the registration to every card missing it. Answers whether the host
// template now carries it (false: no marked card on this page).
export function insertRemoteModal(doc, id, markup) {
  var cards = remoteCards(doc)
  if (cards.length === 0) return false
  for (var i = 0; i < cards.length; i++) {
    if (!hasRemote(cards[i], id)) cards[i].appendChild(remoteTemplate(doc, id, markup))
  }
  return true
}

export function remoteModalUrl(cfg, id) {
  return cfg.url.replace('__id__', encodeURIComponent(id))
}

// A refused fragment's error. Its message is shown only with cfg.debug.
function remoteError(message) {
  var err = new Error(message)
  err.studioModal = true
  return err
}

// True when the markup carries a <script> element. A text match, not a parse:
// the fragment is server-rendered, so this guards an app's own mistake, and a
// false positive (the word in an attribute) errs on the safe side.
export function fragmentHasScript(markup) {
  return /<script[\s>\/]/i.test(String(markup))
}

// One fetch. Rejects unless the answer is the fragment the endpoint sends
// (X-Studio-Modal names the id): a host filter's redirect to a full page, or a
// 401, is an error, never a modal. Rejects too when nothing answers inside
// cfg.timeout_ms (the request is aborted where the browser can), and when the
// fragment carries a <script>.
export function fetchRemoteModal(win, cfg, id) {
  var ms = cfg.timeout_ms > 0 ? cfg.timeout_ms : DEFAULT_FETCH_TIMEOUT_MS
  var controller = typeof win.AbortController === 'function' ? new win.AbortController() : null
  var init = {
    credentials: 'same-origin',
    headers: { 'Accept': 'text/html', 'X-Requested-With': 'XMLHttpRequest' }
  }
  if (controller) init.signal = controller.signal

  return new Promise(function (resolve, reject) {
    var settled = false
    var timer = win.setTimeout(function () {
      if (settled) return
      settled = true
      if (controller) { try { controller.abort() } catch (e) {} }
      reject(remoteError('studio/modal_host: ' + id + ' did not answer in ' + ms + 'ms'))
    }, ms)
    function finish(fn, value) {
      if (settled) return
      settled = true
      if (win.clearTimeout) win.clearTimeout(timer)
      fn(value)
    }

    win.fetch(remoteModalUrl(cfg, id), init).then(function (res) {
      if (!res.ok || !res.headers || res.headers.get('X-Studio-Modal') !== id) {
        throw remoteError('studio/modal_host: ' + id + ' answered ' + res.status)
      }
      return res.text()
    }).then(function (markup) {
      if (fragmentHasScript(markup)) {
        throw remoteError('studio/modal_host: ' + id + ' was refused: its fragment carries a <script>. ' +
                          'Move the behaviour to a module or a Stimulus controller.')
      }
      finish(resolve, markup)
    }).catch(function (err) { finish(reject, err) })
  })
}

// requestIdleCallback where the browser has it, else a timeout.
export function whenIdle(win, fn) {
  if (typeof win.requestIdleCallback === 'function') win.requestIdleCallback(fn, { timeout: 4000 })
  else win.setTimeout(fn, 1500)
}

// Removes every inserted registration from this page's cards: the session
// changed, so what they carry is stale.
function removeRemoteModals(doc) {
  var cards = remoteCards(doc)
  for (var i = 0; i < cards.length; i++) {
    var kids = Array.prototype.slice.call(cards[i].children || [])
    for (var k = 0; k < kids.length; k++) {
      if (kids[k].getAttribute && kids[k].getAttribute(REMOTE_MODAL_ATTR) !== null) {
        if (typeof cards[i].removeChild === 'function') cards[i].removeChild(kids[k])
        else if (typeof kids[k].remove === 'function') kids[k].remove()
      }
    }
  }
}

// The loader one shared store keeps in its closure.
export function createRemoteModals(env) {
  var doc = env.doc
  var win = env.win
  var pending = {}   // id -> Promise<markup>, while in flight or resolved
  var ready = {}     // id -> markup, once resolved
  var session = null // the cfg.session the cache was filled under
  var generation = 0 // bumped by a drop, so a fetch from before it caches nothing

  // Drops the cache when the advertised session differs from the one it was
  // filled under. The first config seen only sets the key.
  function sync(cfg) {
    if (!cfg) return
    if (session === null) { session = cfg.session; return }
    if (cfg.session === session) return
    session = cfg.session
    pending = {}
    ready = {}
    generation++
    removeRemoteModals(doc)
  }

  function load(cfg, id) {
    sync(cfg)
    if (ready[id] !== undefined) return Promise.resolve(ready[id])
    if (!pending[id]) {
      var gen = generation
      var mine = pending[id] = fetchRemoteModal(win, cfg, id).then(function (markup) {
        if (gen === generation) ready[id] = markup
        return markup
      }, function (err) {
        if (pending[id] === mine) delete pending[id]
        throw err
      })
    }
    return pending[id]
  }

  return {
    // The config when id is advertised here, else null. Checks the session.
    handles: function (id) {
      if (typeof id !== 'string') return null
      var cfg = remoteConfig(doc)
      sync(cfg)
      return (cfg && cfg.ids.indexOf(id) !== -1) ? cfg : null
    },
    load: load,
    // Synchronous when the fragment is already here: inserts what this host
    // lacks and answers true, so open() needs no wait.
    insertIfReady: function (id) {
      return ready[id] !== undefined && insertRemoteModal(doc, id, ready[id])
    },
    insert: function (id, markup) { return insertRemoteModal(doc, id, markup) },
    prefetch: function () {
      var cfg = remoteConfig(doc)
      sync(cfg)
      if (!cfg || typeof win.fetch !== 'function') return
      cfg.prefetch.forEach(function (id) {
        // A failed prefetch is retried by the open that needs it.
        load(cfg, id).catch(function () {})
      })
    }
  }
}

// ---- the shared host's store, $store.modals --------------------------------
//
// env is { doc, win }: the document, and the window that carries setTimeout,
// Alpine, ModalAnimations and StudioModals.
export function createModalStore(env) {
  var win = env.win
  var held = { returnFocusTo: null, backdrop: null }
  var store = focusTrap(env, held)
  store.stack = []
  // id -> 'loading' | 'error' for an on-demand modal; read by the host's
  // loading and error cards and by each fetched registration's x-if.
  store._remote = {}
  // id -> the reason the last load failed, shown on the error card only when
  // the host advertises debug (development and test).
  store._remoteReason = {}
  var remote = createRemoteModals(env)

  // open(id, props, opts)
  //   opts.replace: swap the top entry. With a visible card, a directional
  //     slide: it exits right (modal-card-swap-out) and the new one enters
  //     left; opts.direction 'back' mirrors both. A plain mount when empty.
  //   otherwise: push. Closing the new card reveals the one beneath.
  //   An on-demand id not yet in the host loads first (openRemote below).
  store.open = function (id, props, opts) {
    var cfg = remote.handles(id)
    if (cfg && !remote.insertIfReady(id)) return openRemote(this, cfg, id, props, opts, false)
    return openNow.call(this, id, props, opts)
  }

  // The error card's Try again: re-runs the current entry's fetch with the
  // entry left where it is, showing the loading card meanwhile.
  store.retryRemote = function () {
    var entry = this.current()
    if (!entry || this._remote[entry.id] !== 'error') return
    var cfg = remote.handles(entry.id)
    if (!cfg) return
    if (remote.insertIfReady(entry.id)) { delete this._remote[entry.id]; return }
    openRemote(this, cfg, entry.id, entry.props, null, true)
  }

  // The error card's message: the generic line, or with cfg.debug the reason.
  store.remoteErrorText = function () {
    var entry = this.current()
    var reason = entry && this._remoteReason[entry.id]
    return reason || REMOTE_ERROR_TEXT
  }

  // The first open of an on-demand id (or a retry, when inPlace: the entry is
  // already on the stack). Never throws and never leaves a promise unhandled:
  // every outcome is the modal, the loading card, or the error card.
  function openRemote(self, cfg, id, props, opts, inPlace) {
    var body = env.doc.body
    var shown = !!inPlace
    var hold = null
    var done = false
    var timer = null
    if (self._remote[id] === 'error') delete self._remote[id]
    delete self._remoteReason[id]
    var minLoad = function () { return (win.StudioModals && win.StudioModals.MIN_LOAD_MS) || MIN_LOAD_MS }

    if (inPlace) {
      hold = holdAtLeast(minLoad())
      self._remote[id] = 'loading'
    } else {
      timer = win.setTimeout(function () {
        if (done || env.doc.body !== body) return
        shown = true
        hold = holdAtLeast(minLoad())
        self._remote[id] = 'loading'
        openNow.call(self, id, props, opts)
      }, LOAD_DELAY_MS)
    }

    function stopTimer() { if (timer !== null && win.clearTimeout) win.clearTimeout(timer) }

    function fail(err) {
      if (done) return
      done = true
      stopTimer()
      if (env.doc.body !== body) return
      if (cfg.debug && err && err.studioModal) self._remoteReason[id] = err.message
      self._remote[id] = 'error'
      if (!shown) openNow.call(self, id, props, opts)
    }

    remote.load(cfg, id).then(function (markup) {
      if (done) return
      if (env.doc.body !== body) { done = true; stopTimer(); return }
      if (!remote.insert(id, markup)) { fail(); return }
      done = true
      stopTimer()
      if (!shown) { openNow.call(self, id, props, opts); return }
      hold.then(function () {
        if (self._remote[id] === 'loading') delete self._remote[id]
      })
    }).catch(fail)
  }

  // Schedules the advertised prefetches when the browser idles: once now, for
  // the first load, and again after every Turbo visit. load() shares one
  // request per id, so the first load's turbo:load adds no second fetch.
  if (env.doc && typeof env.doc.querySelector === 'function') {
    whenIdle(win, function () { remote.prefetch() })
    if (typeof env.doc.addEventListener === 'function') {
      env.doc.addEventListener('turbo:load', function () {
        whenIdle(win, function () { remote.prefetch() })
      })
    }
  }

  function openNow(id, props, opts) {
    props = props || {}
    opts = opts || {}
    var self = this
    var remounted = false

    if (opts.replace && this.stack.length > 0) {
      var current = this.current()
      if (current && !current._closing) {
        // Phase 1: the leaving entry slides out for CLOSE_ANIM_MS.
        var dir = (opts.direction === 'back') ? 'back' : 'forward'
        current._swapDir = dir
        current._swappingOut = true
        current._closing = true
        win.setTimeout(function () {
          // Phase 2: the swap. An entry that left the stack during the slide
          // (a second swap() hot-swapped it, or a close raced) drops this stale
          // replacement, which would otherwise resurrect a card the user
          // already navigated past.
          var idx = self.stack.indexOf(current)
          if (idx < 0) return
          var newEntry = { id: id, props: props, _swappingIn: true, _swapDir: dir }
          self.stack[idx] = newEntry
          self._sync()
          self.refocus()
          // Phase 3: clear the slide once it lands. _settled latches so the
          // mount class never snaps back on and re-fires the bounce mid-settle.
          win.setTimeout(function () {
            newEntry._swappingIn = false
            newEntry._swapDir = null
            newEntry._settled = true
          }, SWAP_IN_MS)
        }, CLOSE_ANIM_MS)
        return
      }
      // Already mid-close: hot-swap, so no second timer.
      this.stack[this.stack.length - 1] = { id: id, props: props }
      remounted = true
    } else {
      // A push onto a NON-EMPTY stack re-mounts the inner template; only the
      // first push mounts the outer one and captures through x-init.
      remounted = this.stack.length > 0
      this.stack.push({ id: id, props: props })
    }
    this._sync()
    if (remounted) this.refocus()
  }

  // swap(id, props, opts) is open(id, props, { replace: true, ...opts }).
  store.swap = function (id, props, opts) {
    return this.open(id, props, Object.assign({ replace: true }, opts || {}))
  }

  // advance(propsPatch, opts): patches the current entry's props with the same
  // directional slide as swap(), WITHOUT replacing the entry, so the card's
  // x-data scope (form state, watchers) survives a step change inside one
  // modal. A no-op with no current entry, or one closing or mid-swap, so a
  // double click stacks no timers.
  store.advance = function (propsPatch, opts) {
    opts = opts || {}
    var cur = this.current()
    if (!cur || cur._closing || cur._swappingOut) return
    var self = this
    cur._swapDir = (opts.direction === 'back') ? 'back' : 'forward'
    cur._swappingOut = true
    win.setTimeout(function () {
      // The entry left the stack during the slide (Escape mid-animation).
      if (self.stack.indexOf(cur) < 0) return
      if (propsPatch) Object.assign(cur.props, propsPatch)
      cur._swappingOut = false
      cur._swappingIn = true
      self.refocus()
      win.setTimeout(function () {
        cur._swappingIn = false
        cur._swapDir = null
        cur._settled = true
      }, SWAP_IN_MS)
    }, CLOSE_ANIM_MS)
  }

  // Flips _closing, so the exit classes bind, and splices THIS entry (not the
  // top: another open() may have run meanwhile) after its exit animation's
  // registry duration. Focus returns to the opener only when the LAST card
  // leaves; closing down to an underlying card refocuses it.
  store.close = function () {
    var self = this
    var entry = this.current()
    if (!entry || entry._closing) return
    entry._closing = true
    win.setTimeout(function () {
      var idx = self.stack.indexOf(entry)
      if (idx >= 0) {
        self.stack.splice(idx, 1)
        self._sync()
      }
      if (self.stack.length === 0) self.releaseFocus()
      else self.refocus()
    }, modalAnim(win, 'exit', entry.props && entry.props.exitAnim).ms)
  }

  // The visible card's classes: exactly one max-w-* (CARD_WIDTHS by id), the
  // enter class on a fresh mount, the exit class while closing, and the
  // directional swap-* classes during a swap or advance. The mount class is
  // gated on !_settled, so a finished swap never re-fires the bounce, and on
  // !_closing, so a close shows only the exit keyframe.
  store.cardClasses = function () {
    var c = this.current()
    if (!c) return {}
    var o = {}
    o[modalCardWidth(win, c.id)] = true
    if (!c._settled && !c._swappingIn && !c._swappingOut && !c._closing) {
      o[modalAnim(win, 'enter', c.props && c.props.enterAnim).cls] = true
    }
    if (c._closing && !c._swappingOut) {
      o[modalAnim(win, 'exit', c.props && c.props.exitAnim).cls] = true
    }
    // enter.slide and exit.slide resolve to these same class names, so a key
    // set above is never reassigned here (an unconditional false would leave
    // enterAnim/exitAnim 'slide' with no class at all).
    var swapFlags = {
      'modal-card-swap-in':       !!(c._swappingIn  && c._swapDir !== 'back'),
      'modal-card-swap-out':      !!(c._swappingOut && c._swapDir !== 'back'),
      'modal-card-swap-in-back':  !!(c._swappingIn  && c._swapDir === 'back'),
      'modal-card-swap-out-back': !!(c._swappingOut && c._swapDir === 'back')
    }
    for (var flag in swapFlags) {
      if (!(flag in o)) o[flag] = swapFlags[flag]
    }
    return o
  }

  return store
}

// ---- the scoped host's store, $store.<name> --------------------------------
//
// The same focus contract, a plainer stack: a replace swaps the top entry in
// place with no slide (what submitFormWithProgress does to turn crop-photo
// into saving), there is no advance(), and the card's classes come from the
// shared motion layer, engine-motion.css.
export function createScopedModalStore(env) {
  var win = env.win
  var held = { returnFocusTo: null, backdrop: null }
  var store = focusTrap(env, held)
  store.stack = []

  store.open = function (id, props, opts) {
    props = props || {}
    opts = opts || {}
    var entry = { id: id, props: props }
    var remounted = false
    if (opts.replace && this.stack.length > 0) {
      this.stack.splice(this.stack.length - 1, 1, entry)
      remounted = true
    } else {
      remounted = this.stack.length > 0
      this.stack.push(entry)
    }
    this._sync()
    if (remounted) this.refocus()
  }

  store.swap = function (id, props, opts) {
    opts = opts || {}
    opts.replace = true
    this.open(id, props, opts)
  }

  // Flips _closing so the exit animation plays, then splices after it.
  store.close = function () {
    var entry = this.current()
    if (!entry) return
    var self = this
    entry._closing = true
    win.setTimeout(function () {
      var index = self.stack.indexOf(entry)
      if (index !== -1) self.stack.splice(index, 1)
      self._sync()
      if (self.stack.length === 0) self.releaseFocus()
      else self.refocus()
    }, CLOSE_ANIM_MS)
  }

  // Mount on open, unmount while closing. _settled pins the entry after its
  // first render.
  store.cardClasses = function () {
    var entry = this.current()
    if (!entry) return ''
    if (entry._closing) return 'modal-card-unmount'
    if (!entry._settled) entry._settled = true
    return 'modal-card-mount'
  }

  return store
}

// ---- registration -----------------------------------------------------------

export const HOST_SELECTOR = '[data-studio-controller~="modal-host"]'

// Stimulus' own reading of a Boolean value attribute.
function booleanValue(raw) {
  return raw !== null && raw !== undefined && raw !== '0' && raw !== 'false'
}

// The host a host element declares: { store, scoped }.
export function hostConfig(el) {
  return {
    store: el.getAttribute('data-modal-host-store-value') || 'modals',
    scoped: booleanValue(el.getAttribute('data-modal-host-scoped-value'))
  }
}

// Every host declared in root (a document, a body, a frame or a fragment),
// root itself included.
export function hostsIn(root) {
  var found = []
  if (!root) return found
  if (root.matches && root.matches(HOST_SELECTOR)) found.push(hostConfig(root))
  if (root.querySelectorAll) {
    var nodes = root.querySelectorAll(HOST_SELECTOR)
    for (var i = 0; i < nodes.length; i++) found.push(hostConfig(nodes[i]))
  }
  return found
}

// Registers a host's store unless Alpine already has one of that name.
// Answers whether it registered.
export function registerModalStore(Alpine, host, env) {
  if (!Alpine || !Alpine.store) return false
  if (Alpine.store(host.store)) return false
  Alpine.store(host.store, host.scoped ? createScopedModalStore(env) : createModalStore(env))
  return true
}

export function registerHostsIn(root, env) {
  var hosts = hostsIn(root)
  for (var i = 0; i < hosts.length; i++) registerModalStore(env.win.Alpine, hosts[i], env)
}

// The bfcache and Turbo snapshot cleanup for one store: a modal left open does
// not reappear on the next visit, but a dismissible: false card survives (see
// closeAllDismissible).
export function clearStaleModals(win, name) {
  if (!win.Alpine || !win.Alpine.store) return
  var store = win.Alpine.store(name)
  if (store && typeof store.closeAllDismissible === 'function') store.closeAllDismissible()
  else if (store && typeof store.closeAll === 'function') store.closeAll()
}

// Sweeps the store of every host on the page, each store once.
export function clearStaleModalsIn(doc, win) {
  var hosts = hostsIn(doc)
  var swept = []
  for (var i = 0; i < hosts.length; i++) {
    if (swept.indexOf(hosts[i].store) !== -1) continue
    swept.push(hosts[i].store)
    clearStaleModals(win, hosts[i].store)
  }
}

// Installs the globals, the three registration paths and the stale-modal
// sweep, once per document.
var installedOn = new WeakSet()

export function installModalHost(doc, win) {
  if (installedOn.has(doc)) return
  installedOn.add(doc)
  var env = { doc: doc, win: win }

  installModalGlobals(win)

  doc.addEventListener('alpine:init', function () { registerHostsIn(doc, env) })
  doc.addEventListener('turbo:before-render', function (event) {
    if (event.detail) registerHostsIn(event.detail.newBody, env)
  })
  doc.addEventListener('turbo:before-frame-render', function (event) {
    if (event.detail) registerHostsIn(event.detail.newFrame, env)
  })
  // THE SWEEP IS BOUND HERE, the one place, and not by the controller: this
  // module loads by its own tag, so the sweep survives a boot that fails to
  // load, and one binding per document sweeps each store once per event.
  win.addEventListener('pageshow', function (event) {
    if (event.persisted) clearStaleModalsIn(doc, win)
  })
  doc.addEventListener('turbo:before-cache', function () { clearStaleModalsIn(doc, win) })
  // Alpine already running (a host that loads it ahead of the module tags).
  if (win.Alpine && win.Alpine.version) registerHostsIn(doc, env)
}

if (typeof document !== 'undefined' && typeof window !== 'undefined') {
  installModalHost(document, window)
}
