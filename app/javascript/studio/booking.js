// studio/booking: the booking frame and the booking popup (docs/BOOKING.md).
//
//   installBookingFrames  the inline frame: assign src after `load`, once the
//                         frame is near the viewport, and open the crop when
//                         focus moves into the frame.
//   installBookingPopup   any a[data-booking-popup] link opens the booking
//                         dialog instead of leaving the page.
//
// Both install document-level behaviour once per document, however many
// frames, dialogs or Turbo visits follow. Started by the booking controller,
// which studio/booking/_frame and studio/booking/_popup name.
//
// THE GUARDS ARE THE ENGINE'S OWN NAMES, AND THE ELEMENTS ARE THE ENGINE'S OWN
// (data-studio-booking), for the reason studio/footer_map gives for the map: an
// app that still renders a local booking script guards it with the unprefixed
// names and marks its frame, dialog and links with the same data-booking-*
// attributes. Sharing either lets one script stand the other down across a
// Turbo visit, or act on elements that are not its own.
//
// It imports nothing; test/javascript/booking.test.mjs loads it as a data:
// module.

export const FRAME = "iframe[data-booking-frame][data-studio-booking]"
export const WAITING_FRAMES = "iframe[data-booking-frame][data-studio-booking][data-src]"
export const WRAP = "[data-booking-wrap][data-studio-booking]"
export const SHUT_WRAP = "[data-booking-wrap][data-studio-booking][data-booking-crop]:not(.is-open)"
export const POPUP_LINK = "a[data-booking-popup][data-studio-booking]"
export const DIALOG = "dialog[data-booking-dialog][data-studio-booking]"
export const POPUP_FRAME = "iframe[data-booking-popup-frame]"

// ASK GOOGLE ONCE. Two things can ask for a frame: scrolling near it, and a
// booking link that jumps to it. Assigning src a second time, even to the same
// URL, is a second request, so whoever comes second finds it set.
export function loadBookingFrame(frame) {
  if (!frame.getAttribute("src")) frame.src = frame.dataset.src
}

// A plain primary click: not already handled, and not one the visitor modified
// to open a new tab or window.
export function plainClick(event) {
  return !(event.defaultPrevented || event.button !== 0 ||
           event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)
}

// Watches every waiting frame in `doc`, and loads each once it comes within
// 200px of the viewport. A frame is watched once.
export function armBookingFrames(win, doc) {
  doc.querySelectorAll(WAITING_FRAMES).forEach((frame) => {
    if (frame.__bookingArmed) return
    frame.__bookingArmed = true
    if (typeof win.IntersectionObserver !== "function") { loadBookingFrame(frame); return }
    const watcher = new win.IntersectionObserver((entries) => {
      if (!entries.some((entry) => entry.isIntersecting)) return
      watcher.disconnect()
      loadBookingFrame(frame)
    }, { rootMargin: "200px" })
    watcher.observe(frame)
  })
}

// Arms the frames once the window has loaded: a frame that starts loading
// before `load` holds that event open for as long as Google takes to answer.
export function armBookingFramesAfterLoad(win, doc) {
  if (doc.readyState === "complete") armBookingFrames(win, doc)
  else win.addEventListener("load", () => armBookingFrames(win, doc), { once: true })
}

// Focus moving into the frame is the one signal a cross-origin frame gives its
// parent. It means the visitor has started using the calendar.
function openActive(doc) {
  const active = doc.activeElement
  if (!active || !active.matches || !active.matches(FRAME)) return
  const wrap = active.closest(WRAP)
  if (wrap) wrap.classList.add("is-open")
}

