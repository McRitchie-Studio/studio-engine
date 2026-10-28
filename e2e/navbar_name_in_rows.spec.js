const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// THE NAME IN ROWS (Studio.navbar_name_in_rows; the lab turns it on for one
// request with ?name_in_rows=1). The name ends row 1, after the icons, directly
// over the second row (the level bar), and the avatar stands alone. Turf
// Monster's stacked name and level, as before it adopted the engine user nav.
//
// What only a browser can show: the boxes stack; pointing at the name lights the
// avatar (engine.css, THE ACCOUNT GROUP); and on the scroll timeline
// studio/nav_collapse measures the NAME's box, never the avatar's, so the icon
// column slides by exactly what the avatar gives up and the name shrinks by the
// avatar's ratio while keeping its gap to it.

const DESKTOP = { width: 1280, height: 800 };
// Two rows (a level bar under the icons): the stacking and the hover.
const TWO_ROWS = "/lab/bar_stack?signed_in=1&sidebar=1&name_in_rows=1";
// One row on the scroll timeline: the engine shrinks the avatar only for a
// one-row nav, so this is where the timeline's measurements move.
const TIMELINE = "/lab/bar_stack?one_row=1&sidebar=1&timeline=1&name_in_rows=1";

const boxes = (page) => page.evaluate(async () => {
  for (let i = 0; i < 2; i++) await new Promise((r) => requestAnimationFrame(r));
  const h = document.querySelector("header.nav-shell");
  const box = (el) => { if (!el) return null; const r = el.getBoundingClientRect(); return { left: r.left, right: r.right, top: r.top, bottom: r.bottom, height: r.height }; };
  return {
    name: box(h.querySelector("[data-nav-tools] [data-nav-name-trigger]")),
    row2: box(h.querySelector("[data-nav-tools] > div:nth-of-type(2)")),
    avatar: box(h.querySelector("[data-nav-account] > [aria-hidden]")),
    accountHasName: !!h.querySelector("[data-nav-account] [data-nav-name]"),
    toolsShift: parseFloat(h.style.getPropertyValue("--nav-tools-shift")),
    avatarShrink: parseFloat(h.style.getPropertyValue("--nav-avatar-shrink")),
  };
});

test("two rows: the name stacks over the level bar, beside the lone avatar, and pointing at it lights the avatar", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.setViewportSize(DESKTOP);
  await page.goto(TWO_ROWS);
  await page.evaluate(() => document.fonts.ready);

  const at = await boxes(page);
  const msg = JSON.stringify(at);
  expect(at.accountHasName, `the avatar stands alone: ${msg}`).toBe(false);
  expect(at.row2, `the level bar renders: ${msg}`).not.toBeNull();
  expect(at.name.bottom, `the name sits above the second row: ${msg}`).toBeLessThanOrEqual(at.row2.top + 0.5);
  expect(at.name.right, `the name ends over the second row: ${msg}`).toBeLessThanOrEqual(at.row2.right + 0.5);
  expect(at.name.left, `the name starts over the second row: ${msg}`).toBeGreaterThanOrEqual(at.row2.left - 0.5);
  expect(at.name.right, `the name is left of the avatar: ${msg}`).toBeLessThanOrEqual(at.avatar.left + 0.5);

  const glow = () => page.evaluate(() =>
    getComputedStyle(document.querySelector("header [data-nav-account] > [aria-hidden] > *")).boxShadow);
  expect(await glow(), "control: the avatar is unlit at rest").toBe("none");
  await page.locator("header [data-nav-tools] [data-nav-name-trigger]").hover();
  await expect.poll(glow).not.toBe("none");

  expect(errors).toEqual([]);
});

test("on the timeline nav_collapse measures the name's box, not the avatar's", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.setViewportSize(DESKTOP);
  await page.goto(TIMELINE);
  await page.evaluate(() => document.fonts.ready);
  await expect(page.locator("header.nav-shell")).toHaveAttribute("data-nav-timeline-on", "");

  const top = await boxes(page);
  // The name is no longer in the account, so the icon column slides by the
  // avatar's shrink alone. Measuring the avatar as the name (its box is now the
  // account's first child) adds its width x (1 - scale) on top.
  expect(top.avatarShrink, JSON.stringify(top)).toBeGreaterThan(0);
  expect(Math.abs(top.toolsShift - top.avatarShrink), `--nav-tools-shift is the avatar's shrink: ${JSON.stringify(top)}`).toBeLessThanOrEqual(0.5);

  await page.evaluate(() => window.scrollTo(0, 1200));
  const compact = await boxes(page);
  const both = JSON.stringify({ top, compact });
  expect(compact.avatar.height, `the avatar shrinks: ${both}`).toBeLessThan(top.avatar.height - 0.5);
  expect(compact.name.height, `the name shrinks with it: ${both}`).toBeLessThan(top.name.height - 0.5);
  const gap = (at) => at.avatar.left - at.name.right;
  expect(Math.abs(gap(compact) - gap(top)), `the name keeps its gap to the avatar: ${both}`).toBeLessThanOrEqual(1);

  expect(errors).toEqual([]);
});
