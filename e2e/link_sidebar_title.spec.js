const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The link sidebar's title, groups and rows: the word the browser writes by its own
// clock and zone, a drawn divider, one row height, and a description that moves nothing.
//
// CONTROLS, each red for its reason: no paint or UTC hours (the Tokyo spec); no paint on
// turbo:load and connect (the Turbo spec); no border-t (the groups spec); no emoji box
// (the groups spec, 46.5 against 44); description in flow (the no-shift spec, row 44 to 60,
// next row +16); 60ms delay or no transition (the fade spec); hover out of its media query
// (the touch spec); focus rules dropped (the keyboard and tap specs); no reduced-motion block
// (that spec); no truncate (the long-name spec). A section's opt-in header: pt-3 moved onto a
// row or no label-upper (the groups spec); the header put in flow inside a row (the groups
// spec, and the no-shift spec's second pass reads the rows under a header).

const panel = (page) => page.locator("#studio-link-sidebar");
const phonePanel = (page) => page.locator("#studio-link-sidebar-mobile");
const titleOf = (scope) => scope.locator("[data-link-sidebar-title]");
const trigger = (page) => page.locator("[data-link-sidebar-trigger]").first();

const openLab = async (page, query = "sidebar=1") => {
  await blockOffsiteRequests(page);
  await page.goto(`/lab/sidebar_panels?${query}`);
  await page.waitForFunction(() => window.Alpine);
};

// The server's default is Good morning, so this reads another word.
test.describe("at 15:00Z in Tokyo, midnight local", () => {
  test.use({ timezoneId: "Asia/Tokyo" });

  test("a signed-out panel says Good evening, on desktop and on the phone panel", async ({ page }) => {
    const errors = watchPageErrors(page);
    await page.clock.install({ time: "2026-11-04T15:00:00Z" });
    await openLab(page);
    expect(await page.evaluate(() => new Date().getHours()), "the browser's local hour").toBe(0);

    await trigger(page).click();
    await expect(panel(page)).toBeVisible();
    await expect(titleOf(panel(page))).toHaveText("Good evening");
    await expect(titleOf(phonePanel(page))).toHaveText("Good evening");
    expect(errors).toEqual([]);
  });
});

