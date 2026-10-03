const { test, expect, devices } = require("@playwright/test");
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
  // The mount script ran: it rides studio/site_footer/_map_assets, which only a
  // map renders, and arms itself once.
  expect(await page.evaluate(() => window.__studioFooterMapsArmed)).toBe(true);
  // The map's own styles applied: .ftr-map isolates (Leaflet's z-indexes stay inside).
  expect(await map(page).evaluate((el) => getComputedStyle(el).isolation)).toBe("isolate");

  // The map runs edge to edge: as wide as the viewport, not the centred column.
  const widths = await map(page).evaluate((el) => [el.getBoundingClientRect().width, document.documentElement.clientWidth]);
  expect(widths[0]).toBe(widths[1]);
  expect(await map(page).evaluate((el) => el.getBoundingClientRect().height)).toBeGreaterThanOrEqual(256);

  // The map is centred on the address the footer prints.
  const centre = await map(page).evaluate((el) => {
    const c = el.__footerMap.getCenter();
    return [c.lat.toFixed(3), c.lng.toFixed(3)];
  });
  expect(centre).toEqual(["38.889", "-77.035"]);

  // Page scroll stays page scroll until the visitor clicks into the map.
  expect(await map(page).evaluate((el) => el.__footerMap.scrollWheelZoom.enabled())).toBe(false);
  // With a mouse the map drags: the no-drag rule is for touch devices only.
  expect(await map(page).evaluate((el) => el.__footerMap.dragging.enabled())).toBe(true);

  // Leaflet puts .leaflet-container on the map element ITSELF. The footer's rule
  // for it has to win over Leaflet's own grey (#ddd) and its 12px Helvetica.
  const style = await map(page).evaluate((el) => {
    const computed = getComputedStyle(el);
    return { background: computed.backgroundColor, font: computed.fontFamily, body: getComputedStyle(document.body).fontFamily };
  });
  expect(style.background).not.toBe("rgb(221, 221, 221)");
  expect(style.font).toBe(style.body);

  // Leaflet numbers its panes and controls up to z-index 1000. The map is its
  // own stacking context, so none of that reaches the page's layers: this is
  // the condition test/lib/layer_scale_contract_test.rb exempts leaflet.css on.
  const stacking = await map(page).evaluate((el) => ({
    isolation: getComputedStyle(el).isolation,
    control: parseInt(getComputedStyle(el.querySelector(".leaflet-top")).zIndex, 10),
  }));
  expect(stacking.control).toBe(1000);
  expect(stacking.isolation).toBe("isolate");
});

test("on a touch device a one-finger swipe on the map scrolls the page", async ({ browser, baseURL }) => {
  // A phone: touch input and a mobile user agent, which is what L.Browser.mobile reads.
  const context = await browser.newContext({ ...devices["Pixel 5"], baseURL });
  const page = await context.newPage();
  await blockOffsiteRequests(page);
  await page.goto("/lab/site_footer");
  await expectMounted(page);

  // NOT VACUOUS: Leaflet itself sees a mobile browser here.
  expect(await page.evaluate(() => window.L.Browser.mobile)).toBe(true);

  const state = await map(page).evaluate((el) => ({
    dragging: el.__footerMap.dragging.enabled(),
    pinch: el.__footerMap.touchZoom.enabled(),
    touchAction: getComputedStyle(el).touchAction,
  }));
  expect(state.dragging).toBe(false);
  expect(state.pinch).toBe(true);
  // The browser keeps the pan gesture for the page; `none` would hand it to the map.
  expect(state.touchAction).toBe("pan-x pan-y");

  // And the gesture itself: put the map mid-screen, swipe up on it with one
  // finger, and the PAGE moves while the map's centre does not.
  await map(page).evaluate((el) => el.scrollIntoView({ block: "center" }));
  const before = await map(page).evaluate((el) => {
    const box = el.getBoundingClientRect();
    const centre = el.__footerMap.getCenter();
    return { x: Math.round(box.left + box.width / 2), y: Math.round(box.top + box.height / 2),
             scrollY: window.scrollY, centre: [centre.lat, centre.lng] };
  });
  expect(before.scrollY).toBeGreaterThan(150);

  // The finger goes down on the map and drags 160px down the screen, as real
  // touch events (start, a run of moves a frame apart, end).
  const client = await context.newCDPSession(page);
  const touch = (type, y) =>
    client.send("Input.dispatchTouchEvent", { type, touchPoints: type === "touchEnd" ? [] : [{ x: before.x, y }] });
  await touch("touchStart", before.y);
  for (let step = 1; step <= 16; step++) {
    await touch("touchMove", before.y + step * 10);
    await page.waitForTimeout(16);
  }
  await touch("touchEnd");

  await expect.poll(() => page.evaluate(() => window.scrollY)).toBeLessThan(before.scrollY - 60);
  const after = await map(page).evaluate((el) => {
    const centre = el.__footerMap.getCenter();
    return [centre.lat, centre.lng];
  });
  expect(after).toEqual(before.centre);
  await context.close();
});

