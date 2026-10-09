// studio/lazy_controllers: registers a page-specific controller the first time
// an element names it, so its module is fetched only by a page that uses it.
//
//   watchLazyControllers({
//     root: document.documentElement,
//     attribute: "data-studio-controller",
//     loaders: { board: () => import("studio/controllers/board_controller") },
//     register: (name, controller) => application.register(name, controller)
//   })
//
// An every-page controller is imported statically, which puts it in the
// preloaded boot graph. A lazy one is named here by a dynamic import, which the
// boot graph does not follow.
//
// UNTIL A LAZY CONTROLLER REGISTERS its element's actions do nothing: Stimulus
// ignores an action whose controller it does not know.
//
// A LOAD THAT FAILS IS FINAL FOR THE DOCUMENT. A browser keeps a failed module
// fetch in the document's module map and rejects every later import() of it
// without a new request, across DOM changes and Turbo visits; only a full page
// load fetches it again. So the registry imports a controller once. When the
// import fails it reports the failure once and marks every element that names
// the controller, those on the page and those that arrive later:
//
//   <div data-studio-controller="board" data-studio-controller-failed="board">
//
// A control that must work whenever its page does is therefore not lazy: the
// hold button is imported statically by studio/stimulus.
//
// It imports nothing; test/javascript/lazy_controllers.test.mjs loads it as a
// data: module.

// The attribute a failed controller's elements carry: the identifiers, among
// those the element names, whose module failed to load.
export const FAILED_ATTRIBUTE = "data-studio-controller-failed"

// The identifiers in one data-studio-controller value.
export function controllerNames(value) {
  return String(value || "").split(/\s+/).filter(Boolean)
}

// `root` itself, when it carries `attribute`, and every element beneath it
// that does.
function elementsWith(root, attribute) {
  const elements = []
  if (!root) return elements
  if (typeof root.getAttribute === "function" && root.getAttribute(attribute) != null) elements.push(root)
  if (typeof root.querySelectorAll === "function") elements.push(...root.querySelectorAll(`[${attribute}]`))
  return elements
}

// The identifiers from `names` that an element in `root`, or `root` itself,
// carries in `attribute`.
export function lazyNamesIn(root, names, attribute) {
  const wanted = new Set(names)
  const found = new Set()
  if (wanted.size === 0) return []

  for (const element of elementsWith(root, attribute)) {
    for (const name of controllerNames(element.getAttribute(attribute))) {
      if (wanted.has(name)) found.add(name)
    }
  }
  return [...found]
}

// Writes `failedAttribute` on every element in `root` that names a controller
// in `failed`. Returns the elements it marked on this pass.
export function markFailed(root, failed, attribute, failedAttribute = FAILED_ATTRIBUTE) {
  const lost = new Set(failed)
  const marked = []
  if (lost.size === 0) return marked

  for (const element of elementsWith(root, attribute)) {
    const names = controllerNames(element.getAttribute(attribute)).filter((name) => lost.has(name))
    if (names.length === 0 || typeof element.setAttribute !== "function") continue

    const value = [...new Set(names)].join(" ")
    if (element.getAttribute(failedAttribute) === value) continue
    element.setAttribute(failedAttribute, value)
    marked.push(element)
  }
  return marked
}

// Loads and registers each lazy controller once, on first sight: now, for the
// elements already in `root`, and after any change beneath it. A controller
// whose load fails is never loaded again; its elements are marked instead.
// Returns { pending, failed, scan, stop, started }. The observer stops by
// itself once every controller has registered; while one has failed it keeps
// watching, to mark the elements that arrive later.
export function watchLazyControllers({ root, attribute, loaders, register, Observer, report, failedAttribute }) {
  const pending = new Set(Object.keys(loaders || {}))
  const loading = new Set()
  const failed = new Map()
  const complain = report || ((name, error) => console.error(
    `[studio] the ${name} controller failed to load and stays unavailable until the page is reloaded`, error
  ))
  let observer = null

  const stop = () => {
    if (observer) observer.disconnect()
    observer = null
  }

  const mark = () => markFailed(root, failed.keys(), attribute, failedAttribute || FAILED_ATTRIBUTE)

  const load = (name) => {
    pending.delete(name)
    loading.add(name)
    return Promise.resolve()
      .then(() => loaders[name]())
      .then((module) => {
        register(name, module && module.default ? module.default : module)
        loading.delete(name)
        if (pending.size === 0 && loading.size === 0 && failed.size === 0) stop()
      })
      .catch((error) => {
        loading.delete(name)
        failed.set(name, error)
        mark()
        complain(name, error)
      })
  }

  const scan = () => {
    mark()
    return Promise.all(lazyNamesIn(root, [...pending], attribute).map(load))
  }

  const ObserverClass = Observer || (typeof MutationObserver !== "undefined" ? MutationObserver : null)
  if (ObserverClass && pending.size > 0) {
    observer = new ObserverClass(() => { if (pending.size > 0 || failed.size > 0) scan() })
    observer.observe(root, { childList: true, subtree: true, attributes: true, attributeFilter: [attribute] })
  }

  return { pending, failed, scan, stop, started: scan() }
}
