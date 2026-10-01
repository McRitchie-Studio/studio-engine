const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests, watchPageErrors } = require("./helpers");

// The booking primitives (studio/booking/_frame, _popup, _assets;
// docs/BOOKING.md).
//
// WHY A BROWSER TIER EARNS ITS PLACE HERE. The frame's URL waits in data-src and
// an inline script assigns src only after the window's `load` event, once the
// frame is near the viewport: a third-party frame that starts loading earlier
// holds `load` open for as long as Google takes to answer. The integration tier
// can see data-src in the markup. Only a browser shows the script moving it to
// src, and when. The crop that opens on focus and the dialog that opens in place
// are the same kind of fact.
//
// GOOGLE IS STUBBED. These specs are about WHEN the frame is asked for, and must
// not depend on whether a runner can reach calendar.google.com. Everything else
// off-origin is refused (blockOffsiteRequests), the stub is registered after it,
// and Playwright runs the last route registered first.

// A predicate, not a glob. test/lib/e2e_lane_contract_test.rb counts the specs
// in this file after stripping comments, and a glob ending in slash-star-star
// reads to it as the start of a block comment: two tests vanished from its count.
const isGoogle = (url) => url.hostname === "calendar.google.com";

const frame = (page) => page.locator("iframe[data-booking-frame]");
const dialog = (page) => page.locator("dialog[data-booking-dialog]");

async function stubGoogle(page) {
  const asked = [];
  await blockOffsiteRequests(page);
  await page.route(isGoogle, (route) => {
    asked.push(route.request().url());
    return route.fulfill({
      contentType: "text/html",
      // 300px down: inside the window every cropped lab frame shows, so it can be clicked.
      body: "<p id='stub' style='margin-top:300px'>booking stub</p>",
    });
  });
  return asked;
}

test("a frame below the fold asks Google only once it is scrolled to", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 600 });
  const asked = await stubGoogle(page);
  await page.goto("/lab/site_footer/home");

  // `load` has fired (goto waits for it) and the frame is far below the fold.
  await expect(frame(page)).toHaveCount(1);
  expect(await frame(page).getAttribute("src")).toBeNull();
  // One more beat, so an observer that fired on arming would be seen.
  await page.waitForTimeout(300);
  expect(await frame(page).getAttribute("src")).toBeNull();
  expect(asked).toEqual([]);

  await frame(page).scrollIntoViewIfNeeded();
  await expect(frame(page)).toHaveAttribute("src", /calendar\.google\.com\/calendar\/appointments\/schedules\/.+gv=true$/);
  await expect(page.frameLocator("iframe[data-booking-frame]").locator("#stub")).toHaveText("booking stub");
  expect(asked).toHaveLength(1);
});

test("a frame already in view still waits for the window's load event", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  const asked = await stubGoogle(page);

  // Hold `load` open on a subresource of the page (the footer's logo). An image
  // does not delay DOMContentLoaded, so the frame's script has already run.
  let release;
  const held = new Promise((resolve) => { release = resolve; });
  let holding = false;
  await page.route((url) => url.pathname.endsWith("/e2e/img/nav-logo.png"), async (route) => {
    holding = true;
    await held;
    return route.continue();
  });

  await page.goto("/lab/site_footer/schedule", { waitUntil: "domcontentloaded" });
  await expect(frame(page)).toBeInViewport();
  await expect.poll(() => holding).toBe(true);

  // NOT VACUOUS: the document really is short of `load`, and the frame is in view.
  expect(await page.evaluate(() => document.readyState)).not.toBe("complete");

  // Turbo 7 announces `turbo:load` at DOMContentLoaded, before the window's
  // `load` (Turbo 8, which this lab runs, waits for it). The script listens for
  // that event, so replay the early one: it must still wait.
  await page.evaluate(() => document.dispatchEvent(new Event("turbo:load")));
  await page.waitForTimeout(300);
  expect(await frame(page).getAttribute("src")).toBeNull();
  expect(asked).toEqual([]);

  release();
  await expect(frame(page)).toHaveAttribute("src", /gv=true$/);
  expect(await page.evaluate(() => document.readyState)).toBe("complete");
  expect(asked).toHaveLength(1);
});

test("the frame fills its column", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await stubGoogle(page);
  await page.goto("/lab/site_footer/schedule");

  await expect(frame(page)).toHaveAttribute("src", /gv=true$/);
  // The lab column is 56rem (896px) less its side padding and the frame's border.
  const box = await frame(page).boundingBox();
  expect(box.width).toBeGreaterThanOrEqual(820);
  expect(box.width).toBeLessThanOrEqual(896);
});

