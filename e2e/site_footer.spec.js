const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests } = require("./helpers");

// The site footer's map (studio/site_footer/_assets, docs/SITE_FOOTER.md).
//
// WHY A BROWSER TIER EARNS ITS PLACE HERE. test/integration/site_footer_test.rb
// proves the footer's markup: the address, the links, the element the map mounts
// on, and that the element names Leaflet's two files. It cannot prove the map:
// that is an inline script that fetches Leaflet from the engine's own assets,
// mounts it on [data-footer-map], and replaces the fallback link. Only a browser
// shows that it ran, that it runs again after a Turbo visit (which replaces the
// body but not the script's state), that a restored Turbo snapshot gets a live
// map rather than Leaflet's dead DOM, and that dark mode restyles the tiles.
//
// THE NETWORK IS CLOSED. Tile images come from tile.openstreetmap.org and are
// deliberately NOT asserted: the mount does not need them, and a runner that
// cannot reach OpenStreetMap must not fail this file. blockOffsiteRequests
// answers them empty.
//
// These pages load Turbo (layouts/site_footer_lab); no other lab page does.

const map = (page) => page.locator("footer[data-site-footer] [data-footer-map]");

// Every request for one of Leaflet's two files, by path.
function watchLeaflet(page) {
  const asked = [];
  page.on("request", (request) => {
    const url = new URL(request.url());
    if (/leaflet/.test(url.pathname)) asked.push(`${url.hostname}${url.pathname}`);
  });
  return asked;
}

async function expectMounted(page) {
  // Leaflet's container class lands on the element, with the pin on it, and the
  // no-script fallback link is gone.
  await expect(map(page)).toHaveClass(/leaflet-container/);
  await expect(map(page).locator(".ftr-pin")).toHaveCount(1);
  await expect(map(page).locator(".ftr-map-fallback")).toHaveCount(0);
  // Leaflet's stylesheet is applied, not just its script: without it the panes
  // are static blocks and the map is a column of tiles.
  await expect
    .poll(() => map(page).locator(".leaflet-map-pane").evaluate((el) => getComputedStyle(el).position))
    .toBe("absolute");
}

test("the footer map mounts from the engine's own Leaflet, centred on the address", async ({ page }) => {
  const asked = watchLeaflet(page);
  await blockOffsiteRequests(page);
  await page.goto("/lab/site_footer");

  await expectMounted(page);

  // Leaflet came from this origin, once each: the script and the stylesheet.
  expect(asked.sort()).toEqual(["127.0.0.1/e2e/css/studio/leaflet.css", "127.0.0.1/e2e/js/studio/leaflet.js"]);
  expect(await page.evaluate(() => window.L.version)).toBe("1.9.4");

  // The map runs edge to edge: as wide as the viewport, not the centred column.
  const widths = await map(page).evaluate((el) => [el.getBoundingClientRect().width, document.documentElement.clientWidth]);
  expect(widths[0]).toBe(widths[1]);
  expect(await map(page).evaluate((el) => el.getBoundingClientRect().height)).toBeGreaterThanOrEqual(256);

  // The map is centred on the address the footer prints.
  const centre = await map(page).evaluate((el) => {
    const c = el.__footerMap.getCenter();
    return [c.lat.toFixed(3), c.lng.toFixed(3)];
  });
  expect(centre).toEqual(["39.761", "-104.979"]);

  // Page scroll stays page scroll until the visitor clicks into the map.
  expect(await map(page).evaluate((el) => el.__footerMap.scrollWheelZoom.enabled())).toBe(false);
});

test("the map's tiles follow the theme in CSS", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/site_footer");
  await expectMounted(page);

  // The lab is dark by default; strip the class to grade the light palette.
  const tileFilter = () => map(page).locator(".leaflet-tile-pane").evaluate((el) => getComputedStyle(el).filter);
  expect(await tileFilter()).toContain("invert(1)");
  await page.evaluate(() => document.documentElement.classList.remove("dark"));
  expect(await tileFilter()).toBe("none");
});