test("a map below the fold costs nothing until the visitor scrolls near it", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 600 });
  const asked = watchLeaflet(page);
  const tiles = [];
  page.on("request", (request) => { if (request.url().includes("tile.openstreetmap.org")) tiles.push(request.url()); });
  await blockOffsiteRequests(page);
  await page.goto("/lab/site_footer/home");

  // `load` has fired and the footer is thousands of pixels away: no Leaflet, no tile.
  await expect(map(page)).toHaveCount(1);
  await page.waitForTimeout(300);
  expect(asked).toEqual([]);
  expect(tiles).toEqual([]);
  expect(await page.evaluate(() => typeof window.L)).toBe("undefined");
  await expect(map(page).locator(".ftr-map-fallback")).toHaveCount(1);

  await map(page).scrollIntoViewIfNeeded();
  await expectMounted(page);
  expect(asked.filter((path) => path.endsWith("leaflet.js"))).toHaveLength(1);
  // NOT VACUOUS: once mounted the map does ask for tiles, so their absence above meant something.
  await expect.poll(() => tiles.length).toBeGreaterThan(0);
});

test("a map already in view still waits for the window's load event", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  const asked = watchLeaflet(page);
  await blockOffsiteRequests(page);

  // Hold `load` open on a subresource of the page (the footer's logo), as
  // booking_frame.spec.js does for the frame.
  let release;
  const held = new Promise((resolve) => { release = resolve; });
  let holding = false;
  await page.route((url) => url.pathname.endsWith("/e2e/img/nav-logo.png"), async (route) => {
    holding = true;
    await held;
    return route.continue();
  });

  await page.goto("/lab/site_footer", { waitUntil: "domcontentloaded" });
  await expect(map(page)).toBeInViewport();
  await expect.poll(() => holding).toBe(true);
  expect(await page.evaluate(() => document.readyState)).not.toBe("complete");

  // Turbo 7 announces `turbo:load` before `load`; replay it. The map must still wait.
  await page.evaluate(() => document.dispatchEvent(new Event("turbo:load")));
  await page.waitForTimeout(300);
  expect(asked).toEqual([]);
  await expect(map(page)).not.toHaveClass(/leaflet-container/);

  release();
  await expectMounted(page);
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
  // No map, so the map's script never ran and its styles are not on the page:
  // studio/site_footer/_map_assets is rendered only with a map.
  expect(await page.evaluate(() => window.__studioFooterMapsArmed)).toBeUndefined();
  expect(await page.evaluate(() => [...document.styleSheets].some((sheet) => {
    try { return [...sheet.cssRules].some((rule) => /leaflet|\.ftr-map/.test(rule.cssText)); } catch (e) { return false; }
  }))).toBe(false);
  // The footer's own styles still applied, and a link is painted at full
  // opacity in the link ink (--ftr-link-ink), not the body colour faded.
  const link = page.locator("footer[data-site-footer] a.ftr-link").first();
  expect(await link.evaluate((el) => getComputedStyle(el).opacity)).toBe("1");
  expect(await link.evaluate((el) => {
    const probe = document.createElement("span");
    probe.style.color = getComputedStyle(el.closest(".ftr")).getPropertyValue("--ftr-link-ink");
    el.closest(".ftr").appendChild(probe);
    const want = getComputedStyle(probe).color;
    probe.remove();
    return getComputedStyle(el).color === want;
  })).toBe(true);
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

// THE FOOTER'S ROWS. What a visitor sees is which columns share a row, and
// whether the email address in the Contact column is on one line. 0.83.0's equal
// `minmax(0, 1fr)` tracks broke the address in two at every width; a wrapping
// flex row kept it whole but gave a wide column a row to itself. Neither shows
// in the markup: the text and the elements are all there either way. So these
// specs read the rendered rows, at the widths the layout has to hold:
//   320, 360, 390: the brand, then the link columns two to a row
//   768:        the brand, then every link column in one row
//   1024, 1280: the brand in that row too
const rowsOf = (page) =>
  page.locator("footer[data-site-footer] .ftr-cols > *").evaluateAll((els) => {
    const rows = new Map();
    els.forEach((el) => {
      const top = Math.round(el.getBoundingClientRect().top);
      rows.set(top, (rows.get(top) || []).concat(el.getAttribute("aria-label") || "brand"));
    });
    return [...rows.keys()].sort((a, b) => a - b).map((top) => rows.get(top).join("+"));
  });
const email = (page) =>
  page.locator("footer[data-site-footer] nav[aria-label='Contact'] a[href^='mailto:']").evaluate((link) => ({
    text: link.textContent.trim(),
    lines: link.getClientRects().length,
    // Held by its track, not only by nowrap: an unwrappable label in a track too
    // narrow for it would run out of its column and over the next one.
    inside: link.getBoundingClientRect().right <= link.closest("nav").getBoundingClientRect().right + 0.5,
  }));
// Nothing runs off the page, and no column runs out of the footer's own column.
const overflow = (page) =>
  page.evaluate(() => {
    const wrap = document.querySelector("footer[data-site-footer] .ftr-wrap").getBoundingClientRect();
    const right = Math.max(...[...document.querySelectorAll("footer[data-site-footer] .ftr-cols > *")].map((el) => el.getBoundingClientRect().right));
    return { page: document.documentElement.scrollWidth - window.innerWidth, footer: Math.max(0, Math.round(right - (wrap.right - 16))) };
  });

async function expectRows(page, count, expected) {
  await blockOffsiteRequests(page);
  for (const [width, rows] of Object.entries(expected)) {
    await page.setViewportSize({ width: Number(width), height: 900 });
    await page.goto(`/lab/site_footer/columns/${count}`);

    expect(await rowsOf(page), `rows at ${width}px`).toEqual(rows);
    const address = await email(page);
    expect(address.text).toBe("team@lab-studio.example");
    expect(address.lines, `the address is on one line at ${width}px`).toBe(1);
    expect(address.inside, `the address stays inside its column at ${width}px`).toBe(true);
    expect(await overflow(page), `nothing overflows at ${width}px`).toEqual({ page: 0, footer: 0 });
  }
}

test("four link columns: two to a row on a phone, one row from 768px, beside the brand from 1024px", async ({ page }) => {
  await expectRows(page, 4, {
    320: ["brand", "Contact+Company", "Solutions+Legal"],
    360: ["brand", "Contact+Company", "Solutions+Legal"],
    390: ["brand", "Contact+Company", "Solutions+Legal"],
    768: ["brand", "Contact+Company+Solutions+Legal"],
    1024: ["brand+Contact+Company+Solutions+Legal"],
    1280: ["brand+Contact+Company+Solutions+Legal"],
  });
});

test("three link columns: two to a row on a phone, one row from 768px, beside the brand from 1024px", async ({ page }) => {
  await expectRows(page, 3, {
    320: ["brand", "Contact+Company", "Solutions"],
    360: ["brand", "Contact+Company", "Solutions"],
    390: ["brand", "Contact+Company", "Solutions"],
    768: ["brand", "Contact+Company+Solutions"],
    1024: ["brand+Contact+Company+Solutions"],
    1280: ["brand+Contact+Company+Solutions"],
  });
});

test("two link columns: one row under the brand, and beside it from 1024px", async ({ page }) => {
  await expectRows(page, 2, {
    320: ["brand", "Contact+Company"],
    360: ["brand", "Contact+Company"],
    390: ["brand", "Contact+Company"],
    768: ["brand", "Contact+Company"],
    1024: ["brand+Contact+Company"],
    1280: ["brand+Contact+Company"],
  });
});

// A FIFTH COLUMN is past what one row holds: the brand stays across the top and
// the columns wrap four to a row (two on a phone). Nothing is broken and nothing
// runs off the page.
test("five link columns wrap four to a row under the brand", async ({ page }) => {
  await expectRows(page, 5, {
    390: ["brand", "Contact+Company", "Solutions+Legal", "Resources"],
    768: ["brand", "Contact+Company+Solutions+Legal", "Resources"],
    1024: ["brand", "Contact+Company+Solutions+Legal", "Resources"],
    1280: ["brand", "Contact+Company+Solutions+Legal", "Resources"],
  });
});

// AN APP'S OWN OVERRIDE. A host that patched 0.83.0's tracks from its own
// stylesheet did it with rules like these, more specific than the engine's.
// They still apply (the row is a grid), and they draw the same rows: an app may
// keep the block or delete it.
test("an app's 0.83.0 track override still draws the same rows, with the address whole", async ({ page }) => {
  await blockOffsiteRequests(page);
  const expected = {
    320: ["brand", "Contact+Company", "Solutions+Legal"],
    390: ["brand", "Contact+Company", "Solutions+Legal"],
    768: ["brand", "Contact+Company+Solutions+Legal"],
    1024: ["brand+Contact+Company+Solutions+Legal"],
    1280: ["brand+Contact+Company+Solutions+Legal"],
  };
  for (const [width, rows] of Object.entries(expected)) {
    await page.setViewportSize({ width: Number(width), height: 900 });
    await page.goto("/lab/site_footer/columns/4");
    await page.addStyleTag({ content: `
      footer[data-site-footer] .ftr-cols { grid-template-columns: 1.2fr 1fr; }
      footer[data-site-footer] .ftr-link[href^="mailto:"] { overflow-wrap: normal; }
      @media (min-width: 768px) { footer[data-site-footer] .ftr-cols { grid-template-columns: 1.7fr 1fr 1fr 1fr; } }
      @media (min-width: 1024px) { footer[data-site-footer] .ftr-cols { grid-template-columns: 1.7fr 1.5fr 1fr 1fr 1fr; } }` });

    expect(await rowsOf(page), `rows at ${width}px`).toEqual(rows);
    const address = await email(page);
    expect(address.lines, `the address is on one line at ${width}px`).toBe(1);
    expect(address.inside, `the address stays inside its column at ${width}px`).toBe(true);
    expect(await overflow(page), `nothing overflows at ${width}px`).toEqual({ page: 0, footer: 0 });
  }
});

test("on a screen narrower than any phone the address breaks rather than running off the page", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.setViewportSize({ width: 240, height: 800 });
  await page.goto("/lab/site_footer/columns/2");

  expect((await email(page)).lines).toBeGreaterThan(1);
  expect((await overflow(page)).page).toBe(0);
});

