// studio/page_transition_reveal: the arriving half of a full-load page transition
// (docs/PAGE_TRANSITIONS.md, "Full page loads"). Loaded only with
// Studio.page_transition_direction set.
//
// CLASSIC AND SYNCHRONOUS ON PURPOSE. pagereveal fires before the first render, and a listener
// bound after that misses it for good. A module is deferred, so it can be too late.
//
// It holds no table of styles. The leaving page read the style with studio/page_transitions
// at pageswap and left it here. No style means the leaving page did not plan this one (its
// module had not run, or it was the same path), so the load is plain, not the browser's fade.
(function () {
  var STYLE_KEY = "studio-page-transition-style"
  var HOLD_CAP_MS = 3000

  // Holds the first render to the end of parsing, on an arrival only (nothing has this id). A
  // render of half a body would give the new picture no navbar or stack to hold still. The
  // browser sets no limit on this hold, so the timer does: a slow body paints at the cap. The
  // cap sits inside the browser's own limit on the transition, so the motion still plays.
  function holdForTheWholePage() {
    try {
      if (!window.sessionStorage.getItem(STYLE_KEY)) return
    } catch (_error) {
      return
    }
    var link = document.createElement("link")
    link.rel = "expect"
    link.href = "#studio-page-transition-end-of-parse"
    link.setAttribute("blocking", "render")
    document.head.appendChild(link)
    window.setTimeout(function () { link.remove() }, HOLD_CAP_MS)
  }

  function takeStyle() {
    try {
      var style = window.sessionStorage.getItem(STYLE_KEY)
      window.sessionStorage.removeItem(STYLE_KEY)
      return style
    } catch (_error) {
      return null
    }
  }

  holdForTheWholePage()

  window.addEventListener("pagereveal", function (event) {
    var root = document.documentElement
    // A page back from the back/forward cache still wears what it had on when it left.
    delete root.dataset.pageTransition
    delete root.dataset.pageTransitionVisit

    var style = takeStyle()
    var transition = event.viewTransition
    if (!transition) return
    var direction = document.querySelector('meta[name="page-transition-direction"]')
    if (!style || !direction) {
      // The skip is chosen here, so its `ready` rejection is expected: handled, as in
      // studio/page_transitions' skipOwnTransition. Chrome leaves it unhandled otherwise.
      if (transition.ready && typeof transition.ready.catch === "function") transition.ready.catch(function () {})
      transition.skipTransition()
      return
    }

    // engine.css reads these three. The new page's picture comes after this listener, so the
    // held stack and every morph name are settled in time.
    root.dataset.pageTransitionDirection = direction.content
    root.dataset.pageTransition = style
    root.dataset.pageTransitionVisit = ""
    var stack = document.querySelector("[data-vt-held], .studio-bar-stack")
    if (stack) stack.setAttribute("data-vt-held", "")

    var done = function () {
      if (root.dataset.pageTransition !== style) return
      delete root.dataset.pageTransition
      delete root.dataset.pageTransitionVisit
    }
    transition.finished.then(done, done)
  })
})()
