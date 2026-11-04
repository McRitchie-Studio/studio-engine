const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The link sidebar's title, its groups and its rows (components/_link_sidebar,
// studio/link_sidebar). What the response bytes cannot show: the word the browser
// writes by its own clock and zone, whether a divider is drawn, and how a long name
// sits beside the close button.
//
// The server's default word is "Good morning", so a spec that wants the browser's
// word to be proven reads a word other than that one.
//
// CONTROLS, each run with the server restarted, each red for the reason named:
//   - paintGreetings writes nothing: the Paris and Tokyo specs read "Good morning"
//     where they expect another word; the boundary and restore specs fail on their
//     word as well.
//   - greetingFor reads getUTCHours: the Denver and Paris specs read the UTC word.
//   - drop the interval: the boundary spec stays on "Good morning" after the minute.
//   - drop the turbo:before-render paint: the restore spec reads "Good morning" on
//     the hidden panel after Back.
//   - drop `border-t` from the group: the divider spec reads a border width of 0px.
//   - drop `truncate` from the title: the long-name specs read no overflow, and the
//     close button leaves the panel.

const INSTANT = "2026-11-04T15:00:00Z";

const panel = (page) => page.locator("#studio-link-sidebar");
const phonePanel = (page) => page.locator("#studio-link-sidebar-mobile");
const titleOf = (scope) => scope.locator("[data-link-sidebar-title]");
const trigger = (page) => page.locator("[data-link-sidebar-trigger]").first();

const openLab = async (page, query = "sidebar=1") => {
  await blockOffsiteRequests(page);
  await page.goto(`/lab/sidebar_panels?${query}`);
  await page.waitForFunction(() => window.Alpine);
};

// One instant, three zones, three words: only the browser's own local time can
// answer differently for the same moment.
for (const [zone, localHour, word] of [
  ["America/Denver", 8, "Good morning"],
  ["Europe/Paris", 16, "Good afternoon"],
  ["Asia/Tokyo", 0, "Good evening"]
]) {
  test.describe(`at ${INSTANT} in ${zone}`, () => {
    test.use({ timezoneId: zone });

    test(`a signed-out panel says ${word}`, async ({ page }) => {
      const errors = watchPageErrors(page);
      await page.clock.install({ time: INSTANT });
      await openLab(page);
      expect(await page.evaluate(() => new Date().getHours()), "the browser's local hour").toBe(localHour);

      await trigger(page).click();
      await expect(panel(page)).toBeVisible();
      await expect(titleOf(panel(page))).toHaveText(word);
      expect(errors).toEqual([]);
    });
  });
}

test.describe("on a phone", () => {
  test.use({ timezoneId: "Asia/Tokyo", viewport: { width: 390, height: 844 } });

  test("the phone panel says the browser's word too", async ({ page }) => {
    await page.clock.install({ time: INSTANT });
    await openLab(page);

    await trigger(page).click();
    await expect(phonePanel(page)).toBeVisible();
    await expect(panel(page)).toBeHidden();
    await expect(titleOf(phonePanel(page))).toHaveText("Good evening");
  });
});

test.describe("across a boundary", () => {
  test.use({ timezoneId: "UTC" });

  test("a panel left open past noon changes its word within a minute", async ({ page }) => {
    await page.clock.install({ time: "2026-11-04T11:59:30Z" });
    await openLab(page);
    await trigger(page).click();
    await expect(titleOf(panel(page))).toHaveText("Good morning");

    await page.clock.runFor(61000);

    await expect(panel(page)).toBeVisible();
    await expect(titleOf(panel(page))).toHaveText("Good afternoon");
  });

  test("a Turbo visit paints the word, and a snapshot restored later paints the later word", async ({ page }) => {
    const errors = watchPageErrors(page);
    await page.clock.install({ time: "2026-11-04T18:00:00Z" });
    await blockOffsiteRequests(page);

    await page.goto("/lab/toast_flash");
    await expect(page.locator("[data-test='toast-flash-page']")).toBeVisible();
    await page.evaluate(() => { window.__sameDocument = true; });
    await page.evaluate(() => window.Turbo.visit("/lab/sidebar_panels_turbo?sidebar=1"));
    await expect(page.locator("[data-test='lab-body']")).toBeVisible();
    expect(await page.evaluate(() => window.__sameDocument), "a Turbo visit").toBe(true);
    await expect(panel(page)).toBeHidden();
    await expect(titleOf(panel(page)), "evening, set with no click").toHaveText("Good evening");

    await page.locator("[data-survey-lab-away]").click();
    await expect(page).toHaveURL(/site_footer\/terms/);
    expect(await page.evaluate(() => window.__sameDocument), "still a Turbo visit").toBe(true);

    // Eighteen hours on, and the snapshot holds the evening's word.
    await page.clock.fastForward("18:00:00");
    await page.goBack();
    await expect(page.locator("[data-test='lab-body']")).toBeVisible();
    expect(await page.evaluate(() => window.__sameDocument), "a snapshot restore").toBe(true);

    await expect(panel(page)).toBeHidden();
    await expect(titleOf(panel(page)), "the restore paints, before any click").toHaveText("Good afternoon");
    expect(errors).toEqual([]);
  });
});