test("a column's width hint sets its own track", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.setViewportSize({ width: 1280, height: 900 });
  const widths = () =>
    page.locator("footer[data-site-footer] .ftr-cols > *").evaluateAll((els) => els.map((el) => el.getBoundingClientRect().width));

  // No hint: the brand 1.7 shares, the first column 1.5, the others 1.
  await page.goto("/lab/site_footer/columns/3");
  const plain = await widths();
  expect(plain[1] / plain[2]).toBeGreaterThan(1.45);
  expect(plain[1] / plain[2]).toBeLessThan(1.55);
  expect(plain[0] / plain[2]).toBeGreaterThan(1.65);
  expect(plain[0] / plain[2]).toBeLessThan(1.75);
  expect(Math.abs(plain[2] - plain[3])).toBeLessThanOrEqual(1);

  await page.goto("/lab/site_footer/columns/3?hint=2.5");
  const hinted = await widths();
  expect(hinted[1] / hinted[2]).toBeGreaterThan(2.45);
  expect(hinted[1] / hinted[2]).toBeLessThan(2.55);

  // And at 768px, where the brand is on its own row, the hint still sets the track.
  await page.setViewportSize({ width: 768, height: 900 });
  await page.goto("/lab/site_footer/columns/3?hint=2.5");
  const tablet = await widths();
  expect(tablet[1] / tablet[2]).toBeGreaterThan(2.45);
  expect(tablet[1] / tablet[2]).toBeLessThan(2.55);
});

