// studio/style_modals: what drives the living style guide's Modals section
// (style/_modals): the stack-behaviour demos, the enter/leave simulator whose
// controls are built from the live animation registry, and the stubs the
// wallet specimens need to run with no wallet.
//
// The section's own modal host is the engine's stack under the name dsModals
// (studio/modal_host registers it from the overlay's data attributes), so what
// the guide shows is the store an app runs. The style-modals controller binds
// this module to the section.
//
// It imports nothing; test/javascript/style_modals.test.mjs loads it as a
// data: module.

// The card the stack demos drive: style/modals/_ds_stack_demo, which belongs
// to the guide and to nothing that ships.
export const VEHICLE = "ds-stack-demo"

// The card the enter/leave simulator opens, so only the motion varies.
export const ANIM_DEMO_ID = "email-change-pending"
export const ANIM_DEMO_PROPS = { currentEmail: "you@example.com", newEmail: "new@example.com" }

// The four containers the simulator fills.
export const ANIM_CONTROL_IDS = {
  enterButtons: "modal-anim-enter-buttons",
  exitButtons: "modal-anim-exit-buttons",
  enterSelect: "modal-anim-enter-select",
  exitSelect: "modal-anim-exit-select"
}

// A pending operation, as the vehicle opens: not dismissible, like a real one.
export const PENDING = {
  state: "processing",
  title: "Submitting entry",
  message: "Awaiting confirmation",
  dismissible: false
}

export const SUCCESS = {
  state: "success",
  title: "Entry confirmed",
  message: "Resolved in place — this is the same stack entry you opened.",
  dismissible: true
}

export const FAILURE = {
  state: "error",
  title: "Submission failed",
  message: "The error face of that same entry, patched in by advance().",
  dismissible: true
}

// How long the wallet stub takes to answer, so the picker's connecting state
// is visible.
export const WALLET_CONNECT_MS = 1100

// "Pop (default)", "Shake": a registry key as a control's label.
export function animationLabel(key) {
  return key.charAt(0).toUpperCase() + key.slice(1) + (key === "pop" ? " (default)" : "")
}

// The registry the page holds, read when asked and never copied: a key an app
// registers later grows a control on the next build.
export function animationRegistry(win) {
  const registry = win.ModalAnimations || {}
  return { enter: registry.enter || {}, exit: registry.exit || {} }
}

// How long a round trip holds the card before closing it: its entrance's own
// registry duration plus a beat.
export function roundTripHoldMs(win, enterAnim) {
  const entrance = animationRegistry(win).enter[enterAnim] || {}
  return (entrance.ms || 320) + 700
}

// The stubs solana-studio's wallet picker needs on a page with no wallet:
// a connect that performs none and answers success after a beat, and a
// provider that lists two wallets and has neither. A page that ships a real
// one keeps it.
export function installWalletStubs(win) {
  win.dsWalletConnectDemo = win.dsWalletConnectDemo || function () {
    return new Promise(function (resolve) {
      win.setTimeout(function () { resolve({ success: true }) }, WALLET_CONNECT_MS)
    })
  }
  win.walletProvider = win.walletProvider || {
    available: function () { return [{ name: "Phantom" }, { name: "Solflare" }] },
    isMobile: function () { return false },
    isAvailable: function () { return false }
  }
}