test("the map mounts again after a Turbo visit, and on a restored snapshot", async ({ page }) => {
  const asked = watchLeaflet(page);
  await blockOffsiteRequests(page);
  await page.goto("/lab/site_footer");
  await expectMounted(page);

  // NOT VACUOUS: a marker on window survives a Turbo visit and dies with a full
  // page load. Without it this spec would pass on two ordinary navigations.
  await page.evaluate(() => { window.__sameDocument = true; });

  await page.locator("footer[data-site-footer] a[href='/lab/site_footer/terms']").click();
  await expect(page.locator("[data-lab-page='terms']")).toBeVisible();
  expect(await page.evaluate(() => window.__sameDocument)).toBe(true);

  // The new body's footer has its own, freshly mounted map.
  await expectMounted(page);

  // Back: Turbo restores its snapshot of the first page. The snapshot was taken
  // with the map torn down, so it is mounted again rather than left as dead DOM.
  await page.goBack();
  await expect(page.locator("[data-lab-page='index']")).toBeVisible();
  expect(await page.evaluate(() => window.__sameDocument)).toBe(true);
  await expectMounted(page);
  await expect(map(page).locator(".leaflet-map-pane")).toHaveCount(1);
  expect(await map(page).evaluate((el) => typeof el.__footerMap.getCenter)).toBe("function");

  // Three mounts, one fetch of the script.
  expect(asked.filter((path) => path.endsWith("leaflet.js"))).toHaveLength(1);
});

test("a footer with no address has no map and never asks for Leaflet", async ({ page }) => {
  const asked = watchLeaflet(page);
  await blockOffsiteRequests(page);
  await page.goto("/lab/site_footer/plain");

  await expect(page.locator("footer[data-site-footer]")).toBeVisible();
  await expect(page.locator("[data-footer-map]")).toHaveCount(0);
  await expect(page.locator("[data-footer-location]")).toHaveCount(0);

  // NOT VACUOUS: wait for `load` and one more beat, so a late fetch would be seen.
  await page.waitForLoadState("load");
  await page.waitForTimeout(300);
  expect(asked).toEqual([]);
  expect(await page.evaluate(() => typeof window.L)).toBe("undefined");
});

test("the footer lays out as a grid without the host's utilities", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.goto("/lab/site_footer");

  // Brand and both link columns share one row at desktop width.
  const tops = await page.locator("footer[data-site-footer] .ftr-cols > *").evaluateAll((els) =>
    els.map((el) => Math.round(el.getBoundingClientRect().top))
  );
  expect(tops).toHaveLength(3);
  expect(new Set(tops).size).toBe(1);

  // On a phone the brand takes the full row and the link columns sit under it.
  await page.setViewportSize({ width: 390, height: 844 });
  const phone = await page.locator("footer[data-site-footer] .ftr-cols > *").evaluateAll((els) =>
    els.map((el) => {
      const box = el.getBoundingClientRect();
      return { top: Math.round(box.top), left: Math.round(box.left) };
    })
  );
  expect(phone[1].top).toBeGreaterThan(phone[0].top);
  expect(phone[2].top).toBe(phone[1].top);
  expect(phone[2].left).toBeGreaterThan(phone[1].left);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});

test("with scripts off the map is a link to directions", async ({ browser, baseURL }) => {
  const context = await browser.newContext({ javaScriptEnabled: false, baseURL });
  const page = await context.newPage();
  await page.goto("/lab/site_footer");

  const fallback = page.locator("[data-footer-map] a.ftr-map-fallback");
  await expect(fallback).toBeVisible();
  await expect(fallback).toHaveAttribute("href", /google\.com\/maps\/dir/);
  await expect(fallback).toContainText("3000 Lawrence St, Denver, CO 80205");
  await context.close();
});