test("the footer's headings and small print set their own line heights", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.goto("/lab/site_footer/schedule");

  const lineHeight = (selector) => page.locator(selector).first().evaluate((el) => getComputedStyle(el).lineHeight);
  // NOT VACUOUS: the page's own line height is 1.5, which would give 45px and 21px.
  expect(await page.evaluate(() => getComputedStyle(document.body).lineHeight)).toBe("24px");
  expect(await lineHeight("footer[data-site-footer] .ftr-location-title")).toBe("36px");
  expect(await lineHeight("footer[data-site-footer] .ftr-legal p")).toBe("20px");
  expect(await lineHeight("footer[data-site-footer] .ftr-copyright")).toBe("20px");
  expect(await lineHeight(".booking-frame-note")).toBe("20px");
});

test("with scripts off the map is a link to directions", async ({ browser, baseURL }) => {
  const context = await browser.newContext({ javaScriptEnabled: false, baseURL });
  const page = await context.newPage();
  await page.goto("/lab/site_footer");

  const fallback = page.locator("[data-footer-map] a.ftr-map-fallback");
  await expect(fallback).toBeVisible();
  await expect(fallback).toHaveAttribute("href", /google\.com\/maps\/dir/);
  await expect(fallback).toContainText("123 Example St, Washington, DC 20024");
  await context.close();
});
