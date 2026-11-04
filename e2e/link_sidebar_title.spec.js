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
//   - greetingFor reads getUTCHours: the Denver and Tokyo specs and the phone spec
//     read the UTC word, Good afternoon. 15:00Z in Paris is afternoon either way.
//   - drop the interval: the boundary spec stays on "Good morning" after the minute.
//   - drop the paint on turbo:load and in the controller's connect: the restore spec
//     reads the evening's word on the hidden panel after Back. Either one alone
//     covers it, so each alone turns nothing red; the unit test holds turbo:load.
//   - drop `border-t` from the group: the divider spec reads a border width of 0px.
//   - drop `truncate` from the title: the long-name specs read no overflow.
//   - THE ROW'S DESCRIPTION, engine.css. position: static on the description, the
//     layout-affecting version: the no-shift spec reads a row 16px taller and the next
//     row 16px lower. transition: none: the fade spec reads no value between 0 and 1.
//     The :hover rules out of @media (hover: hover): the touch spec reads opacity 1.
//     The :focus-visible rules dropped: the keyboard spec reads opacity 0. The reduced
//     motion block dropped: the reduced-motion spec reads a slide.

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

  // Terms passes a desc:, Home does not, and at rest they are the same height.
  const heightOf = (href) => panel(page).locator(`nav a[href="${href}"]`).first().evaluate((row) => row.getBoundingClientRect().height);
  expect(await heightOf("/site_footer/terms")).toBe(await heightOf("/"));
});

// --- THE ROW'S DESCRIPTION ---------------------------------------------------------

const TERMS = 'nav a[href="/site_footer/terms"]';
const opacityOf = (locator) => locator.evaluate((node) => Number(getComputedStyle(node).opacity));
const descOf = (row) => row.locator("[data-sidebar-row-desc]");

// Every row's top and height, to the sub-pixel, and the list's own scroll height.
const layoutOf = (page) =>
  panel(page).locator("nav").evaluate((nav) => ({
    scrollHeight: nav.scrollHeight,
    rows: [...nav.querySelectorAll("a, [data-test='geo-signpost-disabled']")].map((row) => {
      const box = row.getBoundingClientRect();
      return [box.top, box.height];
    })
  }));

const openPanel = async (page, query = "sidebar=1&signed_in=1&admin=1") => {
  await openLab(page, query);
  await trigger(page).click();
  await expect(panel(page)).toBeVisible();
  await page.waitForTimeout(350); // the 300ms slide, or the boxes read off-canvas
};

test("hover moves nothing: every row's top and height, in every frame of the fade", async ({ page }) => {
  await openPanel(page);
  const row = panel(page).locator(TERMS);
  const rest = await layoutOf(page);
  expect(await opacityOf(descOf(row)), "hidden at rest").toBe(0);
  expect(rest.rows.length).toBeGreaterThan(3);

  await page.evaluate(() => {
    const nav = document.querySelector("#studio-link-sidebar nav");
    window.__frames = [];
    const sample = () => {
      window.__frames.push({
        scrollHeight: nav.scrollHeight,
        rows: [...nav.querySelectorAll("a, [data-test='geo-signpost-disabled']")].map((node) => {
          const box = node.getBoundingClientRect();
          return [box.top, box.height];
        })
      });
      window.__sampling = requestAnimationFrame(sample);
    };
    sample();
  });
  await row.hover();
  await expect.poll(() => opacityOf(descOf(row))).toBe(1);
  await page.mouse.move(600, 400);
  await expect.poll(() => opacityOf(descOf(row))).toBe(0);
  const frames = await page.evaluate(() => {
    cancelAnimationFrame(window.__sampling);
    return window.__frames;
  });

  expect(frames.length, "frames sampled through the fade in and out").toBeGreaterThan(5);
  for (const frame of frames) expect(frame).toEqual(rest);
});

test("the description sits inside the row, under the lifted label, and truncates to one line", async ({ page }) => {
  await openPanel(page);
  const row = panel(page).locator(TERMS);
  await row.hover();
  await expect.poll(() => opacityOf(descOf(row))).toBe(1);
  await page.waitForTimeout(300); // the transform ends with the fade; read it settled

  const box = await row.boundingBox();
  const label = await row.locator("[data-sidebar-row-label]").boundingBox();
  const desc = await descOf(row).boundingBox();
  expect(label.y, "the label stays in the row").toBeGreaterThanOrEqual(box.y);
  expect(label.y + label.height, "the two lines do not overlap").toBeLessThanOrEqual(desc.y + 0.5);
  expect(desc.y + desc.height, "the description stays in the row").toBeLessThanOrEqual(box.y + box.height);

  const long = panel(page).locator('nav a[href="/site_footer/privacy"]');
  await long.hover();
  await expect.poll(() => opacityOf(descOf(long))).toBe(1);
  const measured = await descOf(long).evaluate((node) => ({
    overflows: node.scrollWidth > node.clientWidth,
    ellipsis: getComputedStyle(node).textOverflow,
    height: node.getBoundingClientRect().height,
    line: parseFloat(getComputedStyle(node).lineHeight)
  }));
  expect(measured.overflows, "long enough to prove anything").toBe(true);
  expect(measured.ellipsis).toBe("ellipsis");
  expect(measured.height).toBe(measured.line);
});

