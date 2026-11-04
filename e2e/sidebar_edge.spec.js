const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests } = require("./helpers");

// [e2e] The sidebar's blurred edge (engine.css, THE SIDEBAR'S EDGE). It is a pseudo-element
// with a backdrop filter, so no box and no byte says what it does: these compare the pixels
// beside the panel with the band on and off.
//
// CONTROLS, each red for its reason: no backdrop-filter (first two specs, the strip beside
// the panel reads the same with the band off); the band as wide as the page (first spec, the
// far strip differs); pointer-events: auto (click spec, the panel stays open); the media
// query dropped (phone spec, the band has content).

const BUSY = "/lab/sidebar_panels?sidebar=1&busy=1";
const panel = (page) => page.locator("#studio-link-sidebar");
const trigger = (page) => page.locator("[data-link-sidebar-trigger]").first();

const openLab = async (page) => {
  await blockOffsiteRequests(page);
  await page.goto(BUSY);
  await page.waitForFunction(() => window.Alpine);
};

const setBand = (page, on) =>
  page.evaluate((on) => {
    document.querySelector("style[data-band-off]")?.remove();
    if (on) return;
    const style = document.createElement("style");
    style.dataset.bandOff = "";
    style.textContent = "[data-sidebar-edge]::before { display: none !important; }";
    document.head.appendChild(style);
  }, on);

// The same strip of the page with the band on, then off.
const stripsDiffer = async (page, clip) => {
  await setBand(page, true);
  const on = await page.screenshot({ clip });
  await setBand(page, false);
  const off = await page.screenshot({ clip });
  await setBand(page, true);
  return !on.equals(off);
};

test("the band blurs the page beside the panel and leaves the page beyond it sharp, in both themes", async ({ page }) => {
  await openLab(page);
  await trigger(page).click();
  await expect(panel(page)).toBeVisible();
  await page.waitForTimeout(350); // the 300ms slide
  const { x: left } = await panel(page).boundingBox();
  const beside = { x: left - 24, y: 200, width: 22, height: 300 };
  const beyond = { x: left - 120, y: 200, width: 60, height: 300 };

  for (const theme of ["dark", "light"]) {
    if (theme === "light") await page.evaluate(() => document.documentElement.classList.remove("dark"));
    expect(await stripsDiffer(page, beside), `${theme}: blurred beside the panel`).toBe(true);
    expect(await stripsDiffer(page, beyond), `${theme}: sharp beyond the band`).toBe(false);
  }
});

test("the band moves with the panel through the slide", async ({ page }) => {
  await openLab(page);
  await trigger(page).click();
  // Hold the slide halfway, where a filter stranded by the transform would show.
  const left = await panel(page).evaluate(async (node) => {
    while (!node.getAnimations().length) await new Promise(requestAnimationFrame);
    const slide = node.getAnimations()[0];
    slide.pause();
    slide.currentTime = 150;
    await new Promise(requestAnimationFrame);
    return node.getBoundingClientRect().left;
  });
  expect(left, "the panel is part way in").toBeGreaterThan(960);
  expect(left).toBeLessThan(1270);

  const beside = { x: left - 24, y: 200, width: 22, height: 300 };
  expect(await stripsDiffer(page, beside), "the blur is beside the panel, here").toBe(true);
  const rest = { x: 960 - 24, y: 200, width: 22, height: 300 };
  if (left - 40 > rest.x + rest.width) {
    expect(await stripsDiffer(page, rest), "and not where the panel will end up").toBe(false);
  }
});

test("the band takes no clicks: a click in it reaches the page and closes the panel", async ({ page }) => {
  await openLab(page);
  await trigger(page).click();
  await expect(panel(page)).toBeVisible();
  await page.waitForTimeout(350);
  const { x: left } = await panel(page).boundingBox();

  const hit = await page.evaluate(([x, y]) => document.elementFromPoint(x, y).closest("[data-test]")?.dataset.test, [left - 10, 300]);
  expect(hit, "a card lies under the band").toBe("lab-busy-card");

  await page.mouse.click(left - 10, 300);

  await expect(panel(page)).toBeHidden();
  await expect(page).toHaveURL(/#busy-\d+$/);
});

test.describe("on a phone", () => {
  test.use({ viewport: { width: 390, height: 844 } });

  test("there is no band and no sideways scroll", async ({ page }) => {
    await openLab(page);
    await trigger(page).click();
    const phone = page.locator("#studio-link-sidebar-mobile");
    await expect(phone).toBeVisible();
    await page.waitForTimeout(350);

    const measured = await phone.evaluate((node) => ({
      band: getComputedStyle(node, "::before").content,
      filter: getComputedStyle(node, "::before").backdropFilter,
      scrolls: document.documentElement.scrollWidth > document.documentElement.clientWidth,
      width: node.getBoundingClientRect().width
    }));
    expect(measured.width, "it fills the phone").toBe(390);
    expect(measured.band).toBe("none");
    expect(measured.filter).toBe("none");
    expect(measured.scrolls).toBe(false);
  });
});