// [wrapper height, frame height, frame margin-top] for one lab frame.
const sizes = (page, name) =>
  page.locator(`[data-lab-crop="${name}"] [data-booking-wrap]`).evaluate((el) => {
    const inner = el.querySelector("iframe");
    return [el.clientHeight, inner.offsetHeight, parseInt(getComputedStyle(inner).marginTop, 10)];
  });
const labFrame = (page, name) => page.frameLocator(`[data-lab-crop="${name}"] iframe[data-booking-frame]`);
const labWrap = (page, name) => page.locator(`[data-lab-crop="${name}"] [data-booking-wrap]`);

test("with no crop declared the frame is whole at rest, and using it changes nothing", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await stubGoogle(page);
  await page.goto("/lab/site_footer/schedule");
  await expect(frame(page)).toHaveAttribute("src", /gv=true$/);

  const wrap = page.locator("[data-booking-wrap]");
  const heights = () =>
    wrap.evaluate((el) => [el.clientHeight, el.querySelector("iframe").offsetHeight,
                           parseInt(getComputedStyle(el.querySelector("iframe")).marginTop, 10)]);

  // The whole 732px frame, not a window onto it: no schedule's crop is a default.
  expect(await heights()).toEqual([732, 732, 0]);
  await expect(wrap).not.toHaveClass(/booking-frame-cropped/);
  expect(await wrap.getAttribute("style")).toBeNull();

  await page.frameLocator("iframe[data-booking-frame]").locator("#stub").click();
  await expect(wrap).toHaveClass(/is-open/);
  await page.waitForTimeout(350);
  expect(await heights()).toEqual([732, 732, 0]);
});

test("a cropped frame shows its own window at rest and opens to its own full height once it is used", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await stubGoogle(page);
  await page.goto("/lab/site_footer/crops");
  await expect(page.locator('[data-lab-crop="first"] iframe')).toHaveAttribute("src", /gv=true$/);

  // top 200, bottom 600, frame 720: a 412px window, 194px down a 720px frame.
  expect(await sizes(page, "first")).toEqual([412, 720, -194]);
  await expect(labWrap(page, "first")).not.toHaveClass(/is-open/);

  // A click inside the frame moves focus into it; the parent sees only a blur.
  await labFrame(page, "first").locator("#stub").click();
  await expect(labWrap(page, "first")).toHaveClass(/is-open/);
  await expect.poll(async () => await sizes(page, "first")).toEqual([720, 720, 0]);
});

test("two frames with different crops share a page, and each opens alone", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await stubGoogle(page);
  await page.goto("/lab/site_footer/crops");
  for (const name of ["first", "second", "whole"]) {
    await page.locator(`[data-lab-crop="${name}"] iframe`).scrollIntoViewIfNeeded();
    await expect(page.locator(`[data-lab-crop="${name}"] iframe`)).toHaveAttribute("src", /gv=true$/);
  }

  // Each wrapper carries its own numbers; neither leaks into the other, nor into
  // the frame that has none.
  expect(await sizes(page, "first")).toEqual([412, 720, -194]);
  expect(await sizes(page, "second")).toEqual([342, 640, -144]);
  expect(await sizes(page, "whole")).toEqual([732, 732, 0]);

  await labFrame(page, "second").locator("#stub").click();
  await expect(labWrap(page, "second")).toHaveClass(/is-open/);
  await expect.poll(async () => await sizes(page, "second")).toEqual([640, 640, 0]);
  await expect(labWrap(page, "first")).not.toHaveClass(/is-open/);
  expect(await sizes(page, "first")).toEqual([412, 720, -194]);

  // FRAME TO FRAME. Focus goes from the second frame straight into the first and
  // never through this window, so no second blur fires; the first must open anyway.
  await labFrame(page, "first").locator("#stub").click();
  await expect.poll(async () => await sizes(page, "first")).toEqual([720, 720, 0]);
  expect(await sizes(page, "second")).toEqual([640, 640, 0]);
});

test("below 640px nothing is cropped, declared or not", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await stubGoogle(page);
  await page.goto("/lab/site_footer/crops");

  // NOT VACUOUS: these two wrappers do carry a crop; the width is what drops it.
  await expect(labWrap(page, "first")).toHaveClass(/booking-frame-cropped/);
  await expect(labWrap(page, "second")).toHaveClass(/booking-frame-cropped/);
  for (const name of ["first", "second", "whole"]) expect(await sizes(page, name)).toEqual([1200, 1200, 0]);
});