test("the description fades in and out rather than popping", async ({ page }) => {
  await openPanel(page);
  const row = panel(page).locator(TERMS);
  await page.evaluate((selector) => {
    const desc = document.querySelector(`#studio-link-sidebar ${selector} [data-sidebar-row-desc]`);
    window.__opacities = [];
    const sample = () => {
      window.__opacities.push(Number(getComputedStyle(desc).opacity));
      window.__fading = requestAnimationFrame(sample);
    };
    sample();
  }, TERMS);

  await row.hover();
  await expect.poll(() => opacityOf(descOf(row))).toBe(1);
  const inbound = await page.evaluate(() => window.__opacities.splice(0));
  await page.mouse.move(600, 400);
  await expect.poll(() => opacityOf(descOf(row))).toBe(0);
  const outbound = await page.evaluate(() => {
    cancelAnimationFrame(window.__fading);
    return window.__opacities;
  });

  const between = (values) => values.filter((value) => value > 0.02 && value < 0.98);
  expect(between(inbound).length, `coming in: ${inbound.join(",")}`).toBeGreaterThan(0);
  expect(between(outbound).length, `going out: ${outbound.join(",")}`).toBeGreaterThan(0);
});

test("a row with no description does nothing new on hover", async ({ page }) => {
  await openPanel(page);
  const row = panel(page).locator('nav a[href="/"]');
  const rest = await layoutOf(page);

  await row.hover();
  await page.waitForTimeout(350);

  await expect(descOf(row)).toHaveCount(0);
  const transform = await row.locator("span.font-medium").evaluate((node) => getComputedStyle(node).transform);
  expect(transform).toBe("none");
  expect(await layoutOf(page)).toEqual(rest);
});

test("keyboard focus shows the description and moves nothing", async ({ page }) => {
  await openPanel(page);
  const row = panel(page).locator(TERMS);
  const rest = await layoutOf(page);

  let reached = false;
  for (let tab = 0; tab < 40 && !reached; tab += 1) {
    await page.keyboard.press("Tab");
    reached = await row.evaluate((node) => document.activeElement === node);
  }
  expect(reached, "Tab reaches the row").toBe(true);
  expect(await row.evaluate((node) => node.matches(":focus-visible"))).toBe(true);
  expect(await row.evaluate((node) => node.matches(":hover")), "no pointer here").toBe(false);

  await expect.poll(() => opacityOf(descOf(row))).toBe(1);
  expect(await layoutOf(page)).toEqual(rest);
});

test("the description stays in the row's accessible name", async ({ page }) => {
  await openPanel(page);
  const row = panel(page).getByRole("link", { name: /Terms What you agree to/ });
  await expect(row).toHaveCount(1);
  expect(await opacityOf(descOf(row)), "while hidden to the eye").toBe(0);
});

test.describe("on a touch screen", () => {
  test.use({ hasTouch: true, isMobile: true, viewport: { width: 390, height: 844 } });

  test("a tap leaves :hover on the row and the description stays hidden", async ({ page }) => {
    await openLab(page, "sidebar=1&signed_in=1");
    expect(await page.evaluate(() => matchMedia("(hover: hover)").matches), "the device reports no hover").toBe(false);
    await trigger(page).tap();
    await expect(phonePanel(page)).toBeVisible();
    await page.waitForTimeout(350);

    // The row would navigate and the panel would close: hold both, to read the row tapped.
    await page.evaluate(() => {
      window.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopImmediatePropagation();
      }, true);
    });
    const row = phonePanel(page).locator(TERMS);
    await row.tap();
    await page.waitForTimeout(350);

    expect(await row.evaluate((node) => node.matches(":hover")), "the tap left :hover behind").toBe(true);
    expect(await opacityOf(descOf(row))).toBe(0);
  });
});

test.describe("under reduced motion", () => {
  test.use({ contextOptions: { reducedMotion: "reduce" } });

  test("the description appears where it will sit, with no slide", async ({ page }) => {
    await openPanel(page);
    expect(await page.evaluate(() => matchMedia("(prefers-reduced-motion: reduce)").matches)).toBe(true);
    const row = panel(page).locator(TERMS);
    const transformOf = () => descOf(row).evaluate((node) => getComputedStyle(node).transform);
    const rest = await transformOf();
    const layout = await layoutOf(page);

    await row.hover();
    await expect.poll(() => opacityOf(descOf(row))).toBe(1);

    expect(await transformOf(), "the same place at rest and shown").toBe(rest);
    const labelMoves = await row.locator("[data-sidebar-row-label]").evaluate((node) => getComputedStyle(node).transitionDuration);
    expect(labelMoves, "the label does not glide").toBe("0s");
    expect(await layoutOf(page)).toEqual(layout);
  });
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
