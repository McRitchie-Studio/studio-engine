const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The self-styled page header (docs/PAGE_HEADER.md, "In a plain-CSS app") in a
// PLAIN-CSS host: layouts/plain_css_lab has no engine head, no Tailwind, no Stimulus and
// no import map, only a host stylesheet in rantly's shape (its own tokens mapped onto the
// engine's, light and dark by prefers-color-scheme, and a sticky masthead). The row's CSS
// and script come from studio/page_header/_assets alone.
//
// Every claim is a computed style, a box, a focus or an attribute the script writes, so
// no markup test can answer it.
//
// THE PHONE IS EMULATED, NOT RESIZED. Headless Chromium will not size a window below
// about 500px, so a setViewportSize(390) can leave the layout at another width. Each
// phone check opens its own mobile context and asserts the real window.innerWidth first.
//
// CONTROLS, each run against this file with the lab server restarted:
//   - the partial's studio_page_header_assets call removed: 6 red, all of them (an
//     unstyled row, and no script to mark the sentinel live).
//   - publishNavBottom made a no-op: 4 red, the stuck row slides under the masthead on
//     the desktop and the phone, in both schemes.
//   - wireMenu not called: 1 red, aria-expanded never set.
//   - the "-mx-4" rule removed: 2 red, the row loses its bleed (desktop, both schemes).

const DESKTOP = { width: 1280, height: 800 };
const PHONE = { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true };
const LAB = "/lab/plain_css/page_header";
const LEGAL = "/lab/plain_css/legal";

const row = (page) => page.locator(".page-header");
const box = (locator) => locator.evaluate((el) => {
  const r = el.getBoundingClientRect();
  return { top: r.top, bottom: r.bottom, left: r.left, right: r.right, width: r.width, height: r.height };
});
const style = (locator, prop) => locator.evaluate((el, p) => getComputedStyle(el)[p], prop);

