const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The loader family (docs/LOADER.md, "The family") on /lab/loaders, the
// style guide's own Loaders section, and /lab/pull_to_refresh.
//
// WHY THE BROWSER. Whether a loader moves, a skeleton shimmers or stands still,
// a frame lands when its end nears the viewport, and a finger's pull reloads
// the page are all computed style, layout and event timing. None of it is in
// the markup.
//
//   1. Spinner, dots and an indeterminate bar animate on the canonical rules; a
//      bar with a percent is a progressbar with that value and that fill.
//   2. A skeleton is aria-busy, its shapes are hidden from assistive tech, and
//      it shimmers, except under reduced motion.
//   3. Infinite scroll loads the next page as its end nears, with no click,
//      says how many came, keeps "Load more" visible, and says when it is done.
//   4. A keyboard press on "Load more" moves focus to the first new item.
//   5. With no script, "Load more" opens the next page.
//   6. On a phone, a pull from the top reloads the page; on a desktop the
//      pull never arms.

const section = (page) => page.locator("#loaders");
const specimen = (page, name) => page.locator(`[data-loader-specimen="${name}"]`);

test("spinner, dots and the bar move on the canonical rules, and a bar with a percent is its value", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.goto("/lab/loaders");

  const animation = (locator) => locator.evaluate((el) => getComputedStyle(el).animationName);
  expect(await animation(specimen(page, "spinner").locator(".studio-loader .spinner").first())).toBe("spin");
  expect(await animation(specimen(page, "dots").locator(".studio-loader .loading-dots span").first())).toBe("loading-dots-bounce");

  const bars = specimen(page, "bar").locator('.studio-loader[role="progressbar"]');
  await expect(bars).toHaveCount(2);
  const measured = bars.nth(0);
  await expect(measured).toHaveAttribute("aria-valuenow", "62");
  await expect(measured).toHaveAttribute("aria-label", "Uploading");
  // The fill is clipped to the percent: the 38% past it is cut away.
  const clip = await measured.locator(".progress-meter-fill").evaluate((el) => getComputedStyle(el).clipPath);
  expect(clip).toBe("inset(0px 38% 0px 0px)");

  const sweeping = bars.nth(1);
  expect(await sweeping.getAttribute("aria-valuenow")).toBeNull();
  expect(await animation(sweeping.locator(".progress-meter-fill"))).toBe("progress-indeterminate");

  // setPercent turns the sweep into a value.
  await sweeping.evaluate((el) => window.StudioLoader.setPercent(el, 30));
  await expect(sweeping).toHaveAttribute("aria-valuenow", "30");
  expect(await animation(sweeping.locator(".progress-meter-fill"))).toBe("none");
  expect(errors).toEqual([]);
});

test("a skeleton is busy, hides its shapes from assistive tech, and shimmers", async ({ page }) => {
  await page.goto("/lab/loaders");
  const skeleton = specimen(page, "skeleton").locator(".studio-skeleton").first();
  await expect(skeleton).toHaveAttribute("aria-busy", "true");
  const items = skeleton.locator(".studio-skeleton-item");
  expect(await items.count()).toBe(2);
  expect(await items.evaluateAll((els) => els.every((el) => el.getAttribute("aria-hidden") === "true"))).toBe(true);
  // What a screen reader gets is the one label, not the shapes.
  expect((await skeleton.locator(".sr-only").textContent()).trim()).toBe("Loading people");
  const bone = skeleton.locator(".studio-skeleton-bone").first();
  expect(await bone.evaluate((el) => getComputedStyle(el).animationName)).toBe("studio-skeleton-shimmer");
  expect(await bone.evaluate((el) => getComputedStyle(el).backgroundColor)).not.toBe("rgba(0, 0, 0, 0)");
});

test.describe("under reduced motion", () => {
  test("skeletons and plain loaders stand still", async ({ page }) => {
    await page.emulateMedia({ reducedMotion: "reduce" });
    await page.goto("/lab/loaders");
    const moving = await page.evaluate(() =>
      [...document.querySelectorAll("#loaders .studio-skeleton-bone, #loaders .studio-loader, #loaders .studio-loader *")]
        .filter((el) => getComputedStyle(el).animationName !== "none")
        .map((el) => el.className.baseVal ?? el.className));
    expect(moving).toEqual([]);
  });
});