// The demo drivers. env: { win, doc, store } — the window, the document the
// simulator's controls live in, and the name of the section's modal store.
export function createModalDemos(env) {
  const win = env.win
  const doc = env.doc
  const storeName = env.store || "dsModals"
  const store = () => win.Alpine.store(storeName)
  const element = (id) => doc.getElementById(id)

  function openDemo(props) {
    store().open(VEHICLE, Object.assign({}, PENDING, props || {}))
  }

  // A state change on the card already open. advance() patches props without
  // replacing the stack entry, so the vehicle's scope survives. Only a
  // still-open vehicle is patched: a timer that fires after the card closed
  // does nothing to whatever is on top now.
  function advanceDemo(patch) {
    const current = store().current()
    if (!current || current.id !== VEHICLE || current._closing) return
    store().advance(patch)
  }

  function animOpen(enterAnim, exitAnim) {
    store().open(ANIM_DEMO_ID, Object.assign({}, ANIM_DEMO_PROPS, { enterAnim, exitAnim }))
  }

  // Open, let the entrance settle, then close, so the chosen exit is what
  // plays.
  function animRoundTrip(enterAnim, exitAnim) {
    animOpen(enterAnim, exitAnim)
    win.setTimeout(function () { store().close() }, roundTripHoldMs(win, enterAnim))
  }

  // Builds the quick buttons and the select options from the live registry.
  // Each container is emptied first, so building again doubles nothing.
  function buildAnimControls() {
    const registry = animationRegistry(win)
    const enterButtons = element(ANIM_CONTROL_IDS.enterButtons)
    const exitButtons = element(ANIM_CONTROL_IDS.exitButtons)
    const enterSelect = element(ANIM_CONTROL_IDS.enterSelect)
    const exitSelect = element(ANIM_CONTROL_IDS.exitSelect)

    const addOption = function (select, key) {
      if (!select) return
      const option = doc.createElement("option")
      option.value = key
      option.textContent = animationLabel(key)
      if (key === "pop") option.selected = true
      select.appendChild(option)
    }
    const addButton = function (container, key, onClick, suffix) {
      if (!container) return
      const button = doc.createElement("button")
      button.type = "button"
      button.className = "btn btn-outline btn-sm"
      button.textContent = animationLabel(key) + (suffix || "")
      button.onclick = onClick
      container.appendChild(button)
    }

    ;[enterButtons, exitButtons, enterSelect, exitSelect].forEach(function (node) {
      if (node) node.innerHTML = ""
    })

    Object.keys(registry.enter).forEach(function (key) {
      addButton(enterButtons, key, function () { animOpen(key, "pop") }, " ↗")
      addOption(enterSelect, key)
    })
    Object.keys(registry.exit).forEach(function (key) {
      addButton(exitButtons, key, function () { animRoundTrip("pop", key) })
      addOption(exitSelect, key)
    })
  }

  return {
    buildAnimControls,

    // Stack behaviour
    processing: function () { openDemo({}) },
    success: function () { openDemo(SUCCESS) },
    error: function () { openDemo(FAILURE) },
    processThenSuccess: function () {
      openDemo({ message: "Awaiting RPC confirmation" })
      win.setTimeout(function () { advanceDemo(SUCCESS) }, 3000)
    },
    processThenError: function () {
      openDemo({ message: "Awaiting RPC confirmation" })
      win.setTimeout(function () { advanceDemo(FAILURE) }, 3000)
    },
    dismissible: function () {
      openDemo({
        dismissible: true,
        title: "Dismissible processing",
        message: "Escape and click-outside both close this one."
      })
    },
    fastWithHold: function () {
      openDemo({ title: "Fast operation", message: "Holding the spinner for at least 1500ms" })
      win.StudioModals.holdAtLeast(1500).then(function () { advanceDemo(SUCCESS) })
    },
    fastNoHold: function () {
      openDemo({ title: "Fast operation", message: "No hold, so this flashes past" })
      win.setTimeout(function () { advanceDemo(SUCCESS) }, 50)
    },
    stackTwo: function () {
      openDemo({
        dismissible: true,
        title: "Bottom of the stack",
        message: "A second card is about to push in front of this one."
      })
      win.setTimeout(function () { store().open(ANIM_DEMO_ID, ANIM_DEMO_PROPS) }, 700)
    },

    // Enter / leave simulator
    animOpenSelected: function () {
      animOpen(element(ANIM_CONTROL_IDS.enterSelect).value, element(ANIM_CONTROL_IDS.exitSelect).value)
    },
    animRoundTripSelected: function () {
      animRoundTrip(element(ANIM_CONTROL_IDS.enterSelect).value, element(ANIM_CONTROL_IDS.exitSelect).value)
    }
  }
}
