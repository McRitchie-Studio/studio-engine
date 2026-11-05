const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The app-to-app page transition (studio/page_transitions, docs/PAGE_TRANSITIONS.md).
// The animation names, the groups and the frames are observable only in a browser. A recorder
// walks document.getAnimations() each frame and keeps what each view-transition pseudo ran.
const LAB = "/lab/page_transitions";
const FADE_OUT = "vt-page-out";
const PIXEL_PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAEBgIApD5fRAAAAABJRU5ErkJggg==";

async function record(page) {
  await page.addInitScript(() => {
    // Only the transition's own: a page's infinite animation refuses finish().
    window.transitionAnimations = () => document.getAnimations()
      .filter((a) => a.effect && (a.effect.pseudoElement || "").startsWith("::view-transition"));
    window.__seen = [];
    window.__frames = [];
    const tick = () => {
      for (const animation of document.getAnimations()) {
        const pseudo = animation.effect && animation.effect.pseudoElement;
        if (!pseudo || !pseudo.startsWith("::view-transition")) continue;
        const key = `${pseudo} ${animation.animationName || ""}`;
        if (!window.__seen.includes(key)) window.__seen.push(key);
      }
      // Only a real motion: "still" stands from turbo:visit, before any transition exists.
      const style = document.documentElement.dataset.pageTransition;
      if (style && style !== "still") {
        const read = (pseudo) => getComputedStyle(document.documentElement, pseudo).transform;
        window.__frames.push({
          root: read("::view-transition-old(root)"),
          stack: read("::view-transition-group(studio-bar-stack)"),
        });
      }
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
}

const seen = (page) => page.evaluate(() => window.__seen);

async function go(page, testId = "other") {
  const load = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.locator(`[data-test="${testId}"]`).first().click();
  await load;
}

async function open(page, query) {
  await blockOffsiteRequests(page);
  await record(page);
  await page.route("**/e2e/img/pt-hung.png", () => {});
  await page.route("**/e2e/img/pt-failed.png", (route) => route.abort());
  await page.goto(`${LAB}?${query}`);
  await page.waitForFunction(() => window.Turbo);
}

// The share of pixels that differ, at quarter size, with where they start for a failure.
// Chrome that moved reads 100% here. The ceiling is 10%, not 0: on the CI's Linux the phone
// stack's label reads 3% changed, starting at its left edge (x16), with the page paused; it
// did not reproduce on a Mac, and a slow font did not cause it. Text paints differently in a
// snapshot there, by all that was measured. Bytes cannot compare a gradient's snapshot either.
function changedShare(page, a, b) {
  return page.evaluate(async ([one, two]) => {
    const read = async (encoded) => {
      const blob = await (await fetch(`data:image/png;base64,${encoded}`)).blob();
      const bitmap = await createImageBitmap(blob);
      const width = Math.ceil(bitmap.width / 4);
      const height = Math.ceil(bitmap.height / 4);
      const canvas = new OffscreenCanvas(width, height);
      const context = canvas.getContext("2d");
      context.imageSmoothingQuality = "high";
      context.drawImage(bitmap, 0, 0, width, height);
      return { width, data: context.getImageData(0, 0, width, height).data };
    };
    const [left, right] = [await read(one), await read(two)];
    let changed = 0;
    let first = null;
    for (let i = 0; i < left.data.length; i += 4) {
      if (Math.abs(left.data[i] - right.data[i]) + Math.abs(left.data[i + 1] - right.data[i + 1]) + Math.abs(left.data[i + 2] - right.data[i + 2]) > 24) {
        changed += 1;
        if (!first) first = `x${((i / 4) % left.width) * 4}`;
      }
    }
    return { share: changed / (left.data.length / 4), first };
  }, [a.toString("base64"), b.toString("base64")]);
}

function expectPlayed(names, oldName, newName) {
  expect(names).toContain(`::view-transition-old(root) ${oldName}`);
  expect(names).toContain(`::view-transition-new(root) ${newName}`);
}

for (const [direction, out, slideIn, unfoldIn] of [
  ["left", "pt-out-left", "pt-in-from-right", "pt-unfold-right"],
  ["right", "pt-out-right", "pt-in-from-left", "pt-unfold-left"],
  ["top", "pt-out-top", "pt-in-from-bottom", "pt-unfold-bottom"],
  ["bottom", "pt-out-bottom", "pt-in-from-top", "pt-unfold-top"],
]) {
  test(`${direction} with no style plays the slide, on every visit`, async ({ page }) => {
    const errors = watchPageErrors(page);
    await open(page, `direction=${direction}`);
    for (let visit = 0; visit < 3; visit += 1) {
      await page.evaluate(() => { window.__seen.length = 0; });
      await go(page);
      const names = await seen(page);
      expectPlayed(names, out, slideIn);
      expect(names).not.toContain(`::view-transition-new(root) ${unfoldIn}`);
    }
    expect(errors).toEqual([]);
  });

  test(`${direction} with style=unfold plays the unfold, on every visit`, async ({ page }) => {
    await open(page, `direction=${direction}&style=unfold`);
    for (let visit = 0; visit < 3; visit += 1) {
      await page.evaluate(() => { window.__seen.length = 0; });
      await go(page);
      const names = await seen(page);
      expectPlayed(names, out, unfoldIn);
      expect(names).not.toContain(`::view-transition-new(root) ${slideIn}`);
    }
  });
}

// Stops the motion at its midpoint and reads what the browser computed.
async function pausedMidway(page) {
  const seenPaused = page.evaluate(() => new Promise((done) => {
    const check = () => {
      const running = window.transitionAnimations().filter((a) => (a.animationName || "").startsWith("pt-"));
      if (running.length < 2) return requestAnimationFrame(check);
      running.forEach((a) => { a.pause(); a.currentTime = 350; });
      requestAnimationFrame(() => requestAnimationFrame(() => done()));
    };
    check();
  }));
  await page.locator('[data-test="other"]').first().click();
  await seenPaused;
}

function readMidway(page) {
  return page.evaluate(() => {
    const read = (pseudo) => getComputedStyle(document.documentElement, pseudo);
    return {
      oldOpacity: read("::view-transition-old(root)").opacity,
      newOpacity: read("::view-transition-new(root)").opacity,
      backdrop: read("::view-transition").backgroundColor,
      page: getComputedStyle(document.body).backgroundColor,
    };
  });
}

for (const theme of ["dark", "light"]) {
  test(`a slide stays opaque over the page color, ${theme} theme`, async ({ page }) => {
    await open(page, `direction=left&theme=${theme}`);
    await page.evaluate((value) => { document.documentElement.dataset.theme = value; }, theme);
    await pausedMidway(page);
    const midway = await readMidway(page);
    expect(midway.oldOpacity).toBe("1");
    expect(midway.newOpacity).toBe("1");
    expect(midway.backdrop).not.toBe("rgb(0, 0, 0)");
    expect(midway.backdrop).toBe(midway.page);
  });

  test(`an unfold has the page color behind it, ${theme} theme`, async ({ page }) => {
    await open(page, `direction=right&style=unfold&theme=${theme}`);
    await page.evaluate((value) => { document.documentElement.dataset.theme = value; }, theme);
    await pausedMidway(page);
    const midway = await readMidway(page);
    expect(midway.backdrop).not.toBe("rgb(0, 0, 0)");
    expect(midway.backdrop).toBe(midway.page);
  });
}

// Stops the motion partway and compares pixels: chrome that moved with the page differs.
async function expectChromeHoldsStill(page) {
  const stack = page.locator("[data-vt-held]");
  await expect(stack).toBeVisible();
  const stackBox = await stack.boundingBox();
  const headerBox = await page.locator(".vt-pinned-header").boundingBox();
  // Paint the stack as a visit does, named: a stacking context changes how text is
  // antialiased on the CI's Linux, which would read as motion (2 to 5% of pixels).
  await page.evaluate(() => { document.documentElement.dataset.pageTransitionVisit = ""; });
  await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
  const before = {
    stack: await page.screenshot({ clip: stackBox }),
    header: await page.screenshot({ clip: headerBox }),
  };

  await page.evaluate(() => document.querySelector('[data-test="other"]').click());
  await page.waitForFunction(() => document.getAnimations().some((a) => (a.animationName || "").startsWith("pt-")));
  await page.evaluate(() => transitionAnimations().forEach((a) => { a.pause(); a.currentTime = 280; }));
  const pageMoved = await page.evaluate(() => getComputedStyle(document.documentElement, "::view-transition-old(root)").transform);
  expect(pageMoved, "the page never moved, so this measured nothing").not.toBe("none");
  const during = {
    stack: await page.screenshot({ clip: stackBox }),
    header: await page.screenshot({ clip: headerBox }),
  };
  await page.evaluate(() => transitionAnimations().forEach((a) => a.finish()));
  await page.waitForFunction(() => !document.documentElement.hasAttribute("data-page-transition"));
  const stackChange = await changedShare(page, before.stack, during.stack);
  const headerChange = await changedShare(page, before.header, during.header);
  expect(stackChange.share, `the banner stack moved, from ${stackChange.first}`).toBeLessThan(0.1);
  expect(headerChange.share, `the navbar moved, from ${headerChange.first}`).toBeLessThan(0.1);
}

test("the page moves while the banner stack and the navbar hold still", async ({ page }) => {
  await open(page, "direction=left");
  await expectChromeHoldsStill(page);
  const names = await seen(page);
  expect(names.filter((name) => /(old|new)\(studio-bar-stack\)/.test(name))).toEqual([]);
  expect(names.filter((name) => /(old|new)\(studio-header\)/.test(name))).toEqual([]);
});

test("the stack has its name for the visit alone, so its tooltip stays over the navbar", async ({ page }) => {
  await open(page, "direction=left");
  const stack = page.locator("[data-vt-held]");
  const name = () => stack.evaluate((el) => getComputedStyle(el).viewTransitionName);
  expect(await name()).toBe("none");

  const button = page.locator("[data-studio-banner-button]:has([data-studio-banner-tooltip])").first();
  await button.hover();
  const onTop = await button.evaluate((el) => {
    const tip = el.querySelector("[data-studio-banner-tooltip]");
    tip.style.pointerEvents = "auto";
    const box = tip.getBoundingClientRect();
    const header = document.querySelector(".vt-pinned-header").getBoundingClientRect();
    const y = box.top + box.height / 2;
    return {
      overlapsHeader: y > header.top && y < header.bottom,
      top: tip.contains(document.elementFromPoint(box.left + box.width / 2, y)),
    };
  });
  expect(onTop.overlapsHeader, "the tooltip does not reach the navbar, so this measured nothing").toBe(true);
  expect(onTop.top, "the tooltip painted under the navbar").toBe(true);
  await page.mouse.move(0, 400);

  await page.evaluate(() => { window.__names = []; document.addEventListener("turbo:before-render", () => {
    window.__names.push(getComputedStyle(document.querySelector("[data-vt-held]")).viewTransitionName);
  }, { once: true }); });
  await go(page);
  expect(await page.evaluate(() => window.__names)).toEqual(["studio-bar-stack"]);
  expect(await name()).toBe("none");
  expect(await page.evaluate(() => document.documentElement.dataset.pageTransitionVisit)).toBeUndefined();
});

test("a second banner stack gets no second name, so the transition still plays", async ({ page }) => {
  await open(page, "direction=left&twice=1");
  await expect(page.locator(".studio-bar-stack")).toHaveCount(2);
  await expect(page.locator("[data-vt-held]")).toHaveCount(1);
  await go(page);
  expectPlayed(await seen(page), "pt-out-left", "pt-in-from-right");
});

test("a same-page visit plays nothing", async ({ page }) => {
  await open(page, "direction=left");
  await go(page, "same");
  const names = await seen(page);
  expect(names.filter((name) => /\((root)\) /.test(name) && !name.includes("group"))).toEqual([]);
});

test("the setting off plays no style, with no script, no marks and no name", async ({ page }) => {
  const requests = [];
  page.on("request", (request) => requests.push(request.url()));
  const moduleRequests = () => requests.filter((url) => url.includes("studio/page_transitions"));

  await open(page, "");
  expect(await page.locator('meta[name="page-transition-direction"]').count()).toBe(0);
  expect(await page.evaluate(() => document.documentElement.dataset.pageTransitionDirection)).toBeUndefined();
  await expect(page.locator("[data-vt-held]")).toHaveCount(0);
  await expect(page.locator("header.vt-pinned-header, .vt-pinned-header")).toHaveCount(0);
  expect(moduleRequests()).toEqual([]);

  await page.locator('[data-test="other"]').first().click();
  await expect(page.locator('[data-test="page-b"]')).toBeVisible();
  expect((await seen(page)).filter((name) => name.includes(" pt-"))).toEqual([]);
  expect(await page.evaluate(() => document.documentElement.hasAttribute("data-page-transition"))).toBe(false);
  expect(moduleRequests()).toEqual([]);

  // The control: the same page with the setting on does fetch it.
  await page.goto(`${LAB}?direction=left`);
  await page.waitForFunction(() => document.documentElement.dataset.pageTransitionDirection === "left");
  expect(moduleRequests().length).toBeGreaterThan(0);
});

test("a hung image releases the swap at the cap", async ({ page }) => {
  await open(page, "direction=left&img=hung");
  const waited = await page.evaluate(() => new Promise((done) => {
    document.addEventListener("turbo:before-render", () => {
      const started = performance.now();
      document.addEventListener("turbo:render", () => done(performance.now() - started), { once: true });
    }, { once: true });
    document.querySelector('[data-test="other"]').click();
  }));
  expect(waited).toBeGreaterThanOrEqual(450);
  expect(waited).toBeLessThan(1500);
  await expect(page.locator('[data-test="page-b"]')).toBeVisible();
});

test("a failed image does not hold the visit", async ({ page }) => {
  await open(page, "direction=left&img=failed");
  const waited = await page.evaluate(() => new Promise((done) => {
    document.addEventListener("turbo:before-render", () => {
      const started = performance.now();
      document.addEventListener("turbo:render", () => done(performance.now() - started), { once: true });
    }, { once: true });
    document.querySelector('[data-test="other"]').click();
  }));
  expect(waited).toBeLessThan(400);
  await expect(page.locator('[data-test="page-b"]')).toBeVisible();
});

test("the incoming image is decoded before the swap, and another listener's resume cannot cut it short", async ({ page }) => {
  // What Turf's turbo_snapshot_cache.js does: a hold of one tick, from a listener bound
  // ahead of the engine's module, as a host's entry point is.
  await page.addInitScript(() => document.addEventListener("turbo:before-render", (event) => {
    const { resume } = event.detail;
    event.preventDefault();
    setTimeout(resume, 0);
  }));
  await open(page, "direction=left&img=slow");
  await page.route("**/e2e/img/pt-slow.png", async (route) => {
    await new Promise((done) => setTimeout(done, 300));
    await route.fulfill({ body: Buffer.from(PIXEL_PNG, "base64"), contentType: "image/png" });
  });
  const complete = await page.evaluate(() => new Promise((done) => {
    document.addEventListener("turbo:render", () => {
      const img = document.querySelector('[data-test="eager-image"]');
      done({ complete: img.complete, width: img.naturalWidth });
    }, { once: true });
    document.querySelector('[data-test="other"]').click();
  }));
  expect(complete.width, "the real image had not loaded when the page swapped").toBeGreaterThan(0);
});

test("the overlay never shows during the image wait", async ({ page }) => {
  await open(page, "direction=left&img=hung&overlay=1");
  // From before-render on: a slow response may show the overlay, as it always has.
  await page.evaluate(() => {
    window.__overlayShown = 0;
    document.addEventListener("turbo:before-render", () => {
      const overlay = document.querySelector("[data-studio-loader-overlay]");
      if (!overlay.hidden) window.__overlayShown += 1;
      new MutationObserver(() => { if (!overlay.hidden) window.__overlayShown += 1; }).observe(overlay, { attributes: true });
    }, { once: true });
  });
  await go(page);
  expect(await page.evaluate(() => window.__overlayShown)).toBe(0);
});

test("a chat head on one page alone moves with the page", async ({ page }) => {
  await open(page, "direction=left&morph=a");
  await go(page);
  const names = await seen(page);
  expectPlayed(names, "pt-out-left", "pt-in-from-right");
  expect(names.filter((name) => name.includes("agent-portrait"))).toEqual([]);
});

test("a chat head on both pages morphs, and no style plays", async ({ page }) => {
  await open(page, "direction=left&morph=both");
  await go(page);
  const names = await seen(page);
  expect(names.some((name) => name.startsWith("::view-transition-group(agent-portrait)"))).toBe(true);
  expect(names).toContain(`::view-transition-old(root) ${FADE_OUT}`);
  expect(names.filter((name) => name.includes(" pt-"))).toEqual([]);
});

// The launch panel's own visit: a new page at the address it already holds.
async function visitHere(page, options) {
  const load = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.evaluate((visit) => window.Turbo.visit(window.location.href, visit), options);
  await load;
}

test("an advance visit to the same path morphs a shared name, and no style plays", async ({ page }) => {
  await open(page, "direction=left&morph=both");
  await visitHere(page, {});
  const names = await seen(page);
  expect(names.some((name) => name.startsWith("::view-transition-group(agent-portrait)"))).toBe(true);
  expect(names.filter((name) => name.includes(" pt-"))).toEqual([]);
});

test("a refresh of the same path plays nothing, with a chat head on the page", async ({ page }) => {
  await open(page, "direction=left&morph=both");
  await visitHere(page, { action: "replace" });
  const names = await seen(page);
  expect(names.some((name) => name.includes("agent-portrait"))).toBe(false);
  expect(names.filter((name) => /\(root\) /.test(name) && !name.includes("group"))).toEqual([]);
});

test("a visit that redirects moves the page once", async ({ page }) => {
  await page.addInitScript(() => {
    window.__moves = [];
    const start = document.startViewTransition.bind(document);
    document.startViewTransition = (update) => {
      const transition = start(update);
      transition.ready.then(() => {
        window.__moves.push(document.getAnimations().some((a) => (a.animationName || "").startsWith("pt-")));
      }, () => {});
      return transition;
    };
  });
  await open(page, "direction=left");
  await go(page, "redirect");
  await expect(page.locator('[data-test="page-b"]')).toBeVisible();
  expect(new URL(page.url()).pathname).toBe("/lab/page_transitions_b");
  expect(await page.evaluate(() => window.__moves)).toEqual([true, false]);
  expectPlayed(await seen(page), "pt-out-left", "pt-in-from-right");
});

// A refused form: Turbo renders the 422 with no visit, and fires no turbo:load.
async function refuseForm(page) {
  const html = await page.evaluate(() => fetch(window.location.href).then((response) => response.text()));
  await page.route("**/lab/refused", (route) => route.fulfill({ status: 422, contentType: "text/html", body: html }));
  const rendered = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:render", done, { once: true })));
  await page.evaluate(() => {
    const form = document.createElement("form");
    form.method = "post";
    form.action = "/lab/refused";
    document.body.appendChild(form);
    form.requestSubmit();
  });
  await rendered;
}

test("after a refused form, the next link still moves the page", async ({ page }) => {
  await open(page, "direction=left");
  await refuseForm(page);
  await go(page);
  expectPlayed(await seen(page), "pt-out-left", "pt-in-from-right");
});

test("after a refused form, a replace visit to another path still moves the page", async ({ page }) => {
  await open(page, "direction=left");
  await refuseForm(page);
  const load = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.evaluate(() => window.Turbo.visit(document.querySelector('[data-test="other"]').href, { action: "replace" }));
  await load;
  expectPlayed(await seen(page), "pt-out-left", "pt-in-from-right");
});

test("after a refused form, an advance to the same path still morphs", async ({ page }) => {
  await open(page, "direction=left&morph=both");
  await refuseForm(page);
  await visitHere(page, {});
  const names = await seen(page);
  expect(names.some((name) => name.startsWith("::view-transition-group(agent-portrait)"))).toBe(true);
});

test("Back between two chat heads still morphs, from Turbo's cache", async ({ page }) => {
  await open(page, "direction=left&morph=both");
  await go(page);
  await page.evaluate(() => { window.__seen.length = 0; });
  const load = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.goBack();
  await load;
  const names = await seen(page);
  expect(names.some((name) => name.startsWith("::view-transition-group(agent-portrait)"))).toBe(true);
  expect(names.filter((name) => name.includes(" pt-"))).toEqual([]);
});

test("Back from a scrolled page plays the app's direction and restores the scroll", async ({ page }) => {
  await open(page, "direction=left");
  await page.evaluate(() => window.scrollTo(0, 800));
  await page.waitForTimeout(200); // Turbo records the position on a throttled scroll.
  // Not locator.click: Playwright would scroll the link into view first.
  const left = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.evaluate(() => document.querySelector('[data-test="other"]').click());
  await left;
  await page.waitForTimeout(200); // Past the page's own load: Turbo ignores an early popstate.
  expect(await page.evaluate(() => window.scrollY)).toBe(0);
  await page.evaluate(() => { window.__seen.length = 0; });
  const load = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.goBack();
  await load;
  expectPlayed(await seen(page), "pt-out-left", "pt-in-from-right");
  await expect(page.locator('[data-test="page-a"]')).toBeVisible();
  expect(await page.evaluate(() => window.scrollY)).toBe(800);
});

test("a modal open across the swap is gone on arrival, and the move still plays", async ({ page }) => {
  const errors = watchPageErrors(page);
  await open(page, "direction=left&modal=1");
  await page.evaluate(() => window.Alpine.store("modals").open("lab-first", { title: "Card" }));
  await expect(page.locator('[role="dialog"]')).toBeVisible();
  const left = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.evaluate(() => window.Turbo.visit(document.querySelector('[data-test="other"]').href));
  await left;
  expectPlayed(await seen(page), "pt-out-left", "pt-in-from-right");
  await expect(page.locator('[data-test="page-b"]')).toBeVisible();
  await expect(page.locator('[role="dialog"]')).toHaveCount(0);
  expect(await page.evaluate(() => document.body.classList.contains("modal-open"))).toBe(false);
  expect(errors).toEqual([]);
});

test("a sidebar open across the swap comes back closed, and the move still plays", async ({ page }) => {
  const errors = watchPageErrors(page);
  await open(page, "direction=left&sidebar=1");
  await page.waitForFunction(() => window.Alpine && window.Alpine.store("sidebars"));
  await page.evaluate(() => { window.Alpine.store("sidebars").linkTreeOpen = true; });
  await expect(page.locator("#studio-link-sidebar")).toBeVisible();
  const left = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.evaluate(() => window.Turbo.visit(document.querySelector('[data-test="other"]').href));
  await left;
  expectPlayed(await seen(page), "pt-out-left", "pt-in-from-right");
  await expect(page.locator('[data-test="page-b"]')).toBeVisible();
  await expect(page.locator("#studio-link-sidebar")).toBeHidden();
  expect(errors).toEqual([]);
});

test("at phone width the chrome holds still while the page moves", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await open(page, "direction=top");
  await expectChromeHoldsStill(page);
  expectPlayed(await seen(page), "pt-out-top", "pt-in-from-bottom");
});

test("leaving a page scrolled, the stack does not slide in, and the collapsed navbar still pins", async ({ page }) => {
  await open(page, "direction=left");
  await page.evaluate(() => window.scrollTo(0, 800));
  await page.waitForTimeout(100);
  const left = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.evaluate(() => document.querySelector('[data-test="other"]').click());
  await left;
  const frames = await page.evaluate(() => window.__frames);
  expect(new Set(frames.map((frame) => frame.root)).size).toBeGreaterThan(3);
  expect(new Set(frames.map((frame) => frame.stack)).size, "the stack slid in from above the viewport").toBe(1);
  expect((await seen(page)).filter((name) => name.includes("group(studio-bar-stack)"))).toEqual([]);
  await expect(page.locator('[data-test="page-b"]')).toBeVisible();
});

test.describe("with reduced motion", () => {
  test.use({ contextOptions: { reducedMotion: "reduce" } });

  test("the swap is plain: no transition, no pause, nothing marked to play", async ({ page }) => {
    const errors = watchPageErrors(page);
    await open(page, "direction=left&img=hung");
    const result = await page.evaluate(() => new Promise((done) => {
      const started = {};
      document.addEventListener("turbo:before-render", (event) => {
        started.at = performance.now();
        started.prevented = () => event.defaultPrevented;
      }, { once: true });
      document.addEventListener("turbo:render", () => done({
        waited: performance.now() - started.at,
        attribute: document.documentElement.dataset.pageTransition ?? null,
      }), { once: true });
      document.querySelector('[data-test="other"]').click();
    }));
    expect(result.attribute).toBeNull();
    expect(result.waited, "a hung image held a reduced-motion visit").toBeLessThan(300);
    expect(await seen(page)).toEqual([]);
    await expect(page.locator('[data-test="page-b"]')).toBeVisible();
    expect(errors).toEqual([]);
  });
});

test("a browser without view transitions gets the plain swap, with no pause", async ({ page }) => {
  await page.addInitScript(() => { delete Document.prototype.startViewTransition; });
  await open(page, "direction=left&img=hung");
  const attribute = await page.evaluate(() => new Promise((done) => {
    let started;
    document.addEventListener("turbo:before-render", () => { started = performance.now(); }, { once: true });
    document.addEventListener("turbo:render", () => done({
      waited: performance.now() - started,
      attribute: document.documentElement.dataset.pageTransition ?? null,
    }), { once: true });
    document.querySelector('[data-test="other"]').click();
  }));
  expect(attribute.attribute).toBeNull();
  expect(attribute.waited).toBeLessThan(300);
  await expect(page.locator('[data-test="page-b"]')).toBeVisible();
});