test.describe("infinite scroll", () => {
  // Short enough that the list's end starts well past NEAR_PX (600px) below it.
  test.use({ viewport: { width: 1280, height: 240 } });

test("it loads the next page as its end nears, keeps Load more, and says what came", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.goto("/lab/loaders");
  const feed = specimen(page, "infinite");
  const items = feed.locator("[data-feed-item]");
  const status = feed.locator("[data-infinite-scroll-status]");
  await expect(items).toHaveCount(4);
  // The status line is a polite live region.
  await expect(status).toHaveAttribute("aria-live", "polite");

  // Far from the end, nothing loads.
  await page.waitForTimeout(400);
  await expect(items).toHaveCount(4);

  // Scrolling the list's end near the viewport loads page 2: no click.
  await feed.locator("[data-feed-item]").first().scrollIntoViewIfNeeded();
  await expect.poll(() => items.count()).toBeGreaterThanOrEqual(8);
  await expect(feed.getByText("Item 8")).toBeAttached();
  await expect(status).toHaveText(/more items loaded/);
  const done = feed.locator("[data-infinite-scroll-done]");

  // Page 3 is the last: the list says so, and no next frame waits.
  await feed.locator("[data-feed-item]").last().scrollIntoViewIfNeeded();
  await expect(items).toHaveCount(12);
  await expect(done).toHaveText("That is everything");
  await expect(status).toHaveText("4 more items loaded. That is everything");
  await expect(feed.locator("turbo-frame[data-infinite-scroll-next]:not([complete])")).toHaveCount(0);
  expect(new URL(page.url()).pathname).toBe("/lab/loaders");
  expect(errors).toEqual([]);
});

test("Load more stays visible while the next page waits", async ({ page }) => {
  await page.goto("/lab/loaders");
  const more = specimen(page, "infinite").locator("[data-infinite-scroll-more]");
  await expect(more).toHaveCount(1);
  await more.scrollIntoViewIfNeeded();
  await expect(more.or(specimen(page, "infinite").locator("[data-infinite-scroll-done]")).first()).toBeVisible();
});
});

test.describe("a keyboard press", () => {
  test.use({ viewport: { width: 1280, height: 240 } });

test("on Load more moves focus to the first new item", async ({ page }) => {
  await page.goto("/lab/loaders");
  const feed = specimen(page, "infinite");
  const more = feed.locator("[data-infinite-scroll-more]");
  // Focus without scrolling, so the press, not the observer, loads the page.
  await more.evaluate((el) => el.focus({ preventScroll: true }));
  await page.keyboard.press("Enter");
  await expect(page.locator(":focus")).toHaveText("Item 5");
});
});

test.describe("with no script", () => {
  test.use({ javaScriptEnabled: false });

  test("Load more opens the next page", async ({ page }) => {
    await page.goto("/lab/loaders");
    await specimen(page, "infinite").locator("[data-infinite-scroll-more]").click();
    await expect(page).toHaveURL(/\/lab\/loaders_feed\?page=2$/);
    await expect(page.locator("[data-feed-item]").first()).toHaveText("Item 5");
    await expect(page.locator("[data-infinite-scroll-more]")).toBeVisible();
  });
});

// A one-finger drag down from (x, fromY) to (x, toY), in steps, on `selector`.
async function pull(page, selector, fromY, toY) {
  await page.evaluate(({ selector, fromY, toY }) => {
    const target = document.querySelector(selector);
    const touch = (y) => new Touch({ identifier: 1, target, clientX: 180, clientY: y });
    const fire = (type, y) => target.dispatchEvent(new TouchEvent(type, {
      bubbles: true, cancelable: true,
      touches: type === "touchend" ? [] : [touch(y)],
      changedTouches: [touch(y)]
    }));
    fire("touchstart", fromY);
    for (let i = 1; i <= 8; i++) fire("touchmove", fromY + ((toY - fromY) * i) / 8);
    fire("touchend", toY);
  }, { selector, fromY, toY });
}

test.describe("pull to refresh on a phone", () => {
  test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });

  test("a short pull settles back; a long pull from the top reloads the page", async ({ page }) => {
    await blockOffsiteRequests(page);
    const errors = watchPageErrors(page);
    await page.goto("/lab/pull_to_refresh");
    const stamp = page.locator('[data-test="pull-stamp"]');
    const before = await stamp.textContent();
    // The controller is lazy: wait for it to arm.
    await expect.poll(() => page.evaluate(() => document.documentElement.style.overscrollBehaviorY)).toBe("contain");

    await pull(page, ".studio-pull-refresh", 120, 150);
    await expect(page.locator(".studio-pull-refresh")).toHaveAttribute("data-pull-state", "settling");
    await page.waitForTimeout(300);
    expect(await stamp.textContent()).toBe(before);

    await pull(page, ".studio-pull-refresh", 120, 400);
    await expect(stamp).not.toHaveText(before);
    expect(errors).toEqual([]);
  });
});

test("on a desktop the pull never arms", async ({ page }) => {
  await page.goto("/lab/pull_to_refresh");
  await page.waitForTimeout(500);
  expect(await page.evaluate(() => document.documentElement.style.overscrollBehaviorY)).toBe("");
  await expect(page.locator(".studio-pull-refresh-indicator")).toBeHidden();
});

test("the style guide carries the Loaders section, all eight, and its pill", async ({ page }) => {
  await page.goto("/lab/loaders");
  for (const name of ["spinner", "skeleton", "bar", "dots", "button", "overlay", "pull", "infinite"]) {
    await expect(specimen(page, name), name).toHaveCount(1);
  }
  await expect(section(page).locator("article")).toHaveCount(8);
  // Every usage snippet wraps inside its box, clear of its Copy button.
  const clipped = await section(page).locator("pre").evaluateAll((els) =>
    els.filter((el) => el.scrollWidth > el.clientWidth).map((el) => el.textContent.slice(0, 40)));
  expect(clipped).toEqual([]);

  await page.goto("/lab/style_nav");
  await expect(page.locator('a[href="#loaders"]').first()).toHaveText("Loaders");
  await expect(page.locator("#loaders article")).toHaveCount(8);
});
