// studio/alpine_stores: the Alpine stores every host body binds to,
// $store.theme and $store.devMode, and the theme value and toggle behind them.
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

// Flips the root's `dark` class under a short transition class, stores the
// result, and answers it.
export function toggleTheme(root, storage, later) {
  root.classList.add('theme-transition')
  root.classList.toggle('dark')
  var value = root.classList.contains('dark') ? 'dark' : 'light'
  storage.setItem('theme', value)
  later(function () { root.classList.remove('theme-transition') }, 300)
  return value
}

// Registers each store Alpine does not already have. env carries what the
// stores read and write: { storage, root, later }.
export function registerStudioStores(Alpine, env) {
  if (Alpine.store('devMode') === undefined) {
    Alpine.store('devMode', env.storage.getItem('devMode') === 'true')
  }
  if (Alpine.store('theme') === undefined) {
    Alpine.store('theme', {
      value: storedTheme(env.storage),
      get isDark() { return this.value === 'dark' },
      toggle: function () {
        this.value = toggleTheme(env.root, env.storage, env.later)
      }
    })
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
      later: function (fn, ms) { win.setTimeout(fn, ms) }
    })
  })
}

if (typeof document !== 'undefined' && typeof window !== 'undefined') {
  installStudioStores(document, window)
}
