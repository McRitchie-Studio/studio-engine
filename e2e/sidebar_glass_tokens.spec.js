const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests, slidIn } = require("./helpers");

// [e2e] The glass sidebar paints the app's colours from four root tokens (engine.css,
// THE GLASS SIDEBAR), and with no tokens set it paints the hub's violet exactly as before.
// Computed styles on the live panel, in both themes. The lit tile classes take the buttons'
// light only under glass.
//
// CONTROLS: the hub-look spec passes on the commit before the tokens (the values are the
// ones the shell hard-coded, so the look did not move), and the app-token spec fails there
// (an app's :root tokens never reached the shell). The lit-tile spec fails with the
// .lit-tile rules removed.

const panel = (page) => page.locator("#studio-link-sidebar");
const shell = (page) => panel(page).locator("[data-sidebar-glass-shell]");

const openGlass = async (page) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/sidebar_panels?glass=1&signed_in=1&admin=1");
  await page.waitForFunction(() => window.Alpine);
  await page.locator("[data-link-sidebar-trigger]:visible").first().click();
  await expect(panel(page)).toBeVisible();
  await slidIn(panel(page));
};

const setDark = (page, on) => page.evaluate((dark) => document.documentElement.classList.toggle("dark", dark), on);

// What the panel paints: ink, soft ink (a group header), the thin fill under the blur, the
// hairline, the shadow, and a hovered row's fill.
const paint = (page) => shell(page).evaluate((el) => {
  const css = getComputedStyle(el);
  const header = el.querySelector("[data-sidebar-group-header]") || el.querySelector("[data-sidebar-row-desc]");
  // The hover fill, resolved: a probe inside the shell paints var(--glass-hover).
  const probe = document.createElement("div");
  probe.style.backgroundColor = "var(--glass-hover)";
  el.append(probe);
  const hover = getComputedStyle(probe).backgroundColor;
  probe.remove();
  return {
    ink: css.color,
    softInk: getComputedStyle(header).color,
    fill: css.backgroundColor,
    line: css.borderLeftColor,
    shadow: css.boxShadow,
    hover,
  };
});

test("with no tokens set, the panel paints the hub's violet in both themes", async ({ page }) => {
  const errors = watchPageErrors(page);
  await openGlass(page);

  await setDark(page, false);
  await expect.poll(() => paint(page)).toEqual({
    ink: "rgb(29, 24, 50)",
    softInk: "rgb(71, 66, 96)",
    fill: "rgba(255, 255, 255, 0.72)",
    line: "rgba(29, 24, 50, 0.14)",
    shadow: "rgba(29, 24, 50, 0.24) 0px 24px 60px 0px",
    hover: "rgba(29, 24, 50, 0.08)",
  });

  await setDark(page, true);
  await expect.poll(() => paint(page)).toEqual({
    ink: "rgb(241, 239, 250)",
    softInk: "rgb(222, 218, 237)",
    fill: "rgba(36, 30, 62, 0.72)",
    line: "rgba(255, 255, 255, 0.14)",
    shadow: "rgba(0, 0, 0, 0.5) 0px 24px 60px 0px",
    hover: "rgba(255, 255, 255, 0.1)",
  });
  expect(errors).toEqual([]);
});

// An app's stylesheet: unlayered, after the engine, on :root and .dark, as NEW_APP_SETUP.md
// shows. These are Commercial Welding's navy values.
test("an app's root tokens reach the panel in both themes", async ({ page }) => {
  await openGlass(page);
  await page.addStyleTag({ content: `
    :root { --glass-sidebar-fill: 249 251 253; --glass-sidebar-ink: #0B1824;
            --glass-sidebar-soft-ink: #3B4F63; --glass-sidebar-tint: 11 24 36; }
    .dark { --glass-sidebar-fill: 18 41 63; --glass-sidebar-ink: #F1F5F9; --glass-sidebar-soft-ink: #D5E2EE; }
  ` });

  await setDark(page, false);
  await expect.poll(() => paint(page)).toMatchObject({
    ink: "rgb(11, 24, 36)",
    softInk: "rgb(59, 79, 99)",
    fill: "rgba(255, 255, 255, 0.72)",
    line: "rgba(11, 24, 36, 0.14)",
    shadow: "rgba(11, 24, 36, 0.24) 0px 24px 60px 0px",
    hover: "rgba(11, 24, 36, 0.08)",
  });

  await setDark(page, true);
  await expect.poll(() => paint(page)).toMatchObject({
    ink: "rgb(241, 245, 249)",
    softInk: "rgb(213, 226, 238)",
    fill: "rgba(18, 41, 63, 0.72)",
  });
});

test("a lit tile takes the buttons' light under glass, and nothing without it", async ({ page }) => {
  await blockOffsiteRequests(page);
  const shadows = async () => page.evaluate(() => {
    const make = (cls) => {
      const el = document.createElement("a");
      el.className = cls;
      el.href = "#";
      el.textContent = "Tile";
      el.style.background = "#1f5fa8";
      document.body.append(el);
      const shadow = getComputedStyle(el).boxShadow;
      el.remove();
      return shadow;
    };
    return { tile: make("lit-tile"), soft: make("lit-tile-soft") };
  });

  await page.goto("/lab/sidebar_panels?surface=glass");
  await setDark(page, false);
  const lit = await shadows();
  expect(lit.tile).toContain("rgba(255, 255, 255, 0.35) 0px 1px 0px 0px inset");
  expect(lit.tile).toContain("rgba(0, 0, 0, 0.2) 0px -2px 0px 0px inset");
  expect(lit.tile).toContain("rgba(0, 0, 0, 0.4) 0px 1px 2px 0px");
  expect(lit.soft).toContain("rgba(255, 255, 255, 0.8) 0px 1px 0px 0px inset");

  await page.goto("/lab/sidebar_panels");
  expect(await shadows()).toEqual({ tile: "none", soft: "none" });
});
