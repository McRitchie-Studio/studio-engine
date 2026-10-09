// studio/footer_map: mounts a Leaflet map on every [data-footer-map]
// (docs/SITE_FOOTER.md). Leaflet (script and stylesheet) is fetched once, on
// demand, from the URLs the element carries, so a page with no map pays nothing
// for it. The basemap follows the site theme in CSS (studio/site_footer/
// _map_assets). Tiles are OpenStreetMap's keyless ones; a basemap that needs an
// API key does not belong in a gem.
//
// NOTHING STARTS BEFORE THE WINDOW'S `load`, AND NOTHING UNTIL THE MAP IS NEAR
// THE VIEWPORT. The tiles are a third party's, and a request that starts before
// `load` holds that event open for as long as the third party takes to answer.
// The map is also at the bottom of every public page, where most visits never
// reach: those pay for neither Leaflet nor a single tile.
//
// THE GUARD IS THE ENGINE'S OWN NAME, AND THE ELEMENTS ARE THE ENGINE'S OWN. An
// app that still renders a local footer script guards it with the unprefixed
// name and marks its map [data-footer-map] too. Sharing either would let
// whichever script ran first in a Turbo session stand the other down and then
// fail on its elements: that app's map carries no data-leaflet-js, so there is
// nothing here to fetch.
//
// It imports nothing; test/javascript/footer_map.test.mjs loads it as a data:
// module. Started by the footer-map controller.

export const MAPS = "[data-footer-map][data-leaflet-js]"
export const TILES = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
export const ATTRIBUTION = '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'

// What a map element asks for: where it is centred, how far in, and whether it
// shows zoom buttons. Answers null when the element carries no usable point.
export function mapOptions(dataset) {
  const at = [parseFloat(dataset.lat), parseFloat(dataset.lng)]
  if (isNaN(at[0]) || isNaN(at[1])) return null
  return { at, zoom: parseInt(dataset.zoom, 10) || 15, zoomControl: dataset.controls !== "false" }
}

// Installs the footer maps, once per document. Answers the function that arms
// the maps now on the page (after `load`), whether this call installed it or an
// earlier one did.
export function installFooterMaps(win, doc) {
  if (win.__studioFooterMapsArmed) return win.__studioFooterMapsArm || (() => {})
  win.__studioFooterMapsArmed = true

  let maps = []
  let loading = null

  // Checked on every mount, not once: a page visit that rebuilds the head must
  // not leave a mounted map without its stylesheet.
  function ensureStylesheet(href) {
    if (!href || doc.querySelector("link[data-studio-leaflet]")) return
    const link = doc.createElement("link")
    link.rel = "stylesheet"
    link.href = href
    link.setAttribute("data-studio-leaflet", "")
    doc.head.appendChild(link)
  }

  function loadLeaflet(src) {
    if (win.L) return Promise.resolve()
    if (loading) return loading
    loading = new Promise((resolve, reject) => {
      const s = doc.createElement("script")
      s.src = src
      s.onload = resolve
      // A failed fetch must not be remembered: the next visit tries again.
      s.onerror = () => { loading = null; s.remove(); reject(new Error("leaflet failed to load")) }
      doc.head.appendChild(s)
    })
    return loading
  }

  function mount(el) {
    if (el.__footerMap) return
    const options = mapOptions(el.dataset)
    if (!options) return
    const L = win.L
    // NO ONE-FINGER DRAG ON A TOUCH DEVICE. The map runs edge to edge, so on a
    // phone a swipe that starts on it would pan the map instead of scrolling
    // the page, and there is no gutter to scroll by. With dragging off Leaflet
    // leaves touch-action at pan-x pan-y: one finger scrolls the page, and a
    // pinch still zooms the map (touchZoom stays on, and moves it under the
    // fingers). The zoom buttons and the directions link do the rest.
    const map = L.map(el, { center: options.at, zoom: options.zoom,
                            scrollWheelZoom: false, attributionControl: true,
                            dragging: !L.Browser.mobile, touchZoom: true,
                            zoomControl: options.zoomControl })
    map.attributionControl.setPrefix(false)
    L.tileLayer(TILES, { attribution: ATTRIBUTION, maxZoom: 19 }).addTo(map)
    L.marker(options.at, { icon: L.divIcon({ className: "", html: '<div class="ftr-pin"></div>', iconSize: [18, 18], iconAnchor: [9, 9] }),
                           keyboard: false }).addTo(map)
    // Page scroll stays page scroll until the visitor commits to the map.
    map.on("click", () => { map.scrollWheelZoom.enable() })
    map.on("mouseout", () => { map.scrollWheelZoom.disable() })
    const fallback = el.querySelector(".ftr-map-fallback")
    if (fallback) { el.__footerFallback = fallback; fallback.remove() }
    el.__footerMap = map
    maps.push(el)
  }

  function fetchAndMount(el) {
    ensureStylesheet(el.dataset.leafletCss)
    loadLeaflet(el.dataset.leafletJs)
      .then(() => { if (el.isConnected) mount(el) })
      .catch(() => { /* the fallback link stays */ })
  }

  // One observer per map: it fires once, when the map comes within 400px of
  // the viewport, and is then dropped.
  function watch(el) {
    if (el.__footerMap || el.__footerWatch) return
    if (typeof win.IntersectionObserver !== "function") { fetchAndMount(el); return }
    const watcher = new win.IntersectionObserver((entries) => {
      if (!entries.some((entry) => entry.isIntersecting)) return
      watcher.disconnect()
      el.__footerWatch = null
      fetchAndMount(el)
    }, { rootMargin: "400px" })
    el.__footerWatch = watcher
    watcher.observe(el)
  }

  function armAll() { doc.querySelectorAll(MAPS).forEach(watch) }

  function armAfterLoad() {
    if (doc.readyState === "complete") armAll()
    else win.addEventListener("load", armAll, { once: true })
  }

  // A cached Turbo snapshot would restore Leaflet's DOM without its state, so
  // the map is taken down and its fallback link put back before the snapshot.
  doc.addEventListener("turbo:before-cache", () => {
    maps.forEach((el) => {
      const fallback = el.__footerFallback
      el.__footerMap.remove()
      el.__footerMap = null
      if (fallback && !el.querySelector(".ftr-map-fallback")) el.appendChild(fallback)
    })
    maps = []
  })
  doc.addEventListener("turbo:load", armAfterLoad)
  win.__studioFooterMapsArm = armAfterLoad
  armAfterLoad()
  return armAfterLoad
}
