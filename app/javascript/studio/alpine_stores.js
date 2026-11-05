// studio/alpine_stores: the Alpine stores every host body binds to,
// $store.theme and $store.devMode, and the theme setter behind them.
//
// WHY THIS IS ITS OWN ENTRY POINT. Every host's <body> says
// :class="{ 'dev-mode': $store.devMode }", and the engine's theme toggle reads
// $store.theme. When those stores lived only inside studio/application's graph,
// any failure to load that graph (a missing digest after a deploy, a network
// drop, a throw in Stimulus or a controller) left Alpine evaluating the body
// binding against an undefined store, and it threw on every page.
//
// So the stores load by two paths, and either one alone is enough:
//
//   1. layouts/studio/_head imports this module with its own
//      javascript_import_module_tag, which carries the request's CSP nonce.
//      A failed studio/application does not stop it.
//   2. studio/alpine_shims imports it, so the boot graph carries it too and the
//      module is preloaded with the rest of the boot.
//
// Both resolve to one module instance, and the install below is idempotent
// regardless: one alpine:init listener per document, and a store is registered
// only when Alpine does not have one of that name (so a host's own wins).
//
// THIS MODULE IMPORTS NOTHING, and test/javascript/alpine_stores.test.mjs holds
// it to that: an import would put another module's failure back in its path.
//
// The pre-paint half of the theme (adding `dark` before first paint) stays an
// inline, nonced script in the head: it must run before the stylesheet paints,
// which no deferred module can.

// The stored theme, dark unless the reader chose light.
export function storedTheme(storage) {
  return storage.getItem('theme') || 'dark'
}

// The theme the root's class shows.
function classTheme(root) {
  return root.classList.contains('dark') ? 'dark' : 'light'
}

// A visit owns the view transition. A second one would skip Turbo's and cut its motion short, so
// a toggle during a visit flips at once. data-turbo-visit-direction spans a visit; data-page-transition
// also spans a full load's arrival (studio/page_transitions).
function visiting(root) {
  return root.dataset.turboVisitDirection !== undefined || root.dataset.pageTransition !== undefined
}

function canCrossfade(env) {
  if (!env.doc || typeof env.doc.startViewTransition !== 'function') return false
  if (env.win.matchMedia('(prefers-reduced-motion: reduce)').matches) return false
  return !visiting(env.root)
}

// The theme store. set(value) is the one setter: the root class, the store value and localStorage
// change together, in one step, so they agree at every moment. Under a crossfade that step runs
// in the transition's callback, after the old picture: for up to a frame after set() all three
// still read the old theme.
//
// data-theme-flip is on the root from before the old picture until the crossfade ends. engine.css
// reads it: the page is one picture, no element runs its own transition, and the page-transition
// motions lose. Without a crossfade it stays until the styles of the new theme have been computed.
export function themeStore(env) {
  var root = env.root
  var flips = 0
  var wanted = null // the theme asked for, while its step has not run

  return {
    value: storedTheme(env.storage),
    get isDark() { return this.value === 'dark' },
    set: function (value) {
      if (value !== 'dark' && value !== 'light') return
      if (value === wanted) return
      var self = this
      var commit = function () {
        root.classList.toggle('dark', value === 'dark')
        self.value = value
        env.storage.setItem('theme', value)
      }
      // Nothing to show, but the three may have drifted: a host can write the class directly.
      if (wanted === null && value === classTheme(root)) return commit()

      var mine = ++flips
      // Only the newest flip acts, so a late callback cannot undo a later choice.
      var apply = function () {
        if (mine !== flips) return
        wanted = null
        commit()
      }
      var settle = function () {
        if (mine === flips) delete root.dataset.themeFlip
      }
      wanted = value
      root.dataset.themeFlip = ''
      if (!canCrossfade(env)) {
        apply()
        if (env.win) env.win.getComputedStyle(root).color // no transition starts from these styles
        return env.later(settle, 0)
      }
      var transition = env.doc.startViewTransition(apply)
      // A skipped transition rejects ready; a throw in apply rejects the other two.
      transition.finished.then(settle, settle)
      transition.ready.catch(function () {})
      transition.updateCallbackDone.catch(function () {})
    },
    toggle: function () {
      this.set((wanted || classTheme(root)) === 'dark' ? 'light' : 'dark')
    }
  }
}

// Registers each store Alpine does not already have. env carries what the
// stores read and write: { storage, root, later, doc, win }.
export function registerStudioStores(Alpine, env) {
  if (Alpine.store('devMode') === undefined) {
    Alpine.store('devMode', env.storage.getItem('devMode') === 'true')
  }
  if (Alpine.store('theme') === undefined) {
    Alpine.store('theme', themeStore(env))
  }
}

// Adds the alpine:init listener that registers the stores, once per document.
// It must run before Alpine starts: the head loads Alpine after the module
// tags, and deferred and module scripts run in document order.
var installedOn = new WeakSet()

export function installStudioStores(doc, win) {
  if (installedOn.has(doc)) return
  installedOn.add(doc)
  doc.addEventListener('alpine:init', function () {
    registerStudioStores(win.Alpine, {
      storage: win.localStorage,
      root: doc.documentElement,
      later: function (fn, ms) { win.setTimeout(fn, ms) },
      doc: doc,
      win: win
    })
  })
}

if (typeof document !== 'undefined' && typeof window !== 'undefined') {
  installStudioStores(document, window)
}
