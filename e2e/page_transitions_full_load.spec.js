const { test, expect, chromium } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] A full page load plays the app's page transition (docs/PAGE_TRANSITIONS.md, "Full page
// loads"). A log in sessionStorage outlives each document, so one spec reads both sides of a
// load: what each pseudo ran, each startViewTransition, each CSP violation. A motion that ran
// twice shows up here, and a reload's nothing does too.
const LAB = "/lab/page_transitions";
const STRICT = "direction=left&strict=1";

function installRecorder(context, randomValue = 0) {
  return context.addInitScript((value) => {
    const log = (line) => {
      const lines = JSON.parse(sessionStorage.getItem("pt-log") || "[]");
      lines.push(line);
      sessionStorage.setItem("pt-log", JSON.stringify(lines));
    };
    window.ptLog = log;
    window.__random = value;
    // Only for the pick: Turbo draws its history ids from Math.random too.
    const fixPick = () => {
      const real = Math.random;
      Math.random = () => window.__random;
      setTimeout(() => { Math.random = real; }, 0);
    };
    window.addEventListener("pageswap", (event) => {
      fixPick();
      log(`pageswap ${event.viewTransition ? "transition" : "plain"}`);
    }, { capture: true });
    document.addEventListener("turbo:before-render", fixPick, { capture: true });
    window.addEventListener("pagereveal", (event) => log(`pagereveal ${event.viewTransition ? "transition" : "plain"}`));
    window.addEventListener("pageshow", (event) => { if (event.persisted) log("restored"); });
    document.addEventListener("securitypolicyviolation", (event) => log(`violation ${event.violatedDirective}`));
    const start = Document.prototype.startViewTransition;
    if (start) Document.prototype.startViewTransition = function (...args) { log("startViewTransition"); return start.apply(this, args); };
    const seen = new Set();
    window.__seen = seen;
    window.__frames = [];
    const tick = () => {
      for (const animation of document.getAnimations()) {
        const pseudo = animation.effect && animation.effect.pseudoElement;
        if (!pseudo || !pseudo.startsWith("::view-transition")) continue;
        const key = `${pseudo} ${animation.animationName || ""}`;
        if (!seen.has(key)) { seen.add(key); log(key); }
      }
      if (document.documentElement.hasAttribute("data-page-transition")) {
        const read = (pseudo) => getComputedStyle(document.documentElement, pseudo).transform;
        window.__frames.push({
          root: read("::view-transition-old(root)"),
          stack: read("::view-transition-group(studio-bar-stack)"),
          oldHeader: getComputedStyle(document.documentElement, "::view-transition-old(studio-header)").opacity,
          live: document.documentElement.dataset.pageTransition !== "still"
            && document.getAnimations().some((a) => (a.effect?.pseudoElement || "").startsWith("::view-transition-old(root)")),
        });
      }
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }, randomValue);
}

async function open(page, query, randomValue) {
  await blockOffsiteRequests(page);
  await installRecorder(page, randomValue);
  await page.route("**/e2e/img/pt-hung.png", () => {});
  await page.goto(`${LAB}?${query}`);
  await page.waitForFunction((on) => window.Turbo && (!on || document.documentElement.dataset.pageTransitionDirection), query.includes("direction"));
  await page.evaluate(() => sessionStorage.removeItem("pt-log"));
}

const logged = (page) => page.evaluate(() => JSON.parse(sessionStorage.getItem("pt-log") || "[]"));
const rootMotion = (lines) => lines.filter((line) => /-(old|new)\(root\) /.test(line));

// Past the whole motion: the document's own marks are gone when this returns.
async function settled(page, testId) {
  await expect(page.locator(`[data-test="page-${testId}"]`)).toBeVisible();
  await page.waitForFunction(() => document.documentElement.dataset.pageTransition === undefined
    && !document.getAnimations().some((a) => (a.effect?.pseudoElement || "").startsWith("::view-transition")));
}

function expectOneMotion(lines, oldName, newName) {
  expect(rootMotion(lines).sort()).toEqual([
    `::view-transition-new(root) ${newName}`,
    `::view-transition-old(root) ${oldName}`,
  ]);
}

async function fullLoad(page, testId = "other-full") {
  await page.locator(`[data-test="${testId}"]`).first().click();
}

test("a full load under the enforced strict policy plays the fade, with no violation", async ({ page }) => {
  const errors = watchPageErrors(page);
  await open(page, STRICT, 0);
  await fullLoad(page);
  await settled(page, "b");
  const lines = await logged(page);
  expectOneMotion(lines, "pt-out-left", "pt-in-from-right");
  expect(lines.filter((line) => line.startsWith("violation"))).toEqual([]);
  expect(lines).not.toContain("startViewTransition");
  expect(errors).toEqual([]);

  // The control: the policy is live, and it does refuse a script with no nonce.
  await page.evaluate(() => {
    const script = document.createElement("script");
    script.textContent = "window.__ran = true";
    document.head.appendChild(script);
  });
  expect(await page.evaluate(() => window.__ran)).toBeUndefined();
  await expect.poll(async () => (await logged(page)).filter((line) => line.startsWith("violation"))).toEqual(["violation script-src-elem"]);
});

test("a full load can draw the unfold too", async ({ page }) => {
  await open(page, STRICT, 0.99);
  await fullLoad(page);
  await settled(page, "b");
  expectOneMotion(await logged(page), "pt-out-left", "pt-unfold-right");
});

test("each direction plays its own move across a full load", async ({ page }) => {
  await open(page, "direction=bottom&strict=1", 0);
  await fullLoad(page);
  await settled(page, "b");
  expectOneMotion(await logged(page), "pt-out-bottom", "pt-in-from-top");
});

test("the motion outlives the new page's own turbo:load, then its marks go", async ({ page }) => {
  await blockOffsiteRequests(page);
  await installRecorder(page, 0);
  await page.addInitScript(() => document.addEventListener("turbo:load", () => {
    setTimeout(() => window.ptLog(`after load ${document.documentElement.dataset.pageTransition}`), 0);
  }));
  await page.goto(`${LAB}?${STRICT}`);
  await page.waitForFunction(() => window.Turbo);
  await page.evaluate(() => sessionStorage.removeItem("pt-log"));
  await fullLoad(page);
  await settled(page, "b");
  expect(await logged(page)).toContain("after load fade-left");
  const frames = await page.evaluate(() => window.__frames);
  expect(new Set(frames.map((frame) => frame.root)).size).toBeGreaterThan(3);
  expect(await page.evaluate(() => document.documentElement.dataset.pageTransitionVisit)).toBeUndefined();
});

test("a strict page that leaves by location.assign, as Turf's does, plays once", async ({ page }) => {
  await open(page, STRICT, 0);
  await page.evaluate(() => document.addEventListener("turbo:before-visit", (event) => {
    event.preventDefault();
    window.location.assign(event.detail.url);
  }));
  await fullLoad(page, "other");
  await settled(page, "b");
  const lines = await logged(page);
  expectOneMotion(lines, "pt-out-left", "pt-in-from-right");
  expect(lines).not.toContain("startViewTransition");
});

test("a Turbo visit answered by turbo-visit-control reload plays once", async ({ page }) => {
  await open(page, "direction=left&control=reload&strict=1", 0);
  await page.locator('[data-test="other"]').click();
  await settled(page, "b");
  const lines = await logged(page);
  expectOneMotion(lines, "pt-out-left", "pt-in-from-right");
  expect(lines.filter((line) => line.includes("vt-page-"))).toEqual([]);
  expect(lines.filter((line) => line.startsWith("violation"))).toEqual([]);
});

test("a plain Turbo visit plays once, by Turbo, with no full load", async ({ page }) => {
  await open(page, "direction=left", 0);
  const load = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.locator('[data-test="other"]').click();
  await load;
  const lines = await logged(page);
  expectOneMotion(lines, "pt-out-left", "pt-in-from-right");
  expect(lines.filter((line) => line === "startViewTransition")).toHaveLength(1);
  expect(lines.filter((line) => line.startsWith("page"))).toEqual([]);
});

test("a page that arrived by a full load then plays a Turbo visit once", async ({ page }) => {
  await open(page, "direction=left", 0);
  await fullLoad(page);
  await settled(page, "b");
  await page.evaluate(() => { window.__seen.clear(); sessionStorage.removeItem("pt-log"); });
  const load = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.locator('[data-test="other"]').click();
  await load;
  const lines = await logged(page);
  expectOneMotion(lines, "pt-out-left", "pt-in-from-right");
  expect(lines.filter((line) => line === "startViewTransition")).toHaveLength(1);
  expect(lines.filter((line) => line.startsWith("page"))).toEqual([]);
});

test("a reload plays nothing and leaves no name", async ({ page }) => {
  await open(page, STRICT, 0);
  await page.reload();
  await page.waitForFunction(() => window.Turbo && document.documentElement.dataset.pageTransitionDirection);
  await page.waitForTimeout(200);
  const lines = await logged(page);
  expect(lines).toEqual(expect.arrayContaining(["pageswap plain", "pagereveal plain"]));
  expect(lines.filter((line) => line.startsWith("::view-transition"))).toEqual([]);
  expect(await page.evaluate(() => document.documentElement.dataset.pageTransition)).toBeUndefined();
  expect(await page.locator("[data-vt-held]").evaluate((el) => getComputedStyle(el).viewTransitionName)).toBe("none");
});

test("a full load of the same path plays nothing", async ({ page }) => {
  await open(page, STRICT, 0);
  await fullLoad(page, "same-full");
  await page.waitForFunction(() => window.Turbo && document.documentElement.dataset.pageTransitionDirection);
  await page.waitForTimeout(200);
  const lines = await logged(page);
  expect(lines).toContain("pageswap transition");
  expect(lines).toContain("pagereveal plain");
  expect(lines.filter((line) => line.startsWith("::view-transition"))).toEqual([]);
});

test("a redirect plays once, and a redirect back to this path plays nothing", async ({ page }) => {
  await open(page, STRICT, 0);
  const bounce = (query) => page.evaluate((url) => window.location.assign(url), `/lab/page_transitions_redirect?${query}`);
  await bounce(STRICT);
  await settled(page, "b");
  expectOneMotion(await logged(page), "pt-out-left", "pt-in-from-right");
  await page.waitForFunction(() => window.Turbo && document.documentElement.dataset.pageTransitionDirection);
  await page.evaluate(() => sessionStorage.removeItem("pt-log"));
  await bounce(STRICT);
  await page.waitForFunction(() => sessionStorage.getItem("pt-log")?.includes("pagereveal"));
  const lines = await logged(page);
  expect(lines).toContain("pagereveal plain");
  expect(lines.filter((line) => line.startsWith("::view-transition"))).toEqual([]);
});

test("a native form's page-load overlay is not frozen into the old page's picture", async ({ page }) => {
  await open(page, `${STRICT}&overlay=1&slow=400`, 0);
  await page.evaluate(() => window.addEventListener("pageswap", () => {
    window.ptLog(`overlay hidden ${document.querySelector("[data-studio-loader-overlay]").hidden}`);
  }));
  await page.evaluate((action) => {
    const form = document.createElement("form");
    form.method = "get";
    form.action = action;
    form.dataset.turbo = "false";
    form.setAttribute("data-studio-loader-overlay", "");
    for (const [name, value] of new URLSearchParams(window.location.search)) {
      const input = document.createElement("input");
      Object.assign(input, { type: "hidden", name, value });
      form.appendChild(input);
    }
    document.body.appendChild(form);
    form.requestSubmit();
    // The control: the overlay is up while the page waits, so the line below measures something.
    setTimeout(() => window.ptLog(`overlay waited hidden ${document.querySelector("[data-studio-loader-overlay]").hidden}`), 200);
  }, "/lab/page_transitions_b");
  await settled(page, "b");
  const lines = await logged(page);
  expect(lines).toContain("overlay waited hidden false");
  expect(lines).toContain("overlay hidden true");
  expectOneMotion(lines, "pt-out-left", "pt-in-from-right");
});

test("a click before the old page's module has run gets the plain load, not the browser's fade", async ({ page }) => {
  await blockOffsiteRequests(page);
  await installRecorder(page, 0);
  await page.route("**/e2e/modules/studio/page_transitions*", (route) => route.abort());
  await page.goto(`${LAB}?${STRICT}`);
  await page.waitForFunction(() => window.Turbo);
  await page.evaluate(() => sessionStorage.removeItem("pt-log"));
  await page.unroute("**/e2e/modules/studio/page_transitions*");
  await fullLoad(page);
  await expect(page.locator('[data-test="page-b"]')).toBeVisible();
  await page.waitForTimeout(300);
  const lines = await logged(page);
  expect(lines).toContain("pagereveal transition");
  expect(rootMotion(lines)).toEqual([]);
});

test("the stack carries its name for the motion alone, on both pages", async ({ page }) => {
  await open(page, STRICT, 0);
  const stackName = () => page.locator("[data-vt-held]").evaluate((el) => getComputedStyle(el).viewTransitionName);
  expect(await stackName()).toBe("none");
  // Bound after the module's own listener, so this reads what the old page's picture reads.
  await page.evaluate(() => window.addEventListener("pageswap", () => {
    window.ptLog(`old ${getComputedStyle(document.querySelector("[data-vt-held]")).viewTransitionName}`);
  }));
  await page.addInitScript(() => window.addEventListener("pagereveal", (event) => {
    event.viewTransition?.ready.then(() => {
      window.ptLog(`new ${getComputedStyle(document.querySelector("[data-vt-held]")).viewTransitionName}`);
    });
  }));
  await fullLoad(page);
  await settled(page, "b");
  expect(await logged(page)).toEqual(expect.arrayContaining(["old studio-bar-stack", "new studio-bar-stack"]));
  expect(await stackName()).toBe("none");
});

test("the navbar and the banner stack hold still across a full load", async ({ page }) => {
  await open(page, STRICT, 0);
  const stackBox = await page.locator("[data-vt-held]").boundingBox();
  const headerBox = await page.locator(".vt-pinned-header").boundingBox();
  await page.evaluate(() => { document.documentElement.dataset.pageTransitionVisit = ""; });
  await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
  const before = { stack: await page.screenshot({ clip: stackBox }), header: await page.screenshot({ clip: headerBox }) };
  await page.addInitScript(() => window.addEventListener("pagereveal", (event) => {
    event.viewTransition?.ready.then(() => {
      for (const animation of document.getAnimations()) {
        if ((animation.effect?.pseudoElement || "").startsWith("::view-transition")) { animation.pause(); animation.currentTime = 280; }
      }
      window.__paused = true;
    });
  }));
  await fullLoad(page);
  await page.waitForFunction(() => window.__paused);
  const moved = await page.evaluate(() => getComputedStyle(document.documentElement, "::view-transition-old(root)").transform);
  expect(moved, "the page never moved, so this measured nothing").not.toBe("none");
  const during = { stack: await page.screenshot({ clip: stackBox }), header: await page.screenshot({ clip: headerBox }) };
  await page.evaluate(() => document.getAnimations().forEach((a) => {
    if ((a.effect?.pseudoElement || "").startsWith("::view-transition")) a.finish();
  }));
  await settled(page, "b");
  // In a page of its own: the strict policy refuses this data: fetch.
  const probe = await page.context().newPage();
  const share = (a, b) => probe.evaluate(async ([one, two]) => {
    const read = async (encoded) => {
      const bitmap = await createImageBitmap(await (await fetch(`data:image/png;base64,${encoded}`)).blob());
      const canvas = new OffscreenCanvas(Math.ceil(bitmap.width / 4), Math.ceil(bitmap.height / 4));
      const context = canvas.getContext("2d");
      context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
      return context.getImageData(0, 0, canvas.width, canvas.height).data;
    };
    const [left, right] = [await read(one), await read(two)];
    let changed = 0;
    for (let i = 0; i < left.length; i += 4) {
      if (Math.abs(left[i] - right[i]) + Math.abs(left[i + 1] - right[i + 1]) + Math.abs(left[i + 2] - right[i + 2]) > 24) changed += 1;
    }
    return changed / (left.length / 4);
  }, [a.toString("base64"), b.toString("base64")]);
  // By name too: the lab's navbar is dark on a black backdrop, so its pixels hide a move.
  expect((await logged(page)).some((line) => line.startsWith("::view-transition-group(studio-header)"))).toBe(true);
  // The ceiling and why it is not 0: expectChromeHoldsStill in page_transitions.spec.js.
  expect(await share(before.stack, during.stack), "the banner stack moved").toBeLessThan(0.1);
  expect(await share(before.header, during.header), "the navbar moved").toBeLessThan(0.1);
});

test("leaving a page scrolled, the stack does not slide in", async ({ page }) => {
  await open(page, STRICT, 0);
  await page.evaluate(() => window.scrollTo(0, 800));
  await page.waitForTimeout(100);
  await page.evaluate(() => document.querySelector('[data-test="other-full"]').click());
  await settled(page, "b");
  const frames = await page.evaluate(() => window.__frames);
  expect(new Set(frames.map((frame) => frame.root)).size).toBeGreaterThan(3);
  expect(new Set(frames.map((frame) => frame.stack)).size, "the stack slid in from above the viewport").toBe(1);
  expect(await logged(page)).not.toContain("::view-transition-group(studio-bar-stack) -ua-view-transition-group-anim-studio-bar-stack");
});

test("arriving scrolled by a full load, the taller old navbar does not draw under the new one", async ({ page }) => {
  await open(page, STRICT, 0);
  await page.evaluate(() => window.scrollTo(0, 800));
  await page.waitForTimeout(200);
  const shorter = await page.locator(".vt-pinned-header").evaluate((el) => el.offsetHeight);
  await page.evaluate(() => document.querySelector('[data-test="other-full"]').click());
  await settled(page, "b");
  const taller = await page.locator(".vt-pinned-header").evaluate((el) => el.offsetHeight);
  expect(taller, "the old navbar is not taller, so this measured nothing").toBeGreaterThan(shorter);
  await page.evaluate(() => sessionStorage.removeItem("pt-log"));
  await page.goBack();
  await settled(page, "a");
  expect(await page.evaluate(() => window.scrollY), "Back did not arrive scrolled").toBe(800);
  expectOneMotion(await logged(page), "pt-out-left", "pt-in-from-right");
  const live = (await page.evaluate(() => window.__frames)).filter((frame) => frame.live);
  expect(live.length).toBeGreaterThan(3);
  expect(new Set(live.map((frame) => frame.oldHeader))).toEqual(new Set(["0"]));
});

test("the same arrival by a Turbo visit, Back from a scrolled page, draws one navbar", async ({ page }) => {
  await open(page, "direction=left", 0.99);
  await page.evaluate(() => window.scrollTo(0, 800));
  await page.waitForTimeout(200);
  const leave = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.evaluate(() => document.querySelector('[data-test="other"]').click());
  await leave;
  await page.waitForTimeout(200);
  await page.evaluate(() => { window.__frames.length = 0; });
  const back = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.goBack();
  await back;
  expect(await page.evaluate(() => window.scrollY), "Back did not arrive scrolled").toBe(800);
  const live = (await page.evaluate(() => window.__frames)).filter((frame) => frame.live);
  expect(live.length).toBeGreaterThan(3);
  expect(new Set(live.map((frame) => frame.oldHeader))).toEqual(new Set(["0"]));
});

test("two stacks and a chat head on both pages: one name each, so the direction still plays", async ({ page }) => {
  await open(page, `${STRICT}&twice=1&morph=both`, 0);
  await expect(page.locator(".studio-bar-stack")).toHaveCount(2);
  await fullLoad(page);
  await settled(page, "b");
  const lines = await logged(page);
  expectOneMotion(lines, "pt-out-left", "pt-in-from-right");
  expect(lines.filter((line) => line.includes("agent-portrait"))).toEqual([]);
  await expect(page.locator("[data-vt-held]")).toHaveCount(1);
});

test("Back and Forward across a full load, as fresh documents, each play the direction", async ({ page }) => {
  await open(page, STRICT, 0);
  await fullLoad(page);
  await settled(page, "b");
  await page.evaluate(() => sessionStorage.removeItem("pt-log"));
  await page.goBack();
  await settled(page, "a");
  expectOneMotion(await logged(page), "pt-out-left", "pt-in-from-right");
  await page.evaluate(() => sessionStorage.removeItem("pt-log"));
  await page.goForward();
  await settled(page, "b");
  expectOneMotion(await logged(page), "pt-out-left", "pt-in-from-right");
});

test("an image the new page is still loading does not hold the motion", async ({ page }) => {
  await open(page, `${STRICT}&img=hung`, 0);
  await fullLoad(page);
  await settled(page, "b");
  expectOneMotion(await logged(page), "pt-out-left", "pt-in-from-right");
  expect(await page.locator('[data-test="eager-image"]').evaluate((img) => img.complete)).toBe(false);
});

test("a slow response keeps the old page live until it answers", async ({ page }) => {
  await open(page, `${STRICT}&slow=700`, 0);
  // Not locator.click: Playwright would wait for the commit, and this reads the time before it.
  await page.evaluate(() => {
    setInterval(() => window.ptLog("old page ran"), 50);
    document.querySelector('[data-test="other-full"]').click();
  });
  await settled(page, "b");
  const lines = await logged(page);
  expect(lines.filter((line) => line === "old page ran").length).toBeGreaterThan(5);
  expectOneMotion(lines, "pt-out-left", "pt-in-from-right");
});

test("a body that arrives in two chunks is whole before the new page's picture", async ({ page }) => {
  await open(page, `${STRICT}&split=500`, 0);
  await page.addInitScript(() => window.addEventListener("pagereveal", () => {
    window.ptLog(`revealed ${!!document.querySelector(".studio-bar-stack")} ${!!document.querySelector('[data-test="page-b"]')}`);
  }));
  await fullLoad(page);
  await settled(page, "b");
  const lines = await logged(page);
  expect(lines).toContain("revealed true true");
  expectOneMotion(lines, "pt-out-left", "pt-in-from-right");
  expect(lines.filter((line) => line.includes("studio-header") && /-(old|new)\(/.test(line))).toEqual([]);
});

test("a body slower than the cap paints at the cap, and the motion still plays", async ({ page }) => {
  await open(page, `${STRICT}&split=5000`, 0);
  await page.addInitScript(() => window.addEventListener("pagereveal", () => {
    window.ptLog(`revealed ${!!document.querySelector('[data-test="page-b"]')}`);
  }));
  await fullLoad(page);
  await page.locator('[data-test="page-b"]').waitFor({ timeout: 10000 });
  await settled(page, "b");
  const paint = await page.evaluate(() => performance.getEntriesByName("first-contentful-paint")[0].startTime);
  expect(paint).toBeGreaterThan(2500);
  expect(paint).toBeLessThan(4000);
  const lines = await logged(page);
  expect(lines, "the body arrived before the cap, so this measured nothing").toContain("revealed false");
  expectOneMotion(lines, "pt-out-left", "pt-in-from-right");
});

test("with no direction, a full load has no sheet, no script, no at-rule and nothing acting", async ({ page }) => {
  const requests = [];
  page.on("request", (request) => requests.push(request.url()));
  await open(page, "", 0);
  await fullLoad(page);
  await expect(page.locator('[data-test="page-b"]')).toBeVisible();
  const lines = await logged(page);
  expect(lines).toEqual(expect.arrayContaining(["pageswap plain", "pagereveal plain"]));
  expect(lines.filter((line) => line.startsWith("::view-transition"))).toEqual([]);
  expect(requests.filter((url) => /studio\/page_transition/.test(url))).toEqual([]);
  const viewTransitionRules = () => page.evaluate(() => {
    const count = (rules) => [...rules].reduce((sum, rule) => sum + (rule.constructor.name === "CSSViewTransitionRule" ? 1 : 0) + (rule.cssRules ? count(rule.cssRules) : 0), 0);
    return [...document.styleSheets].reduce((sum, sheet) => sum + count(sheet.cssRules), 0);
  });
  expect(await viewTransitionRules()).toBe(0);
  expect(await page.evaluate(() => sessionStorage.getItem("studio-page-transition-style"))).toBeNull();

  // The control: this reader finds the rule when the setting is on.
  await page.goto(`${LAB}?direction=left`);
  await page.waitForFunction(() => window.Turbo);
  expect(await viewTransitionRules()).toBe(1);
});

test("a browser without cross-document view transitions loads plainly and throws nothing", async ({ baseURL }) => {
  const browser = await chromium.launch({ args: ["--disable-blink-features=PageRevealEvent"] });
  const page = await (await browser.newContext({ baseURL })).newPage();
  const errors = watchPageErrors(page);
  await installRecorder(page, 0);
  await page.goto(`${LAB}?${STRICT}`);
  await page.waitForFunction(() => window.Turbo && document.documentElement.dataset.pageTransitionDirection);
  const supported = await page.evaluate(() => "onpagereveal" in window);
  await fullLoad(page);
  await expect(page.locator('[data-test="page-b"]')).toBeVisible();
  await page.waitForTimeout(200);
  const lines = await logged(page);
  const left = await page.evaluate(() => sessionStorage.getItem("studio-page-transition-style"));
  await browser.close();
  expect(supported, "the flag did not turn the feature off, so this measured nothing").toBe(false);
  expect(lines).toContain("pageswap plain");
  expect(lines.filter((line) => line.startsWith("::view-transition"))).toEqual([]);
  expect(left).toBeNull();
  expect(errors).toEqual([]);
});

test.describe("with reduced motion", () => {
  test.use({ contextOptions: { reducedMotion: "reduce" } });

  test("a full load is plain on both sides, and leaves no style behind", async ({ page }) => {
    const errors = watchPageErrors(page);
    await open(page, STRICT, 0);
    await fullLoad(page);
    await expect(page.locator('[data-test="page-b"]')).toBeVisible();
    await page.waitForTimeout(200);
    const lines = await logged(page);
    expect(lines).toEqual(expect.arrayContaining(["pageswap plain", "pagereveal plain"]));
    expect(lines.filter((line) => line.startsWith("::view-transition"))).toEqual([]);
    expect(await page.evaluate(() => sessionStorage.getItem("studio-page-transition-style"))).toBeNull();
    expect(errors).toEqual([]);
  });
});
