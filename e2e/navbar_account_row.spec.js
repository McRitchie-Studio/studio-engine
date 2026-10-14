const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// THE ACCOUNT ROW, FROM 768px (engine.css, THE ACCOUNT ROW). Every app whose
// navbar renders components/_user_nav gets it; Turf Monster forks the partial.
//
// A one-row nav (no level, no wallet: every app but Turf Monster) carries a 40px
// avatar that shrinks to 32px on the scroll ramp, the first name on the rule of
// 3 against it (font size = avatar / 3 / Montserrat's 0.7 cap height), centred
// on it, and one gap, measured ink to ink, between moon, gear, name and avatar.
// The response bytes cannot show any of it: it is computed style and paint.

const DESKTOP = { width: 1280, height: 800 };
const ONE_ROW = "/lab/bar_stack?one_row=1&sidebar=1";

const sizes = (page) => page.evaluate(() => ({
  avatar: document.querySelector("header [data-nav-account] [aria-hidden] > *").getBoundingClientRect().height,
  name: parseFloat(getComputedStyle(document.querySelector("header [data-nav-name]")).fontSize),
}));

test("the one-row avatar shrinks on scroll and the name follows it", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.setViewportSize(DESKTOP);
  await page.goto(ONE_ROW);

  const rest = await sizes(page);
  expect(rest.avatar).toBe(40);
  expect(rest.name).toBeCloseTo(40 / 3 / 0.7, 1);

  // The theme toggle, the name and the avatar share one centre line.
  const centres = await page.evaluate(() => {
    const mid = (s) => { const r = document.querySelector(s).getBoundingClientRect(); return r.top + r.height / 2; };
    return {
      avatar: mid("header [data-nav-account] [aria-hidden] > *"),
      name: mid("header [data-nav-name]"),
      toggle: mid("header [data-nav-theme-toggle='desktop']"),
    };
  });
  expect(Math.abs(centres.toggle - centres.avatar), JSON.stringify(centres)).toBeLessThanOrEqual(1);
  expect(Math.abs(centres.name - centres.avatar), JSON.stringify(centres)).toBeLessThanOrEqual(1);

  await page.evaluate(() => window.scrollTo(0, 1200));
  await expect(page.locator("header.nav-shell")).toHaveClass(/is-scrolled/);
  await expect.poll(async () => (await sizes(page)).avatar).toBe(32);
  expect((await sizes(page)).name).toBeCloseTo(32 / 3 / 0.7, 1);
  expect(errors).toEqual([]);
});

// The two-row nav (Turf Monster's shape, a level and a wallet) keeps the
// engine's 2rem avatar its second row is laid out against.
test("a two-row nav keeps the 2rem avatar", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await page.goto("/lab/bar_stack?signed_in=1&sidebar=1");

  expect((await sizes(page)).avatar).toBe(32);
});

test("the theme toggle leads the gear, and both sit a size down", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await page.goto(ONE_ROW);

  const rail = await page.evaluate(() => {
    const box = (s) => document.querySelector(s).getBoundingClientRect();
    const gear = box("header [data-nav-tools] [data-link-sidebar-trigger]");
    return {
      moon: box("header [data-nav-tools] [data-nav-theme-toggle='desktop']"),
      gear: { x: gear.x, width: gear.width, height: gear.height },
      glyph: box("header [data-nav-tools] [data-link-sidebar-trigger] svg").width,
    };
  });
  expect(rail.moon.x).toBeLessThan(rail.gear.x);
  expect(rail.moon.width).toBeCloseTo(14, 0);
  expect(rail.gear.width).toBe(24);
  expect(rail.gear.height).toBe(24);
  expect(rail.glyph).toBe(16);
});

test("moon, gear, name and avatar are one gap apart, at rest and scrolled", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await page.goto(ONE_ROW);
  await page.evaluate(() => document.fonts.ready);

  const gaps = () => page.evaluate(() => {
    const ink = (svg) => {
      let left = Infinity, right = -Infinity;
      svg.querySelectorAll("path, circle").forEach((el) => {
        const box = el.getBBox(), m = el.getScreenCTM();
        [box.x, box.x + box.width].forEach((x) => {
          const sx = m.a * x + m.c * box.y + m.e;
          left = Math.min(left, sx);
          right = Math.max(right, sx);
        });
      });
      return [left, right];
    };
    const shown = (list) => [...list].find((el) => el.getBoundingClientRect().width > 0);
    const moon = ink(shown(document.querySelectorAll("header [data-nav-theme-toggle='desktop'] .nav-toggle-icon svg")));
    const gear = ink(shown(document.querySelectorAll("header [data-nav-tools] [data-link-sidebar-trigger] svg")));
    const range = document.createRange();
    range.selectNodeContents(document.querySelector("header [data-nav-name]"));
    const name = range.getBoundingClientRect();
    const avatar = document.querySelector("header [data-nav-account] [aria-hidden] > *").getBoundingClientRect();
    return [gear[0] - moon[1], name.left - gear[1], avatar.left - name.right];
  });

  for (const y of [0, 1200]) {
    await page.evaluate((top) => window.scrollTo(0, top), y);
    if (y) await expect(page.locator("header.nav-shell")).toHaveClass(/is-scrolled/);
    const measured = await gaps();
    measured.forEach((gap) => expect(Math.abs(gap - 12), JSON.stringify(measured)).toBeLessThanOrEqual(1));
  }
});

// The name and avatar open the link sidebar, as the gear does: a button, so a
// screen reader hears what it does. The click flips the one open flag the panel
// and the gear both read ($store.sidebars.linkTreeOpen). This lab mounts the
// panel outside any Alpine scope, so it never paints here for the gear either;
// e2e/link_sidebar.spec.js owns the panel opening on that flag.
test("the name and avatar open the link sidebar", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await page.goto(ONE_ROW);

  const account = page.locator("header button[data-nav-account]");
  const gear = page.locator("header [data-nav-tools] [data-link-sidebar-trigger]");
  const open = () => page.evaluate(() => window.Alpine.store("sidebars").linkTreeOpen);
  await expect(account).toHaveAccessibleName("Alexandra");
  await expect(account).toHaveAttribute("aria-expanded", "false");

  await account.click();
  await expect.poll(open).toBe(true);
  await expect(account).toHaveAttribute("aria-expanded", "true");
  await expect(gear).toHaveAttribute("aria-expanded", "true");

  await account.click();
  await expect.poll(open).toBe(false);
});