test("a booking link opens the popup in place, centred, and Escape closes it", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  const errors = watchPageErrors(page, { ownOriginOnly: true });
  const asked = await stubGoogle(page);
  await page.goto("/lab/site_footer");

  await expect(dialog(page)).toBeHidden();
  await page.waitForLoadState("load");
  expect(asked).toEqual([]);

  await page.locator("footer[data-site-footer] a[data-booking-popup]").click();

  // The visitor stays on the page; the dialog opens and only now asks Google.
  await expect(dialog(page)).toBeVisible();
  await expect(page).toHaveURL(/\/lab\/site_footer$/);
  await expect(page.frameLocator("iframe[data-booking-popup-frame]").locator("#stub")).toHaveText("booking stub");
  expect(asked).toHaveLength(1);
  expect(asked[0]).toMatch(/gv=true$/);
  expect(await dialog(page).evaluate((el) => el.matches(":modal"))).toBe(true);

  // Centred in the viewport. Tailwind's reset zeroes a dialog's margin, which is
  // what centres it, and the lab compiles that reset in as every consumer does.
  const box = await dialog(page).boundingBox();
  expect(Math.abs(box.x + box.width / 2 - 640)).toBeLessThanOrEqual(1);
  expect(Math.abs(box.y + box.height / 2 - 450)).toBeLessThanOrEqual(1);
  expect(box.width).toBe(960);

  // The page behind is locked while the dialog is open: a wheel does not move it.
  const overflow = () => page.evaluate(() => getComputedStyle(document.documentElement).overflowY);
  expect(await overflow()).toBe("hidden");
  const scrolled = await page.evaluate(() => window.scrollY);
  await page.mouse.move(20, 20);
  await page.mouse.wheel(0, 400);
  await page.waitForTimeout(150);
  expect(await page.evaluate(() => window.scrollY)).toBe(scrolled);

  await page.keyboard.press("Escape");
  await expect(dialog(page)).toBeHidden();
  expect(await overflow()).not.toBe("hidden");

  // Opening it again does not ask Google a second time. Close is a real button,
  // big enough to hit: it is the way out once focus is inside Google's frame.
  await page.locator("footer[data-site-footer] a[data-booking-popup]").click();
  await expect(dialog(page)).toBeVisible();
  const close = page.locator("dialog[data-booking-dialog] button[data-booking-close]");
  await expect(close).toHaveText("Close ✕");
  expect((await close.boundingBox()).height).toBeGreaterThanOrEqual(44);

  // Its label reads at 4.5:1 or better against its fill, in both themes, by the
  // colours the browser computed (WCAG relative luminance). The lab is dark by
  // default; stripping the class gives the light palette.
  const contrast = () =>
    close.evaluate((el) => {
      const channels = (value) => value.match(/[\d.]+/g).slice(0, 3).map(Number);
      const luminance = (value) => {
        const [r, g, b] = channels(value).map((c) => {
          const s = c / 255;
          return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
        });
        return 0.2126 * r + 0.7152 * g + 0.0722 * b;
      };
      const style = getComputedStyle(el);
      const [hi, lo] = [luminance(style.color), luminance(style.backgroundColor)].sort((a, b) => b - a);
      return { ratio: (hi + 0.05) / (lo + 0.05), color: style.color, background: style.backgroundColor };
    });
  const dark = await contrast();
  expect(dark.color).toMatch(/^rgb\(/);
  expect(dark.background).toMatch(/^rgb\(/);
  expect(dark.ratio).toBeGreaterThanOrEqual(4.5);
  await page.evaluate(() => document.documentElement.classList.remove("dark"));
  const light = await contrast();
  expect(light.background).not.toBe(dark.background);
  expect(light.ratio).toBeGreaterThanOrEqual(4.5);
  await page.evaluate(() => document.documentElement.classList.add("dark"));
  await close.click();
  await expect(dialog(page)).toBeHidden();
  expect(await overflow()).not.toBe("hidden");
  expect(asked).toHaveLength(1);
  expect(errors).toEqual([]);
});

test("with focus inside the frame Escape cannot close the popup, and Close and the backdrop still do", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await stubGoogle(page);
  await page.goto("/lab/site_footer");
  await page.locator("footer[data-site-footer] a[data-booking-popup]").click();
  await expect(dialog(page)).toBeVisible();

  // THE LIMIT, RECORDED AS A FACT. The frame is another origin; once focus is in
  // it, the key press is Google's. If a browser ever starts closing the dialog
  // here, this goes red and the doc's caveat can go.
  await page.frameLocator("iframe[data-booking-popup-frame]").locator("#stub").click();
  await page.keyboard.press("Escape");
  await page.waitForTimeout(200);
  await expect(dialog(page)).toBeVisible();

  await page.locator("dialog[data-booking-dialog] button[data-booking-close]").click();
  await expect(dialog(page)).toBeHidden();

  await page.locator("footer[data-site-footer] a[data-booking-popup]").click();
  await page.frameLocator("iframe[data-booking-popup-frame]").locator("#stub").click();
  await page.mouse.click(20, 20);
  await expect(dialog(page)).toBeHidden();
});