// WCAG contrast of two computed rgb() colours.
function contrast(a, b) {
  const lum = (rgb) => {
    const [r, g, bl] = rgb.match(/[\d.]+/g).slice(0, 3).map(Number).map((v) => {
      const c = v / 255;
      return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    });
    return 0.2126 * r + 0.7152 * g + 0.0722 * bl;
  };
  const [hi, lo] = [lum(a), lum(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

async function openLab(page, path = LAB) {
  await blockOffsiteRequests(page);
  await page.goto(path);
  await expect(page.locator(".page-header-sentinel")).toHaveAttribute("data-page-header-live", "");
}

// Scroll until the row is pinned, then let the script's frame run.
async function scrollPast(page) {
  await page.evaluate(() => window.scrollTo(0, 700));
  await expect(row(page)).toHaveAttribute("data-stuck", "");
}

for (const scheme of ["light", "dark"]) {
  test(`desktop, ${scheme}: the row is styled from the host's tokens and sticks under its masthead`, async ({ page }) => {
    const errors = watchPageErrors(page);
    await page.emulateMedia({ colorScheme: scheme });
    await page.setViewportSize(DESKTOP);
    await openLab(page);

    const tokens = await page.evaluate(() => {
      const probe = (value, prop) => {
        const el = document.createElement("span");
        el.style[prop] = value;
        document.body.append(el);
        const out = getComputedStyle(el)[prop];
        el.remove();
        return out;
      };
      return { ink: probe("var(--ink)", "color"), surface: probe("var(--surface)", "backgroundColor"),
               accent: probe("var(--accent)", "backgroundColor"), accentInk: probe("var(--accent-ink)", "color") };
    });

    // The title: the type scale's h2 from 40rem, at the display weight, in the host's ink.
    const title = row(page).locator("h1.page-header-title");
    expect(await style(title, "fontSize")).toBe("30px");
    expect(await style(title, "fontWeight")).toBe("800");
    expect(await style(title, "color")).toBe(tokens.ink);

    // At rest the row has no bar.
    expect(await style(row(page), "backgroundColor")).toBe("rgba(0, 0, 0, 0)");

    // The controls: one height, in the fixed order, the action in the host's accent with
    // its own ink, which clears 4.5:1.
    const tab = row(page).locator(".page-header-tab").first();
    const menu = row(page).locator(".page-header-menu-button");
    const action = row(page).locator(".page-header-action");
    const boxes = await Promise.all([tab, menu, action].map(box));
    const heights = boxes.map((b) => Math.round(b.height));
    expect(new Set(heights).size, `heights ${heights.join(", ")}`).toBe(1);
    expect(heights[0]).toBeGreaterThan(24);
    for (let i = 1; i < boxes.length; i++) {
      expect(boxes[i].left).toBeGreaterThanOrEqual(boxes[i - 1].right);
      expect(Math.abs(boxes[i].top - boxes[0].top)).toBeLessThan(1);
    }
    expect(await style(action, "backgroundColor")).toBe(tokens.accent);
    expect(await style(action, "color")).toBe(tokens.accentInk);
    expect(contrast(tokens.accent, tokens.accentInk)).toBeGreaterThanOrEqual(4.5);
    expect(await style(action, "textDecorationLine")).toBe("none");
    expect(await style(menu, "borderTopWidth")).toBe("1px");

    // The trail is above the title, and the meta beside it.
    await expect(row(page).locator(".page-header-crumbs")).toBeVisible();
    await expect(row(page).locator(".page-header-parent")).toBeHidden();
    await expect(row(page).locator(".page-header-meta")).toBeVisible();
    expect(await style(row(page).locator(".page-header-meta"), "textTransform")).toBe("uppercase");

    // The default bleed fits the host's 1rem gutter.
    const main = await box(page.locator("[data-lab-main]"));
    const atRest = await box(row(page));
    expect(Math.abs(atRest.left - main.left), "the row starts at the gutter's outer edge").toBeLessThan(1);

    // Stuck: the bar in the host's surface, right under the masthead, and the same box.
    await scrollPast(page);
    const masthead = await box(page.locator("[data-lab-masthead]"));
    const stuck = await box(row(page));
    expect(Math.abs(stuck.top - masthead.bottom), `row top ${stuck.top}, masthead bottom ${masthead.bottom}`).toBeLessThan(1);
    expect(Math.round(stuck.height)).toBe(Math.round(atRest.height));
    // The bar fades in over 150ms.
    await expect.poll(() => style(row(page), "backgroundColor")).toBe(tokens.surface);

    expect(errors).toEqual([]);
  });
}

test("desktop: the Links menu opens under its button, keeps aria-expanded, and closes on Escape", async ({ page }) => {
  const errors = watchPageErrors(page);
  await page.setViewportSize(DESKTOP);
  await openLab(page);

  const button = row(page).locator(".page-header-menu-button");
  const list = row(page).locator(".page-header-menu-list");
  await expect(button).toHaveAttribute("aria-expanded", "false");

  await button.click();
  await expect(list).toBeVisible();
  await expect(button).toHaveAttribute("aria-expanded", "true");
  const [b, l] = [await box(button), await box(list)];
  expect(l.top).toBeGreaterThanOrEqual(b.bottom);
  expect(Math.abs(l.right - b.right)).toBeLessThan(2);
  expect(await list.locator("a").allTextContents()).toEqual(["Privacy Policy", "Terms of Service"]);
  expect(await style(list, "backgroundColor")).not.toBe("rgba(0, 0, 0, 0)");

  await page.keyboard.press("Escape");
  await expect(list).toBeHidden();
  await expect(button).toHaveAttribute("aria-expanded", "false");
  await expect(button).toBeFocused();

  // ArrowDown from the button walks into the list.
  await button.focus();
  await page.keyboard.press("ArrowDown");
  await expect(list.locator("a").first()).toBeFocused();
  expect(errors).toEqual([]);
});

for (const scheme of ["light", "dark"]) {
  test(`phone 390, ${scheme}: the row fits, the trail gives way to the parent, and it still sticks`, async ({ browser }) => {
    const context = await browser.newContext({ ...PHONE, colorScheme: scheme });
    const page = await context.newPage();
    const errors = watchPageErrors(page);
    await openLab(page);

    expect(await page.evaluate(() => window.innerWidth)).toBe(390);

    const geometry = await page.evaluate(() => {
      const de = document.documentElement;
      const row = document.querySelector(".page-header");
      const tabs = row.querySelector(".page-header-tabs");
      const outside = [...row.querySelectorAll("*")]
        .filter((el) => !tabs.contains(el) && !el.closest("[popover]"))
        .filter((el) => { const r = el.getBoundingClientRect(); return r.width > 0 && (r.left < -0.5 || r.right > de.clientWidth + 0.5); })
        .map((el) => el.className);
      const t = tabs.getBoundingClientRect();
      return { scrollWidth: de.scrollWidth, clientWidth: de.clientWidth, outside, tabsLeft: t.left, tabsRight: t.right };
    });
    expect(geometry.scrollWidth, "the page does not scroll sideways").toBeLessThanOrEqual(geometry.clientWidth);
    expect(geometry.outside, "nothing in the row draws past the screen").toEqual([]);
    expect(geometry.tabsRight).toBeLessThanOrEqual(geometry.clientWidth + 0.5);

    await expect(row(page).locator(".page-header-crumbs")).toBeHidden();
    await expect(row(page).locator(".page-header-parent")).toBeVisible();
    await expect(row(page).locator(".page-header-meta")).toBeHidden();
    expect(await style(row(page).locator("h1"), "fontSize")).toBe("24px");

    await scrollPast(page);
    const masthead = await box(page.locator("[data-lab-masthead]"));
    expect(Math.abs((await box(row(page))).top - masthead.bottom)).toBeLessThan(1);
    expect(errors).toEqual([]);
    await context.close();
  });
}

test("the legal page: one h1 in the header, a readable column, and it fits a phone", async ({ page, browser }) => {
  const errors = watchPageErrors(page);
  await page.setViewportSize(DESKTOP);
  await openLab(page, LEGAL);

  expect(await page.locator("h1").allTextContents()).toEqual(["Privacy Policy"]);
  const column = await box(page.locator(".legal-page"));
  expect(column.width).toBeLessThanOrEqual(46 * 16 + 0.5);
  expect(await page.locator(".legal-page-updated").textContent()).toContain("Last updated November 8, 2026");
  const body = page.locator(".legal-page-body");
  expect(await style(body, "fontSize")).toBe("16px");
  expect(await style(body.locator("h2").first(), "fontSize")).toBe("20px");
  expect(await style(body.locator("a").first(), "textDecorationLine")).toBe("underline");
  expect(errors).toEqual([]);

  const context = await browser.newContext(PHONE);
  const phone = await context.newPage();
  await openLab(phone, `${LEGAL}?page=terms`);
  expect(await phone.evaluate(() => window.innerWidth)).toBe(390);
  const width = await phone.evaluate(() => ({ scroll: document.documentElement.scrollWidth, client: document.documentElement.clientWidth }));
  expect(width.scroll).toBeLessThanOrEqual(width.client);
  expect(await phone.locator("h1").allTextContents()).toEqual(["Terms of Service"]);
  await context.close();
});