// Installs the inline frame's behaviour, once per document. Answers false when
// it was already installed.
export function installBookingFrames(win, doc) {
  if (win.__studioBookingFramesArmed) return false
  win.__studioBookingFramesArmed = true
  win.__studioBookingLoad = loadBookingFrame

  // THE WINDOW BLURS ONCE. Focus that moves from one frame straight into
  // another never comes back through this window, so no second blur announces
  // the second frame, and on a page with two cropped frames it would stay
  // cropped under the visitor's cursor. So while focus is away in a frame and a
  // cropped wrapper is still shut, look again a few times a second. It stops
  // when focus returns here or nothing is left to open, and a page with one
  // frame never starts it: that frame is open by then.
  let watching = null
  const shut = () => doc.querySelector(SHUT_WRAP)
  const stopWatching = () => { if (watching) { win.clearInterval(watching); watching = null } }

  win.addEventListener("blur", () => {
    openActive(doc)
    const active = doc.activeElement
    if (watching || !active || active.tagName !== "IFRAME" || !shut()) return
    watching = win.setInterval(() => {
      openActive(doc)
      if (!shut()) stopWatching()
    }, 250)
  })
  win.addEventListener("focus", stopWatching)

  doc.addEventListener("turbo:load", () => armBookingFramesAfterLoad(win, doc))
  armBookingFramesAfterLoad(win, doc)
  return true
}

// What a click on a booking link does. Delegated from the document, so it
// survives Turbo body swaps. A modified click (new tab, new window) is left
// alone, and so is everything when the dialog is missing or <dialog> is
// unsupported: the link's own href then takes the visitor to the booking page.
//
// ON A PAGE THAT ALREADY SHOWS THE INLINE FRAME the link goes to that frame
// instead: it scrolls there, opens the crop and moves focus in. A popup would
// be a second copy of the calendar on top of the first.
//
// Answers "frame", "dialog", or null when the click is left to the browser.
export function handleBookingLinkClick(event, win, doc) {
  const link = event.target.closest && event.target.closest(POPUP_LINK)
  if (!link) return null
  if (!plainClick(event)) return null

  const inline = doc.querySelector(FRAME)
  if (inline) {
    event.preventDefault()
    const wrap = inline.closest(WRAP)
    if (wrap) wrap.classList.add("is-open")
    // Before `load` the frame keeps waiting: installBookingFrames assigns src then.
    if (doc.readyState === "complete" && win.__studioBookingLoad) win.__studioBookingLoad(inline)
    const calm = win.matchMedia && win.matchMedia("(prefers-reduced-motion: reduce)").matches
    const anchor = wrap || inline
    anchor.scrollIntoView({ behavior: calm ? "auto" : "smooth", block: "start" })
    inline.focus({ preventScroll: true })
    return "frame"
  }

  const dialog = doc.querySelector(DIALOG)
  if (!dialog || typeof dialog.showModal !== "function") return null

  event.preventDefault()
  const frame = dialog.querySelector(POPUP_FRAME)
  if (frame && !frame.getAttribute("src")) frame.src = frame.dataset.src
  if (!dialog.open) dialog.showModal()
  return "dialog"
}

// Never snapshot the dialog open: a restored page would show it stuck. And
// never snapshot its frame loaded: a restored page would ask Google for a popup
// nobody has opened. The src goes back to waiting in data-src.
export function resetBookingDialog(doc) {
  const dialog = doc.querySelector(DIALOG)
  if (!dialog) return
  if (dialog.open) dialog.close()
  const frame = dialog.querySelector(POPUP_FRAME)
  if (frame) frame.removeAttribute("src")
}

// Installs the popup's behaviour, once per document. Answers false when it was
// already installed.
export function installBookingPopup(win, doc) {
  if (win.__studioBookingPopupArmed) return false
  win.__studioBookingPopupArmed = true

  doc.addEventListener("click", (event) => { handleBookingLinkClick(event, win, doc) })

  // A click on the backdrop lands on the dialog element itself.
  doc.addEventListener("click", (event) => {
    if (event.target.matches && event.target.matches(DIALOG)) event.target.close()
  })

  doc.addEventListener("turbo:before-cache", () => resetBookingDialog(doc))
  return true
}