test("on a page that shows the inline frame, a booking link goes to that frame instead of a popup", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 600 });
  const asked = await stubGoogle(page);
  await page.goto("/lab/site_footer/home");

  // The frame is far below the fold and has not been asked for.
  expect(await frame(page).getAttribute("src")).toBeNull();
  const link = page.locator("footer[data-site-footer] a[data-booking-popup]");
  await link.scrollIntoViewIfNeeded();
  // Scrolling to the footer passes the frame, which is what asks Google for it.
  await expect(frame(page)).toHaveAttribute("src", /gv=true$/);

  await link.click();

  // No popup, no navigation: the inline frame is brought up, opened and focused.
  await expect(dialog(page)).toBeHidden();
  await expect(page).toHaveURL(/\/lab\/site_footer\/home$/);
  await expect(page.locator("[data-booking-wrap]")).toHaveClass(/is-open/);
  await expect(page.locator("[data-booking-wrap]")).toBeInViewport({ ratio: 0.5 });
  expect(await page.evaluate(() => document.activeElement.matches("iframe[data-booking-frame]"))).toBe(true);

  // One calendar on the page, asked for once: the popup's frame was never loaded.
  expect(await page.locator("iframe[data-booking-popup-frame]").getAttribute("src")).toBeNull();
  expect(asked).toHaveLength(1);
});

test("a booking link that jumps to a frame never scrolled to asks Google once", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 600 });
  const asked = await stubGoogle(page);
  await page.goto("/lab/site_footer/home");

  // THE JUMP. Hide the frame's block while the page goes to its foot, so the
  // frame never comes near the viewport and its observer never fires: the way a
  // visitor arrives who jumped to the footer (End, an anchor) on a page whose
  // calendar is far above it. NOT VACUOUS: nothing has asked Google yet.
  const link = page.locator("footer[data-site-footer] a[data-booking-popup]");
  await page.evaluate(() => {
    const block = document.querySelector("[data-booking-wrap]").parentElement;
    block.style.display = "none";
    window.scrollTo(0, document.documentElement.scrollHeight);
    return new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(() => { block.style.display = ""; done(); })));
  });
  await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
  await page.waitForTimeout(300);
  expect(await frame(page).getAttribute("src")).toBeNull();
  expect(asked).toEqual([]);
  await expect(frame(page)).not.toBeInViewport();

  // The click assigns src and scrolls to the frame, which then enters the
  // viewport under a still-armed observer. That second arrival must not ask again.
  await link.click();
  await expect(frame(page)).toHaveAttribute("src", /gv=true$/);
  await expect(page.locator("[data-booking-wrap]")).toBeInViewport({ ratio: 0.5 });
  await expect(page.frameLocator("iframe[data-booking-frame]").locator("#stub")).toHaveText("booking stub");
  await page.waitForTimeout(600);
  expect(asked).toHaveLength(1);
});

test("with scripts off the frame is replaced by a plain link to the booking page", async ({ browser, baseURL }) => {
  const context = await browser.newContext({ javaScriptEnabled: false, baseURL });
  const page = await context.newPage();
  await page.goto("/lab/site_footer/schedule");

  const link = page.locator("[data-booking-wrap] .booking-frame-noscript a");
  await expect(link).toBeVisible();
  await expect(link).toHaveAttribute("href", "https://calendar.google.com/calendar/appointments/schedules/LAB-SCHEDULE");
  // The frame that would never load is not left as an empty white box.
  await expect(frame(page)).toBeHidden();
  expect(await page.locator("[data-booking-wrap]").evaluate((el) => el.clientHeight)).toBeLessThan(200);
  await context.close();
});

