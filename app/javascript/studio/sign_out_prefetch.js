// studio/sign_out_prefetch: Turbo never prefetches a sign-out (docs/DEVICE_SESSIONS.md,
// "Prefetch").
//
// Turbo 8 prefetches a same-origin link the pointer rests on for 100ms. Every host's
// sign-out is GET /logout, so a pointer that only passed over a Log out link signed the
// browser out: the prefetch ran SessionsController#destroy and its Set-Cookie dropped
// the session, while the page on screen still drew the user. Measured in the hub's
// e2e/build_funnel.spec.js (task build-funnel-held-message-cause).
//
// The engine's own Log out (components/_link_sidebar) carries data-turbo-prefetch="false".
// This listener covers a Log out link a host draws without it. The server answers any
// prefetch that still arrives with a 204 (Studio::ErrorHandling#refuse_prefetched_sign_out),
// so a click is always a real visit and never a cached 204.
//
// It imports nothing; test/javascript/sign_out_prefetch.test.mjs loads it as a data: module.

// The paths whose GET ends the session (the engine's `match "logout"`).
export const SIGN_OUT_PATHS = Object.freeze([ "/logout" ])

// PURE. Whether `link` (anything with getAttribute("href")) signs out on `origin`.
export function isSignOutLink(link, origin) {
  const href = link && typeof link.getAttribute === "function" ? link.getAttribute("href") : null
  if (!href) return false
  let url
  try {
    url = new URL(href, origin)
  } catch (_error) {
    return false
  }
  return url.origin === origin && SIGN_OUT_PATHS.includes(url.pathname.replace(/\/+$/, "") || "/")
}

// The turbo:before-prefetch listener: cancels the prefetch of a sign-out link.
export function refuseSignOutPrefetch(event, origin = globalThis.location?.origin) {
  if (isSignOutLink(event.target, origin)) event.preventDefault()
}

if (typeof document !== "undefined" && !globalThis.__studioSignOutPrefetch) {
  globalThis.__studioSignOutPrefetch = true
  document.addEventListener("turbo:before-prefetch", (event) => refuseSignOutPrefetch(event))
}