test.describe("across a Turbo visit", () => {
  test.use({ timezoneId: "UTC" });

  test("a visit paints the word, and a snapshot restored later paints the later word", async ({ page }) => {
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

test("the title is the scale's subhead, at its own calm weight", async ({ page }) => {
  await openLab(page);
  await trigger(page).click();

  const font = await titleOf(panel(page)).evaluate((node) => {
    const style = getComputedStyle(node);
    return { size: style.fontSize, weight: style.fontWeight };
  });
  expect(font.size).toBe("24px");
  expect(font.weight).toBe("400");
});

const openPanel = async (page, query = "sidebar=1&signed_in=1&admin=1") => {
  await openLab(page, query);
  await trigger(page).click();
  await expect(panel(page)).toBeVisible();
  await page.waitForTimeout(350); // the 300ms slide, or the boxes read off-canvas
};

const HEADERS = "sidebar=1&headers=1&signed_in=1&admin=1";
const ROWS = "a, [data-test='geo-signpost-disabled']";
const TERMS = 'nav a[href="/site_footer/terms"]';
const opacityOf = (locator) => locator.evaluate((node) => Number(getComputedStyle(node).opacity));
const descOf = (row) => row.locator("[data-sidebar-row-desc]");

// Every row's top and height, to the sub-pixel, and the list's own scroll height.
const layoutOf = (scope) =>
  scope.locator("nav").evaluate((nav, rows) => ({
    scrollHeight: nav.scrollHeight,
    rows: [...nav.querySelectorAll(rows)].map((row) => {
      const box = row.getBoundingClientRect();
      return [box.top, box.height];
    })
  }), ROWS);

test("groups show no label word, a divider separates them, and every kind of row is one height", async ({ page }) => {
  await openPanel(page);
  const nav = panel(page).locator("nav");
  const words = await nav.evaluate((node) => node.innerText);
  for (const label of ["You", "Site", "Help", "Ops", "ADMIN"]) {
    expect(words, `the word ${label} does not show`).not.toContain(label);
  }

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

  // A plain emoji (Home), a swap (Docs), a desc: (Terms), and the Geo row that cannot link.
  const rowFor = (selector) => panel(page).locator(selector).first();
  const measure = (selector) =>
    rowFor(selector).evaluate((row) => {
      const icon = row.children[0].getBoundingClientRect();
      return { height: row.getBoundingClientRect().height, labelLeft: row.children[1].getBoundingClientRect().left, iconWidth: icon.width };
    });
  const plain = await measure('nav a[href="/"]');
  expect(await measure('nav a[href="/up"]'), "a swap against a plain emoji").toEqual(plain);
  expect(await measure(TERMS), "a desc: against a plain emoji").toEqual(plain);
  expect(await measure("[data-test='geo-signpost-disabled']"), "the Geo row against a plain emoji").toEqual(plain);

  // A section that opts in with header: true: the word shows, small and above its rows,
  // and the rows under it are the rows of a group with no word.
  await openPanel(page, HEADERS);
  const headers = panel(page).locator("[data-sidebar-group-header]");
  await expect(headers).toHaveCount(2);
  expect(await headers.allInnerTexts()).toEqual(["MY APPS", "ADMIN"]);
  const label = await headers.first().evaluate((node) => {
    const style = getComputedStyle(node);
    const rowTop = node.nextElementSibling.getBoundingClientRect().top;
    return {
      size: style.fontSize,
      weight: style.fontWeight,
      transform: style.textTransform,
      hidden: node.getAttribute("aria-hidden"),
      bottomToRow: rowTop - node.getBoundingClientRect().bottom
    };
  });
  expect(label).toEqual({ size: "12px", weight: "700", transform: "uppercase", hidden: "true", bottomToRow: 0 });
  expect(await measure('nav a[href="/"]'), "a row under a header against a plain emoji").toEqual(plain);
  expect(await measure(TERMS), "a desc: under a header against a plain emoji").toEqual(plain);
  const divided = await panel(page).locator('nav > [role="group"]').evaluateAll((nodes) =>
    nodes.map((node) => [node.getAttribute("aria-label"), getComputedStyle(node).borderTopWidth])
  );
  expect(divided.slice(0, 3)).toEqual([["My Apps", "0px"], ["Help", "1px"], ["Admin", "1px"]]);

  // It is no click target: a click on the word navigates nowhere and leaves the panel open.
  const before = page.url();
  await headers.first().click();
  expect(page.url()).toBe(before);
  await expect(panel(page)).toBeVisible();
});

const hoverMovesNothing = async (page, query) => {
  await openPanel(page, query);
  const row = panel(page).locator(TERMS);
  const rest = await layoutOf(panel(page));
  expect(await opacityOf(descOf(row)), "hidden at rest").toBe(0);
  expect(rest.rows.length).toBeGreaterThan(3);

  await page.evaluate((rows) => {
    const nav = document.querySelector("#studio-link-sidebar nav");
    window.__frames = [];
    const sample = () => {
      window.__frames.push({
        scrollHeight: nav.scrollHeight,
        rows: [...nav.querySelectorAll(rows)].map((node) => {
          const box = node.getBoundingClientRect();
          return [box.top, box.height];
        })
      });
      window.__sampling = requestAnimationFrame(sample);
    };
    sample();
  }, ROWS);
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
};

test("hover moves nothing: every row's top and height, in every frame of the fade", async ({ page }) => {
  await hoverMovesNothing(page, undefined);
  await hoverMovesNothing(page, HEADERS);
});

test("the description sits inside the row, under the lifted label, and truncates to one line", async ({ page }) => {
  await openPanel(page);
  const row = panel(page).locator(TERMS);
  await row.hover();
  await expect.poll(() => opacityOf(descOf(row))).toBe(1);
  await page.waitForTimeout(100); // the transform ends with the fade; read it settled

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

test("the description waits 150ms, then fades in and out rather than popping", async ({ page }) => {
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
  expect(await descOf(row).evaluate((node) => getComputedStyle(node).transitionDelay)).toBe("0.15s, 0.15s");
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

test("keyboard focus shows a description, on a link and on the Geo row that cannot link", async ({ page }) => {
  await openPanel(page);
  const rest = await layoutOf(panel(page));

  for (const row of [panel(page).locator(TERMS), panel(page).locator("[data-test='geo-signpost-disabled']")]) {
    let reached = false;
    for (let tab = 0; tab < 40 && !reached; tab += 1) {
      await page.keyboard.press("Tab");
      reached = await row.evaluate((node) => document.activeElement === node);
    }
    expect(reached, "Tab reaches the row").toBe(true);
    expect(await row.evaluate((node) => node.matches(":hover")), "no pointer here").toBe(false);
    await expect.poll(() => opacityOf(descOf(row))).toBe(1);
    expect(await layoutOf(panel(page))).toEqual(rest);
  }
});

test.describe("on a touch screen", () => {
  test.use({ hasTouch: true, isMobile: true, viewport: { width: 390, height: 844 } });

  test("a tap leaves :hover on a link row and its description stays hidden", async ({ page }) => {
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
    await page.waitForTimeout(450);

    expect(await row.evaluate((node) => node.matches(":hover")), "the tap left :hover behind").toBe(true);
    expect(await opacityOf(descOf(row))).toBe(0);
  });

  test("a tap on the Geo row that cannot link reveals the string to copy and moves nothing", async ({ page }) => {
    await openLab(page, "sidebar=1&signed_in=1&admin=1");
    await trigger(page).tap();
    await expect(phonePanel(page)).toBeVisible();
    await page.waitForTimeout(350);
    const row = phonePanel(page).locator("[data-test='geo-signpost-disabled']");
    const rest = await layoutOf(phonePanel(page));
    expect(await opacityOf(descOf(row)), "hidden at rest").toBe(0);

    // Playwright's row.tap() refuses an aria-disabled element; a finger does not.
    const box = await row.boundingBox();
    await page.touchscreen.tap(box.x + box.width / 2, box.y + box.height / 2);

    await expect.poll(() => opacityOf(descOf(row))).toBe(1);
    await expect(descOf(row)).toHaveText(/^(ENABLE_GEO_BLOCKING=true|config\.draw_geo_routes = true)$/);
    expect(await descOf(row).evaluate((node) => getComputedStyle(node).pointerEvents), "selectable").toBe("auto");
    expect(await layoutOf(phonePanel(page))).toEqual(rest);
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
    const layout = await layoutOf(panel(page));

    await row.hover();
    await expect.poll(() => opacityOf(descOf(row))).toBe(1);

    expect(await transformOf(), "the same place at rest and shown").toBe(rest);
    const labelMoves = await row.locator("[data-sidebar-row-label]").evaluate((node) => getComputedStyle(node).transitionDuration);
    expect(labelMoves, "the label does not glide").toBe("0s");
    expect(await layoutOf(panel(page))).toEqual(layout);
  });
});

test.describe("a long name on a 320px phone", () => {
  test.use({ viewport: { width: 320, height: 640 } });

  test("truncates and leaves the close button whole and clear", async ({ page }) => {
    await openLab(page, "sidebar=1&long_name=1");
    await trigger(page).click();
    const box = phonePanel(page);
    await expect(box).toBeVisible();
    await page.waitForTimeout(350); // the 300ms slide, or the boxes read off-canvas

    const title = titleOf(box);
    const measure = await title.evaluate((node) => ({
      overflows: node.scrollWidth > node.clientWidth,
      right: node.getBoundingClientRect().right,
      text: getComputedStyle(node).textOverflow
    }));
    const close = await box.locator("[data-link-sidebar-close]").boundingBox();

    expect(measure.overflows, "the name is long enough to prove anything").toBe(true);
    expect(measure.text).toBe("ellipsis");
    expect(measure.right, "the name stops short of the close button").toBeLessThanOrEqual(close.x);
    expect(close.x + close.width, "the close button stays in the viewport").toBeLessThanOrEqual(320);
    expect(close.width).toBe(32);
    await expect(title).toHaveAttribute("title", "Bartholomew Fitzgerald-Wellington");
  });
});
