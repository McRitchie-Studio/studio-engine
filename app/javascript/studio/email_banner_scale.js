// studio/email_banner_scale: scales the 600px email banner down to whatever
// width its frame has.
//
// WHY THIS NEEDS SCRIPT AT ALL. The banner is the EMAIL's own markup, a fixed
// 600px table, and it must stay that way: an inbox has no responsive layout, so
// making it fluid would mean previewing markup no one receives. The frame
// beside it is fluid. Nothing in CSS converts a fixed-width box into a fluid
// one without knowing the container's width, so the width is read and a
// transform applied.
//
// WHAT IT DOES NOT DO: move anything. It sets a scale on a box whose height is
// already reserved by `aspect-ratio`, so no reflow follows and there is no
// paint-time jump.
//
// Without it the preview is unscaled and clipped, so a failure here costs the
// improvement and not the page.
//
// It imports nothing; test/javascript/email_banner_scale.test.mjs loads it as a
// data: module. Started by the email-banner-scale controller.

export const PREVIEWS = "[data-email-banner-preview]"
export const FRAMES = "[data-email-banner-frame]"
export const NATURAL_WIDTH = 600

// The scale that fits a `natural`-wide banner into `available` pixels. Never
// above 1: at 1:1 the preview is exactly the 600px the recipient sees, and past
// that it would show the operator a banner larger than any inbox renders.
// Answers null when the frame has no width to fit.
export function bannerScale(natural, available) {
  if (!available) return null
  return Math.min(available / (natural || NATURAL_WIDTH), 1)
}

// Scales one preview to its frame (its parent). Answers the scale it set, or
// null when it set none.
export function fitBanner(preview) {
  const frame = preview.parentElement
  if (!frame) return null
  const scale = bannerScale(parseFloat(preview.dataset.bannerWidth), frame.clientWidth)
  if (scale === null) return null
  preview.style.transform = "scale(" + scale + ")"
  return scale
}

export function fitAllBanners(doc) {
  doc.querySelectorAll(PREVIEWS).forEach(fitBanner)
}

// Fits every preview in `doc` now and whenever a frame changes width. A
// ResizeObserver and not a resize listener: a frame changes width when a
// sidebar opens or the grid reflows, and neither resizes the window. Answers
// the function that stops watching.
export function startBannerScale(doc, Observer) {
  fitAllBanners(doc)
  if (typeof Observer !== "function") return () => {}

  const observer = new Observer(() => fitAllBanners(doc))
  doc.querySelectorAll(FRAMES).forEach((frame) => observer.observe(frame))
  return () => observer.disconnect()
}
