const { test, expect } = require("@playwright/test");
const { watchPageErrors, expectStickyChromeIsLive, blockOffsiteRequests } = require("./helpers");

// THE HEADER, ON A PHONE.
//
// ============ WHY THE OBVIOUS ASSERTION IS THE WRONG ONE ============
//
// `documentElement.scrollWidth > clientWidth` is the honest test for "this page
// scrolls sideways", and it was GREEN on the broken header at the exact width
// this spec cares about. Measured, before the fix, at 390x844 with the lab
// host's app_name "McRitchie Industries":
//
//     documentElement.scrollWidth   390
//     documentElement.clientWidth   390     <- no sideways scroll
//     left column border box        0..166
//     .nav-title right edge         175.3   <- 9.3px OUTSIDE its own column
//
// The app's name was painting on top of the user column beside it — visible in
// a screenshot, invisible to every document-level measurement, because an
// element overflowing its SIBLING's territory never reaches documentElement.
// The header row is exactly 100% wide either way.
//
// So this spec asserts TWO different things, and the second is the one that
// caught the defect:
//
//   1. The page does not scroll sideways (the acceptance criterion, kept
//      because it is the user-visible promise and because it DID fail below
//      367px — the header had a hard minimum width of 367px at every viewport,
//      so 320px and 360px phones scrolled sideways by 47px and 7px).
//   2. No part of the header draws outside the column it belongs to. This is
//      the CONTAINMENT property, and it is what "fits" actually means.
//
// ============ WHY THE LAB HOST HAS A LOGO AND A REAL NAME ============
//
// e2e/boot.rb gives the lab a Navbar Logo and a two-word app_name because every
// real consumer has both and the bare dummy has neither. With Studio's defaults
// (app_name "Studio", no theme_logos) this page measured ZERO overflowing
// elements and a perfectly contained header — a green read over the broken
// code. The fixture is load-bearing; read boot.rb's note before changing it.

const PHONE = { width: 390, height: 844 };

// The widths this lane holds the header to. 320 is the iPhone SE (1st gen) and
// the narrowest screen anyone still ships; 360 is the most common Android;
// 390 is the iPhone 12-16 class and the width in the acceptance criterion;
// 412/430 are Pixel and iPhone Pro Max. Not a taste list — every one of
// 320/344/360 scrolled sideways before this fix.
const WIDTHS = [320, 360, 375, 390, 412, 430];

// Read the header's geometry: the document's own overflow, every element that
// pokes past the viewport, and — separately — anything drawing outside the
// column it lives in.
async function readHeaderGeometry(page) {
  return await page.evaluate(() => {
    const de = document.documentElement;
    const viewport = de.clientWidth;

    const past = [];
    const walk = (el) => {
      const style = getComputedStyle(el);
      if (style.display === "none" || style.visibility === "hidden") return;
      const box = el.getBoundingClientRect();
      if (box.width === 0 && box.height === 0) return;
      if (box.right > viewport + 0.5 || box.left < -0.5) {
        past.push({
          tag: el.tagName.toLowerCase(),
          className: (el.getAttribute("class") || "").slice(0, 70),
          right: Math.round(box.right * 10) / 10,
          width: Math.round(box.width * 10) / 10,
          // flex-shrink is reported because the ANSWER to this defect was an
          // ancestor with flex-shrink: 0, not the visible thing sticking out.
          flexShrink: style.flexShrink
        });
      }
      for (const child of el.children) walk(child);
    };
    walk(document.body);

    const leftColumn = document.querySelector(".nav-row > div");
    const title = document.querySelector(".nav-title");
    const userColumn = document.querySelector(".user-nav-col, .user-nav-fit");
    const rect = (el) => (el ? el.getBoundingClientRect() : null);
    const leftBox = rect(leftColumn);
    const titleBox = rect(title);

    return {
      viewport,
      documentScrollWidth: de.scrollWidth,
      documentClientWidth: de.clientWidth,
      pastViewport: past,
      // scrollWidth vs clientWidth ON THE COLUMN is how a column reports that
      // its own contents do not fit inside it — the measurement the document
      // level cannot make.
      leftColumnWidth: leftColumn ? Math.round(leftColumn.getBoundingClientRect().width) : null,
      leftColumnScrollWidth: leftColumn ? leftColumn.scrollWidth : null,
      titleRight: titleBox ? Math.round(titleBox.right * 10) / 10 : null,
      titleWidth: titleBox ? Math.round(titleBox.width * 10) / 10 : null,
      leftColumnRight: leftBox ? Math.round(leftBox.right * 10) / 10 : null,
      userColumnWidth: userColumn ? Math.round(userColumn.getBoundingClientRect().width) : null,
      userColumnLeft: userColumn ? Math.round(userColumn.getBoundingClientRect().left * 10) / 10 : null
    };
  });
}

test("the signed-in header does not scroll the page sideways on any phone", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);

  const report = [];
  for (const width of WIDTHS) {
    await page.setViewportSize({ width, height: 844 });
    await page.goto("/lab/bar_stack?signed_in=1");
    await expectStickyChromeIsLive(page, expect);

    const geometry = await readHeaderGeometry(page);
    report.push(`${width}px: scrollWidth=${geometry.documentScrollWidth} clientWidth=${geometry.documentClientWidth}`);

    expect(
      geometry.documentScrollWidth,
      `at ${width}px the page scrolls sideways by ${geometry.documentScrollWidth - geometry.documentClientWidth}px. ` +
        `Widest element past the edge: ${JSON.stringify(geometry.pastViewport[0] || null)}. ` +
        `All widths so far: ${report.join(", ")}`
    ).toBe(geometry.documentClientWidth);

    expect(
      geometry.pastViewport,
      `at ${width}px these elements extend past the viewport: ${JSON.stringify(geometry.pastViewport, null, 2)}`
    ).toEqual([]);
  }

  expect(errors).toEqual([]);
});

