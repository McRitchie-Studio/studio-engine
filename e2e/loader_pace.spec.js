const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests } = require("./helpers");

// [e2e] The one pace of a page load (docs/LOADER.md): under 350ms no loader; once shown, at
// least 750ms. /lab/page_transitions renders no overlay of its own, so these read the one every
// app gets from layouts/studio/_head. `slow=ms` makes page b answer that late.
const LAB = "/lab/page_transitions";

async function timeline(page, query) {
  await blockOffsiteRequests(page);
  await page.addInitScript(() => {
    const t = (window.__t = {});
    const stamp = (key) => { if (t[key] === undefined && t.click !== undefined) t[key] = Math.round(performance.now() - t.click); };
    window.__mark = () => { t.click = performance.now(); };
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
  await page.route("**/e2e/img/pt-hung.png", () => {});
  await timeline(page, "direction=left&slow=450&img=hung");
  await click(page);
  const t = await landed(page);
  report("slow=450, hung image", t);
  expect(t.loaderOut - t.loaderIn).toBeGreaterThanOrEqual(730);
  expect(t.render - t.pictureTaken, "the image wait ran its 500ms cap").toBeGreaterThanOrEqual(450);
  expect(t.render - t.pictureTaken).toBeLessThan(900);
});

test("a failed visit clears the loader at once", async ({ page }) => {
  await timeline(page, "direction=left");
  await page.route("**/lab/page_transitions_b*", async (route) => {
    await new Promise((done) => setTimeout(done, 500));
    await route.abort();
  });
  await click(page);
  await expect(page.locator("[data-studio-loader-overlay]")).toBeVisible();
  await expect(page.locator("[data-studio-loader-overlay]")).toBeHidden({ timeout: 400 });
  expect(await page.evaluate(() => window.__t.loaderOut - window.__t.loaderIn)).toBeLessThan(400);
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

test("under a strict policy the overlay arrives whole, and a signing-style page gains no wait", async ({ page }) => {
  await timeline(page, "direction=left&strict=1&control=reload&slow=450");
  await click(page);
  await expect(page.locator('[data-test="page-b"]')).toBeVisible();
  const t = await page.evaluate(() => JSON.parse(sessionStorage.getItem("pt-violations") || "[]"));
  expect(t).toEqual([]);
});

test("the strict page itself raises no violation when its overlay shows", async ({ page }) => {
  await timeline(page, "direction=left&strict=1&slow=450");
  await click(page);
  const overlay = page.locator("[data-studio-loader-overlay]");
  await expect(overlay).toBeVisible();
  expect(await page.evaluate(() => getComputedStyle(document.querySelector("[data-studio-loader-overlay] .studio-loader")).getPropertyValue("--studio-loader-size").trim())).toBe("96px");
  expect(await page.evaluate(() => window.__t.violations || [])).toEqual([]);
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
