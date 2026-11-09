const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests } = require("./helpers");

// [e2e] The one pace of a page load (docs/LOADER.md): under 350ms no loader; once shown, at
// least 750ms. /lab/page_transitions renders no overlay of its own, so these read the one every
// app gets from layouts/studio/_head. `slow=ms` makes page b answer that late.
//
// EVERY TIME IS FROM THE VISIT'S OWN START, turbo:visit, which is when studio/loader starts its
// clock (350ms, then at least 750ms shown). Not from before Playwright's click: on a loaded
// machine the click alone took over 250ms to land, and a limit read from the test's side of it
// measured the host (787ms against 700, a fast visit's move at 453 against 350). A held wait
// still reads 1100ms or later on the visit's clock, so every limit still catches one.
const LAB = "/lab/page_transitions";

async function timeline(page, query) {
  await blockOffsiteRequests(page);
  await page.route("**/e2e/img/pt-hung.png", () => {});
  await page.addInitScript(() => {
    const t = (window.__t = {});
    const stamp = (key) => { if (t[key] === undefined && t.visit !== undefined) t[key] = Math.round(performance.now() - t.visit); };
    window.__mark = () => { t.click = performance.now(); };
    // Capture, so this runs ahead of the page's own turbo:visit listeners, studio/loader's included.
    document.addEventListener("turbo:visit", () => { if (t.click !== undefined && t.visit === undefined) t.visit = performance.now(); }, { capture: true });
    const start = Document.prototype.startViewTransition;
    if (start) {
      Document.prototype.startViewTransition = function (...args) {
        stamp("pictureTaken");
        const overlay = document.querySelector("[data-studio-loader-overlay]");
        t.overlayInPicture = !!overlay && !overlay.hidden;
        return start.apply(this, args);
      };
    }
    document.addEventListener("turbo:render", () => stamp("render"));
    document.addEventListener("securitypolicyviolation", (event) => { (t.violations ||= []).push(event.violatedDirective); });
    const tick = () => {
      const overlay = document.querySelector("[data-studio-loader-overlay]");
      if (overlay && !overlay.hidden) stamp("loaderIn");
      if (t.loaderIn !== undefined && (!overlay || overlay.hidden)) stamp("loaderOut");
      const moving = document.getAnimations().filter((a) => (a.animationName || "").startsWith("pt-"));
      if (moving.length) { stamp("moveStart"); t.moved = true; }
      else if (t.moved) stamp("moveEnd");
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
  await page.goto(`${LAB}?${query}`);
  await page.waitForFunction(() => window.Turbo);
}

async function click(page, testId = "other") {
  await page.evaluate(() => window.__mark());
  await page.locator(`[data-test="${testId}"]`).first().click();
}

const landed = async (page) => {
  await expect(page.locator('[data-test="page-b"]')).toBeVisible();
  await page.waitForFunction(() => document.documentElement.dataset.pageTransition === undefined
    && !document.getAnimations().some((a) => (a.animationName || "").startsWith("pt-")));
  await page.waitForTimeout(60);
  return page.evaluate(() => window.__t);
};
const report = (name, t) => { console.log(`[pace] ${name}: ${JSON.stringify(t)}`); };

test("a fast visit shows no loader and gains no wait", async ({ page }) => {
  await timeline(page, "direction=left");
  await click(page);
  const t = await landed(page);
  report("fast", t);
  expect(t.loaderIn).toBeUndefined();
  expect(t.moveStart).toBeLessThan(350);
});

test("a response just after the loader appears still gets the whole minimum, then the move", async ({ page }) => {
  await timeline(page, "direction=left&slow=450");
  await click(page);
  const t = await landed(page);
  report("slow=450, slide", t);
  expect(t.loaderIn).toBeGreaterThanOrEqual(340);
  expect(t.loaderOut - t.loaderIn).toBeGreaterThanOrEqual(730);
  expect(t.overlayInPicture, "the old picture must not carry the loader").toBe(false);
  expect(t.moveStart).toBeGreaterThanOrEqual(t.loaderOut - 20);
  expect(t.moveEnd - t.moveStart).toBeGreaterThan(600);
});

test("a long load keeps the loader until the page is ready, and adds nothing", async ({ page }) => {
  await timeline(page, "direction=left&slow=1500");
  await click(page);
  const t = await landed(page);
  report("slow=1500, slide", t);
  expect(t.loaderOut - t.loaderIn).toBeGreaterThanOrEqual(1000);
  expect(t.loaderOut).toBeLessThan(1500 + 400);
  expect(t.overlayInPicture).toBe(false);
});

test("the minimum holds in an app with transitions off", async ({ page }) => {
  await timeline(page, "slow=450");
  await click(page);
  const t = await landed(page);
  report("slow=450, no transitions", t);
  expect(t.loaderOut - t.loaderIn).toBeGreaterThanOrEqual(730);
  expect(t.moveStart).toBeUndefined();
});

test("the image wait comes after the minimum, and neither cuts the other short", async ({ page }) => {
  await timeline(page, "direction=left&slow=450&img=hung");
  await click(page);
  const t = await landed(page);
  report("slow=450, hung image", t);
  expect(t.loaderOut - t.loaderIn).toBeGreaterThanOrEqual(730);
  expect(t.render - t.pictureTaken, "the image wait ran its 500ms cap").toBeGreaterThanOrEqual(450);
  expect(t.render - t.pictureTaken).toBeLessThan(900);
});

test("a page that answers 500 gains no wait", async ({ page }) => {
  await timeline(page, "direction=left");
  await page.route("**/lab/page_transitions_b*", async (route) => {
    await new Promise((done) => setTimeout(done, 450));
    await route.fulfill({ status: 500, contentType: "text/html", body: "<html><body><h1 data-test=\"page-b\">Broken</h1></body></html>" });
  });
  await click(page);
  await expect(page.locator('h1[data-test="page-b"]')).toBeVisible();
  const t = await page.evaluate(() => window.__t);
  report("500 at 450", t);
  expect(t.render).toBeLessThan(700);
});

test("a visit the network drops clears the loader at once", async ({ page }) => {
  await timeline(page, "direction=left");
  await page.evaluate(() => {
    document.addEventListener("turbo:fetch-request-error", () => {
      const overlay = document.querySelector("[data-studio-loader-overlay]");
      sessionStorage.setItem("pt-dropped", JSON.stringify({ hidden: !overlay || overlay.hidden, shown: window.__t.loaderIn !== undefined }));
    });
  });
  let dropped = false;
  await page.route("**/lab/page_transitions_b*", async (route) => {
    if (dropped) return route.continue();
    dropped = true;
    await new Promise((done) => setTimeout(done, 450));
    return route.abort();
  });
  await click(page);
  await expect.poll(() => page.evaluate(() => sessionStorage.getItem("pt-dropped"))).not.toBeNull();
  expect(JSON.parse(await page.evaluate(() => sessionStorage.getItem("pt-dropped")))).toEqual({ hidden: true, shown: true });
});

test("StudioLoader.hide ends the wait at once", async ({ page }) => {
  await timeline(page, "direction=left&slow=450");
  await click(page);
  await page.waitForFunction(() => {
    const overlay = document.querySelector("[data-studio-loader-overlay]");
    return overlay && !overlay.hidden;
  });
  await page.waitForTimeout(150);
  await page.evaluate(() => window.StudioLoader.hide());
  const t = await landed(page);
  report("hide() mid wait", t);
  expect(t.loaderOut - t.loaderIn).toBeLessThan(400);
});

test("a response that asks for a full load, as a signing page does, gains no wait", async ({ page }) => {
  await timeline(page, "direction=left&strict=1&control=reload&slow=450");
  await page.evaluate(() => {
    document.addEventListener("turbo:reload", () => sessionStorage.setItem("pt-reload-at", String(Math.round(performance.now() - window.__t.visit))));
  });
  await click(page);
  await expect(page.locator('[data-test="page-b"]')).toBeVisible();
  expect(Number(await page.evaluate(() => sessionStorage.getItem("pt-reload-at")))).toBeLessThan(700);
});

test("the strict page itself raises no violation when its overlay shows", async ({ page }) => {
  await timeline(page, "direction=left&strict=1&slow=450");
  await click(page);
  const overlay = page.locator("[data-studio-loader-overlay]");
  await expect(overlay).toBeVisible();
  expect(await page.evaluate(() => getComputedStyle(document.querySelector("[data-studio-loader-overlay] .studio-loader")).getPropertyValue("--studio-loader-size").trim())).toBe("96px");
  expect(await page.evaluate(() => window.__t.violations || [])).toEqual([]);
});

test("a slow replace visit never shows the overlay the head carries", async ({ page }) => {
  await timeline(page, "direction=left");
  // Read on every frame, never held from before the visit: the overlay may not exist yet.
  const shown = page.evaluate(() => new Promise((done) => {
    let seen = false;
    const tick = () => {
      const overlay = document.querySelector("[data-studio-loader-overlay]");
      if (overlay && !overlay.hidden) seen = true;
    };
    const timer = setInterval(tick, 20);
    window.Turbo.visit(document.querySelector('[data-test="other"]').href.replace("page_transitions_b?", "page_transitions_b?slow=900&"), { action: "replace" });
    setTimeout(() => { clearInterval(timer); done(seen); }, 800);
  }));
  expect(await shown).toBe(false);
});

test("Back to a cached page gains no wait", async ({ page }) => {
  await timeline(page, "direction=left");
  await click(page);
  await landed(page);
  await page.evaluate(() => { window.__t = { click: performance.now() }; });
  await page.goBack();
  await expect(page.locator('[data-test="page-a"]')).toBeVisible();
  await page.waitForTimeout(200);
  const t = await page.evaluate(() => window.__t);
  expect(t.loaderIn).toBeUndefined();
});