test("the app name stays inside its own column instead of drawing over the user nav", async ({ page }) => {
  await blockOffsiteRequests(page);

  await page.setViewportSize(PHONE);
  await page.goto("/lab/bar_stack?signed_in=1");
  await expectStickyChromeIsLive(page, expect);

  const geometry = await readHeaderGeometry(page);

  // THE ASSERTION THAT WOULD HAVE CAUGHT IT. Before the fix this read
  // titleRight=175.3 against leftColumnRight=166 while the document measured a
  // contented 390/390.
  expect(
    geometry.titleRight,
    `the app name's right edge (${geometry.titleRight}) is outside its own column ` +
      `(ends at ${geometry.leftColumnRight}), so it is drawing across the gap and over ` +
      `the user column that starts at ${geometry.userColumnLeft}. The page does not ` +
      `scroll sideways — documentElement reports ${geometry.documentScrollWidth}/` +
      `${geometry.documentClientWidth} — which is exactly why a document-level check ` +
      `cannot see this.`
  ).toBeLessThanOrEqual(geometry.leftColumnRight);

  // And the column itself contains its contents. scrollWidth > clientWidth on a
  // column is the same defect stated from the other side, and it is the form
  // that survives a later markup change that renames .nav-title.
  expect(
    geometry.leftColumnScrollWidth,
    `the header's left column reports scrollWidth ${geometry.leftColumnScrollWidth} ` +
      `against a width of ${geometry.leftColumnWidth} — its contents do not fit inside it`
  ).toBeLessThanOrEqual(geometry.leftColumnWidth + 1);

  // The two columns do not overlap. Stated on the boxes rather than on the
  // text, because this is the property a host inherits no matter what it puts
  // in either column.
  expect(
    geometry.userColumnLeft,
    "the user column starts before the left column ends — the two overlap"
  ).toBeGreaterThanOrEqual(geometry.leftColumnRight - 1);
});

test("a wider phone never shows less of the app name", async ({ page }) => {
  await blockOffsiteRequests(page);

  // MONOTONICITY, and it is not a nicety — it is a defect this fix CAUSED and
  // then had to correct. Capping only the base band left a 412px Pixel showing
  // 84px of the app's name while a 390px iPhone showed 107px, because 412 falls
  // in the next band up, which still carried a constant 15rem. A wider screen
  // showing less is indistinguishable from a bug to the person holding it.
  const measured = [];
  for (const width of WIDTHS) {
    await page.setViewportSize({ width, height: 844 });
    await page.goto("/lab/bar_stack?signed_in=1");
    const geometry = await readHeaderGeometry(page);
    measured.push({ width, titleWidth: geometry.titleWidth });
  }

  for (let i = 1; i < measured.length; i++) {
    expect(
      measured[i].titleWidth,
      `the app name is ${measured[i].titleWidth}px wide at ${measured[i].width}px but ` +
        `${measured[i - 1].titleWidth}px at the narrower ${measured[i - 1].width}px. ` +
        `Full series: ${JSON.stringify(measured)}`
    ).toBeGreaterThanOrEqual(measured[i - 1].titleWidth);
  }
});

test("the development banner fits a phone in every state it ships", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);

  // The banner is the other half of the acceptance criterion and the easy half
  // to forget: it renders only outside production, so a production screenshot
  // is clean while every developer's and every QA reviewer's screen is not.
  // `devnet` adds the chip, `admin` the cog — the widest the bar gets.
  const states = ["", "?devnet=1", "?signed_in=1&devnet=1", "?signed_in=1&admin=1&sidebar=1&devnet=1"];

  await page.setViewportSize(PHONE);
  for (const query of states) {
    await page.goto("/lab/bar_stack" + query);

    const bar = await page.evaluate(() => {
      const stack = document.querySelector("[data-studio-bar-stack]");
      if (!stack) return null;
      const de = document.documentElement;
      const banner = stack.querySelector("[data-studio-app-banner]");
      const actions = stack.querySelector("[data-studio-app-banner] .shrink-0");
      const box = (el) => (el ? el.getBoundingClientRect() : null);
      const actionsBox = box(actions);
      return {
        documentScrollWidth: de.scrollWidth,
        documentClientWidth: de.clientWidth,
        bannerScrollWidth: banner ? banner.scrollWidth : null,
        bannerWidth: banner ? Math.round(banner.getBoundingClientRect().width) : null,
        actionsRight: actionsBox ? Math.round(actionsBox.right * 10) / 10 : null
      };
    });

    expect(bar, `no bar stack rendered for ${query || "(default)"} — the banner self-gates ` +
      "on Studio.show_environment_banner?, so a lane running under RAILS_ENV=production " +
      "would measure nothing and pass").not.toBeNull();

    expect(
      bar.documentScrollWidth,
      `the dev banner state ${query || "(default)"} scrolls the page sideways`
    ).toBe(bar.documentClientWidth);

    expect(
      bar.bannerScrollWidth,
      `the dev banner's contents (${bar.bannerScrollWidth}px) do not fit its own ` +
        `box (${bar.bannerWidth}px) in state ${query || "(default)"}`
    ).toBeLessThanOrEqual(bar.bannerWidth + 1);

    // The action buttons are `shrink-0` and `whitespace-nowrap` — the one part
    // of this bar that cannot give — so their right edge is the thing to watch.
    expect(
      bar.actionsRight,
      `the banner's un-shrinkable button group ends at ${bar.actionsRight} in a ` +
        `${bar.documentClientWidth}px viewport`
    ).toBeLessThanOrEqual(bar.documentClientWidth);
  }

  expect(errors).toEqual([]);
});