test("a third-party frame's console noise is scoped out by origin, and the page's own errors are not", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await blockOffsiteRequests(page);
  // Google's real frame logs this on its own. Reproduce it from Google's origin:
  // one console error, one uncaught exception.
  await page.route(isGoogle, (route) =>
    route.fulfill({
      contentType: "text/html",
      body: "<p id='stub'>booking stub</p><script>console.error('requestStorageAccess: Permission denied');" +
            "setTimeout(function () { throw new Error('thrown inside the third-party frame'); }, 0);</script>",
    })
  );
  const everything = watchPageErrors(page);
  const ours = watchPageErrors(page, { ownOriginOnly: true });

  await page.goto("/lab/site_footer/schedule");
  await expect(page.frameLocator("iframe[data-booking-frame]").locator("#stub")).toHaveText("booking stub");

  // NOT VACUOUS: the unscoped collector DID hear the frame, both ways.
  await expect.poll(() => everything.join("\n")).toContain("requestStorageAccess: Permission denied");
  await expect.poll(() => everything.join("\n")).toContain("thrown inside the third-party frame");
  expect(ours).toEqual([]);

  // The page's own errors still count, logged or thrown.
  await page.evaluate(() => {
    console.error("an error from the app's own origin");
    setTimeout(() => { throw new Error("thrown by the app's own origin"); }, 0);
  });
  await expect.poll(() => ours.length).toBe(2);
  expect(ours.join("\n")).toContain("an error from the app's own origin");
  expect(ours.join("\n")).toContain("thrown by the app's own origin");
});

test("a page's own booking link opens the same popup, and the backdrop closes it", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await stubGoogle(page);
  await page.goto("/lab/site_footer");

  await page.locator("a.lab-booking-link[data-booking-popup]").click();
  await expect(dialog(page)).toBeVisible();
  await expect(page).toHaveURL(/\/lab\/site_footer$/);

  // A click outside the panel lands on the dialog element itself (its backdrop).
  await page.mouse.click(20, 20);
  await expect(dialog(page)).toBeHidden();

  // AN APP'S OWN LOCAL LINK IS NOT THE ENGINE'S. A host that still renders its
  // own booking partials marks its links a[data-booking-popup] too, without the
  // engine's data-studio-booking. The engine's script leaves those alone.
  await page.evaluate(() => {
    const local = document.createElement("a");
    local.href = "#local-booking";
    local.setAttribute("data-booking-popup", "");
    local.className = "local-booking-link";
    local.textContent = "A host's own booking link";
    document.querySelector("[data-lab-main]").appendChild(local);
  });
  await page.locator("a.local-booking-link").click();
  await expect(page).toHaveURL(/#local-booking$/);
  await expect(dialog(page)).toBeHidden();
});

test("with no dialog on the page, or on a modified click, the link's href is the fallback", async ({ page, context }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await stubGoogle(page);
  await page.goto("/lab/site_footer");
  const link = page.locator("footer[data-site-footer] a[data-booking-popup]");
  await expect(link).toHaveAttribute("href", "/lab/site_footer/schedule");

  // A modified click is left to the browser: a new tab on the booking page, and
  // no dialog here.
  const [tab] = await Promise.all([context.waitForEvent("page"), link.click({ modifiers: ["ControlOrMeta"] })]);
  // A new tab starts on about:blank; wait for it to arrive, not merely to load.
  await tab.waitForURL(/\/lab\/site_footer\/schedule$/);
  await expect(dialog(page)).toBeHidden();
  await tab.close();

  // No dialog (a page that renders booking links and no popup): the link is a link.
  await dialog(page).evaluate((el) => el.remove());
  await link.click();
  await expect(page.locator("[data-lab-page='schedule']")).toBeVisible();
  await expect(page).toHaveURL(/\/lab\/site_footer\/schedule$/);
});

test("the popup still opens after a Turbo visit, and is not restored open", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  const asked = await stubGoogle(page);
  await page.goto("/lab/site_footer");
  await page.evaluate(() => { window.__sameDocument = true; });

  await page.locator("footer[data-site-footer] a[href='/lab/site_footer/terms']").click();
  await expect(page.locator("[data-lab-page='terms']")).toBeVisible();
  expect(await page.evaluate(() => window.__sameDocument)).toBe(true);

  // The click handler is delegated from document, so the new body's link works.
  await page.locator("footer[data-site-footer] a[data-booking-popup]").click();
  await expect(dialog(page)).toBeVisible();
  await expect(page).toHaveURL(/\/lab\/site_footer\/terms$/);

  // Leave with the dialog open, then come back to the snapshot: it must be shut.
  await page.evaluate(() => window.Turbo.visit("/lab/site_footer"));
  await expect(page.locator("[data-lab-page='index']")).toBeVisible();
  await page.goBack();
  await expect(page.locator("[data-lab-page='terms']")).toBeVisible();
  await expect(dialog(page)).toBeHidden();
  // Nor is its frame restored loaded: the snapshot was taken with the src put
  // back to waiting, so the restored page does not ask Google for a closed popup.
  expect(await page.locator("iframe[data-booking-popup-frame]").getAttribute("src")).toBeNull();
  expect(asked).toHaveLength(1);
});
