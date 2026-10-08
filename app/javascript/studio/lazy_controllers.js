// studio/lazy_controllers: registers a page-specific controller the first time
// an element names it, so its module is fetched only by a page that uses it.
//
//   watchLazyControllers({
//     root: document.documentElement,
//     attribute: "data-studio-controller",
//     loaders: { "hold-button": () => import("studio/controllers/hold_button_controller") },
//     register: (name, controller) => application.register(name, controller)
//   })
//
// An every-page controller is imported statically by studio/application, which
// puts it in the preloaded boot graph. A lazy one is named here by a dynamic
// import, which the boot graph does not follow.
//
// UNTIL A LAZY CONTROLLER REGISTERS its element's actions do nothing: Stimulus
// ignores an action whose controller it does not know. A loader that fails is
// reported and tried again the next time the page changes.
//
// It imports nothing; test/javascript/lazy_controllers.test.mjs loads it as a
// data: module.

// The identifiers in one data-studio-controller value.
export function controllerNames(value) {
  return String(value || "").split(/\s+/).filter(Boolean)
}

// The identifiers from `names` that an element in `root`, or `root` itself,
// carries in `attribute`.
export function lazyNamesIn(root, names, attribute) {
  const wanted = new Set(names)
  const found = new Set()
  if (!root || wanted.size === 0) return []

  const elements = []
  if (typeof root.getAttribute === "function" && root.getAttribute(attribute) != null) elements.push(root)
  if (typeof root.querySelectorAll === "function") elements.push(...root.querySelectorAll(`[${attribute}]`))

  for (const element of elements) {
    for (const name of controllerNames(element.getAttribute(attribute))) {
      if (wanted.has(name)) found.add(name)
    }
  }
  return [...found]
}

// Loads and registers each lazy controller once, on first sight: now, for the
// elements already in `root`, and after any change beneath it. Returns
// { pending, scan, stop }; the observer stops by itself once every loader ran.
export function watchLazyControllers({ root, attribute, loaders, register, Observer, report }) {
  const pending = new Set(Object.keys(loaders || {}))
  const loading = new Set()
  const complain = report || ((name, error) => console.error(`[studio] the ${name} controller failed to load`, error))
  let observer = null

  const stop = () => {
    if (observer) observer.disconnect()
    observer = null
  }

  const load = (name) => {
    pending.delete(name)
    loading.add(name)
    return Promise.resolve()
      .then(() => loaders[name]())
      .then((module) => {
        loading.delete(name)
        register(name, module && module.default ? module.default : module)
        if (pending.size === 0 && loading.size === 0) stop()
      })
      .catch((error) => {
        loading.delete(name)
        pending.add(name)
        complain(name, error)
      })
  }

  const scan = () => Promise.all(lazyNamesIn(root, [...pending], attribute).map(load))

  const ObserverClass = Observer || (typeof MutationObserver !== "undefined" ? MutationObserver : null)
  if (ObserverClass && pending.size > 0) {
    observer = new ObserverClass(() => { if (pending.size > 0) scan() })
    observer.observe(root, { childList: true, subtree: true, attributes: true, attributeFilter: [attribute] })
  }

  return { pending, scan, stop, started: scan() }
}