test("a signed-in panel says the name and keeps the links menu's name", async ({ page }) => {
  await openLab(page, "sidebar=1&signed_in=1");
  await trigger(page).click();

  await expect(page.getByRole("navigation", { name: "Links menu" })).toBeVisible();
  await expect(titleOf(panel(page))).toHaveText("Pat");
  await expect(panel(page).locator("[data-link-sidebar-greeting]")).toHaveCount(0);
});

test("an admin's panel says the name and keeps the admin menu's name", async ({ page }) => {
  await openLab(page, "sidebar=1&signed_in=1&admin=1");
  await trigger(page).click();

  await expect(page.getByRole("navigation", { name: "Admin menu" })).toBeVisible();
  await expect(titleOf(panel(page))).toHaveText("Pat");
});

test("a signed-out panel keeps the links menu's name", async ({ page }) => {
  await openLab(page);
  await trigger(page).click();

  await expect(page.getByRole("navigation", { name: "Links menu" })).toBeVisible();
  await expect(page.getByRole("navigation", { name: /Good/ })).toHaveCount(0);
});

test("the title is the scale's subhead, at its own calm weight", async ({ page }) => {
  await openLab(page);
  await trigger(page).click();

  const font = await titleOf(panel(page)).evaluate((node) => {
    const style = getComputedStyle(node);
    return { size: style.fontSize, weight: style.fontWeight, base: getComputedStyle(document.documentElement).getPropertyValue("--type-base") };
  });
  expect(font.size, `1.5x of a --type-base of "${font.base}"`).toBe("24px");
  expect(font.weight).toBe("400");
});

test("groups show no label word, a divider separates them, and every row is one line", async ({ page }) => {
  await openLab(page, "sidebar=1&signed_in=1&admin=1");
  await trigger(page).click();
  await expect(panel(page)).toBeVisible();

  const nav = panel(page).locator("nav");
  const words = await nav.evaluate((node) => node.innerText);
  for (const label of ["You", "Site", "Help", "Ops", "ADMIN"]) {
    expect(words, `the word ${label} does not show`).not.toContain(label);
  }
  expect(words, "a link's desc: does not show").not.toContain("A description that must not show");

  // The words stay, as each group's name.
  await expect(panel(page).getByRole("group", { name: "Site" })).toBeVisible();
  await expect(panel(page).getByRole("group", { name: "Ops, admin" })).toBeVisible();

  const groups = await nav.locator(':scope > [role="group"]').evaluateAll((nodes) =>
    nodes.map((node) => {
      const style = getComputedStyle(node);
      return { name: node.getAttribute("aria-label"), width: style.borderTopWidth, color: style.borderTopColor };
    })
  );
  expect(groups.length, JSON.stringify(groups)).toBeGreaterThan(2);
  expect(groups[0].width, "nothing above the first group").toBe("0px");
  for (const group of groups.slice(1)) {
    expect(group.width, group.name).toBe("1px");
    expect(group.color, group.name).not.toBe("rgba(0, 0, 0, 0)");
  }

  // Terms passes a desc:, Home does not, and the two rows are the same height.
  const heightOf = (href) => panel(page).locator(`nav a[href="${href}"]`).first().evaluate((row) => row.getBoundingClientRect().height);
  expect(await heightOf("/site_footer/terms")).toBe(await heightOf("/"));
});

for (const [name, viewport, scope] of [
  ["a 320px phone", { width: 320, height: 640 }, phonePanel],
  ["desktop, in the 320px panel", { width: 1280, height: 800 }, panel]
]) {
  test.describe(`a long name on ${name}`, () => {
    test.use({ viewport });

    test("truncates and leaves the close button whole and clear", async ({ page }) => {
      await openLab(page, "sidebar=1&long_name=1");
      await trigger(page).click();
      const box = scope(page);
      await expect(box).toBeVisible();
      await page.waitForTimeout(350); // the 300ms slide, or the boxes read off-canvas

      const title = titleOf(box);
      const measure = await title.evaluate((node) => ({
        overflows: node.scrollWidth > node.clientWidth,
        right: node.getBoundingClientRect().right,
        text: getComputedStyle(node).textOverflow,
        lines: Math.round(node.getBoundingClientRect().height / parseFloat(getComputedStyle(node).lineHeight))
      }));
      const close = await box.locator("[data-link-sidebar-close]").boundingBox();

      expect(measure.overflows, "the name is long enough to prove anything").toBe(true);
      expect(measure.text).toBe("ellipsis");
      expect(measure.lines).toBe(1);
      expect(measure.right, "the name stops short of the close button").toBeLessThanOrEqual(close.x);
      expect(close.x + close.width, "the close button stays in the viewport").toBeLessThanOrEqual(viewport.width);
      expect(close.width).toBe(32);
      await expect(title).toHaveAttribute("title", "Bartholomew Fitzgerald-Wellington");
    });
  });
}
