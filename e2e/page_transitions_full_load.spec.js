const { test, expect, chromium } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests, scrolledTo, navAtRest } = require("./helpers");
// The reveal waits and the log-on-red hook are shared with every host's own transition spec.
const shared = require("../lib/studio/node_tooling/e2e_helpers.js");

// [e2e] A full page load plays the app's page transition (docs/PAGE_TRANSITIONS.md, "Full page
// loads"). A log in sessionStorage outlives each document, so one spec reads both sides of a
// load: what each pseudo ran, each startViewTransition, each CSP violation. A motion that ran
// twice shows up here, and a reload's nothing does too.
const LAB = "/lab/page_transitions";
const STRICT = "direction=left&strict=1";

async function installRecorder(context) {
  await shared.watchReveal(context);
  return context.addInitScript(() => {
    const log = (line) => {
      const lines = JSON.parse(sessionStorage.getItem("pt-log") || "[]");
      lines.push(line);
      sessionStorage.setItem("pt-log", JSON.stringify(lines));
    };
    window.ptLog = log;
    // The state each side of a load was in, for the event log a red prints (afterEach below).
    // Lines start "swap-" and "reveal-", so the specs that count "page..." lines never see them.
    window.__ticks = 0;
    window.addEventListener("pageswap", (event) => {
      log(`pageswap ${event.viewTransition ? "transition" : "plain"}`);
      log(`swap-state ${JSON.stringify({
        type: event.activation ? event.activation.navigationType : null,
        to: event.activation && event.activation.entry ? new URL(event.activation.entry.url).pathname : null,
        visibility: document.visibilityState,
        revealed: !!(window.__studioReveal && window.__studioReveal.revealed),
        frames: window.__ticks,
        ready: document.readyState,
        module: !!document.documentElement.dataset.pageTransitionDirection,
      })}`);
    }, { capture: true });
    // After studio/page_transitions' own pageswap listener: the style it left for the next page.
    window.addEventListener("load", () => window.addEventListener("pageswap", () => {
      log(`swap-left ${sessionStorage.getItem("studio-page-transition-style")}`);
    }));
    window.addEventListener("pagereveal", (event) => {
      log(`pagereveal ${event.viewTransition ? "transition" : "plain"}`);
      log(`reveal-state ${JSON.stringify({ visibility: document.visibilityState, style: sessionStorage.getItem("studio-page-transition-style") })}`);
    });
    window.addEventListener("pageshow", (event) => { if (event.persisted) log("restored"); });
    document.addEventListener("securitypolicyviolation", (event) => log(`violation ${event.violatedDirective}`));
    const start = Document.prototype.startViewTransition;
    if (start) Document.prototype.startViewTransition = function (...args) { log("startViewTransition"); return start.apply(this, args); };
    const seen = new Set();
    window.__seen = seen;
    window.__frames = [];
    const tick = () => {
      window.__ticks += 1;
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
  });
}

async function open(page, query) {
  await blockOffsiteRequests(page);
  await installRecorder(page);
  await page.route("**/e2e/img/pt-hung.png", () => {});
  await page.goto(`${LAB}?${query}`);
  await page.waitForFunction((on) => window.Turbo && (!on || document.documentElement.dataset.pageTransitionDirection), query.includes("direction"));
  await page.evaluate(() => sessionStorage.removeItem("pt-log"));
}

const logged = (page) => shared.sessionLog(page, "pt-log");

// A red carries its evidence: the whole event log, printed and attached to the JSON report
// the CI uploads for every shard (shared.logOnRed).
shared.logOnRed(test, logged);
const rootMotion = (lines) => lines.filter((line) => /-(old|new)\(root\) /.test(line));

// The waits, by the lab page's test id. Why visible is not revealed, and why "nothing
// played" waits for the arrival's transition and two frames rather than a pause: the shared
// helpers' comments (lib/studio/node_tooling/e2e_helpers.js).
const pageSelector = (testId) => `[data-test="page-${testId}"]`;
const settled = (page, testId) => shared.settled(page, pageSelector(testId));
const revealed = (page, testId = "b") => shared.revealed(page, pageSelector(testId));
const arrivalSettled = (page, testId = "b") => shared.arrivalSettled(page, pageSelector(testId));
// For "nothing played": the arrival settled, then the new page's modules booted (window.Turbo,
// read on the new page because arrivalSettled found it first), then two more frames. A motion
// or a startViewTransition the arriving page's own script starts is in the log by then.
async function nothingPlayed(page, testId = "b") {
  await arrivalSettled(page, testId);
  await page.waitForFunction(() => window.Turbo);
  await shared.frames(page);
  const lines = await logged(page);
  expect(lines.filter((line) => line.startsWith("::view-transition")), `the event log:\n${lines.join("\n")}`).toEqual([]);
  // A same-document transition after the reveal draws its own pseudos only if it is not
  // skipped; the call itself is the evidence either way.
  expect(lines, "a view transition was started on a load that plays nothing").not.toContain("startViewTransition");
  return lines;
}
// Same path, or a redirect back to it: the old page carries the same test id, so wait for the
// new document's reveal in the log (open() and each step clear it) before reading the page.
// Before a full-load Back or Forward: the page is fully loaded, so its own module has run and
// is listening for pageswap. Revealed is not enough: at 8x CPU Back once left page b while it
// was still "interactive", and a page whose module has not run leaves by the plain load (the
// "click before the old page's module" test below), so the move never played.
const loaded = (page) => page.waitForFunction(() => document.readyState === "complete");
const newDocumentRevealed = (page) => page.waitForFunction(() => (sessionStorage.getItem("pt-log") || "").includes("pagereveal"));

function expectOneMotion(lines, oldName, newName) {
  expect(rootMotion(lines).sort(), `the event log:\n${lines.join("\n")}`).toEqual([
    `::view-transition-new(root) ${newName}`,
    `::view-transition-old(root) ${oldName}`,
  ]);
}

async function fullLoad(page, testId = "other-full") {
  await page.locator(`[data-test="${testId}"]`).first().click();
}

test("a full load under the enforced strict policy plays the slide, with no violation", async ({ page }) => {
  const errors = watchPageErrors(page);
  await open(page, STRICT);
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

test("a full load plays the unfold when the app sets it", async ({ page }) => {
  await open(page, `${STRICT}&style=unfold`);
  await fullLoad(page);
  await settled(page, "b");
  expectOneMotion(await logged(page), "pt-out-left", "pt-unfold-right");
});

test("each direction plays its own move across a full load", async ({ page }) => {
  await open(page, "direction=bottom&strict=1");
  await fullLoad(page);
  await settled(page, "b");
  expectOneMotion(await logged(page), "pt-out-bottom", "pt-in-from-top");
});

test("the motion outlives the new page's own turbo:load, then its marks go", async ({ page }) => {
  await blockOffsiteRequests(page);
  await installRecorder(page);
  // THE ORDER UNDER TEST, MADE CERTAIN: page b reveals, then its turbo:load, then the motion
  // ends. Left to the network, Turbo (a module) came before the reveal here, where the rule
  // this spec guards never runs, and after a short motion on one run in 290. So page b's Turbo
  // is held until page b has revealed, and its motion is paused until its turbo:load.
  let arrived = false;
  let release;
  const revealedB = new Promise((done) => { release = done; });
  await page.exposeBinding("ptArrivalRevealed", () => release());
  page.on("framenavigated", (frame) => { if (frame === page.mainFrame() && frame.url().includes("page_transitions_b")) arrived = true; });
  await page.route("**/e2e/js/turbo.min.js*", async (route) => {
    if (arrived) await revealedB;
    await route.fallback();
  });
  await page.addInitScript(() => {
    document.addEventListener("turbo:load", () => {
      setTimeout(() => window.ptLog(`after load ${document.documentElement.dataset.pageTransition}`), 0);
    });
    window.addEventListener("pagereveal", (event) => {
      if (!event.viewTransition) return;
      const paused = event.viewTransition.ready.then(() => document.getAnimations()
        .filter((a) => (a.effect?.pseudoElement || "").startsWith("::view-transition"))
        .map((a) => { a.pause(); return a; }), () => []);
      document.addEventListener("turbo:load", () => {
        paused.then((animations) => setTimeout(() => animations.forEach((a) => a.play()), 0));
      }, { once: true });
      paused.then(() => window.ptArrivalRevealed());
    });
  });
  await page.goto(`${LAB}?${STRICT}`);
  await page.waitForFunction(() => window.Turbo);
  await page.evaluate(() => sessionStorage.removeItem("pt-log"));
  await fullLoad(page);
  await settled(page, "b");
  expect(await logged(page)).toContain("after load slide-left");
  const frames = await page.evaluate(() => window.__frames);
  expect(new Set(frames.map((frame) => frame.root)).size).toBeGreaterThan(3);
  expect(await page.evaluate(() => document.documentElement.dataset.pageTransitionVisit)).toBeUndefined();
});

test("a strict page that leaves by location.assign, as Turf's does, plays once", async ({ page }) => {
  await open(page, STRICT);
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
  await open(page, "direction=left&control=reload&strict=1");
  await page.locator('[data-test="other"]').click();
  await settled(page, "b");
  const lines = await logged(page);
  expectOneMotion(lines, "pt-out-left", "pt-in-from-right");
  expect(lines.filter((line) => line.includes("vt-page-"))).toEqual([]);
  expect(lines.filter((line) => line.startsWith("violation"))).toEqual([]);
});

// turf-monster's /wallet and /account (run 42447610386): Turbo used to open its view transition
// for a response it would only reload, and the reload skipped that transition while `ready` was
// pending. Turbo awaits only `finished`, so `ready` rejected unhandled: a "Transition was
// skipped" pageerror. Holding the update callback open past Turbo's render keeps `ready`
// pending until the reload's pageswap, which makes the race certain instead of rare.
test("a Turbo visit answered by turbo-visit-control reload opens no view transition, so none is skipped", async ({ page }) => {
  const errors = watchPageErrors(page);
  await page.addInitScript(() => {
    const start = Document.prototype.startViewTransition;
    if (!start) return;
    Document.prototype.startViewTransition = function (update) {
      const held = typeof update === "function"
        ? async () => { await update(); await new Promise((done) => setTimeout(done, 1000)); }
        : update;
      return start.call(this, held);
    };
  });
  await open(page, "direction=left&control=reload&strict=1");
  await page.locator('[data-test="other"]').click();
  await settled(page, "b");
  expect(errors).toEqual([]);
  const lines = await logged(page);
  expect(lines).not.toContain("startViewTransition");
  expectOneMotion(lines, "pt-out-left", "pt-in-from-right");
});

test("a plain Turbo visit plays once, by Turbo, with no full load", async ({ page }) => {
  await open(page, "direction=left");
  const load = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.locator('[data-test="other"]').click();
  await load;
  const lines = await logged(page);
  expectOneMotion(lines, "pt-out-left", "pt-in-from-right");
  expect(lines.filter((line) => line === "startViewTransition")).toHaveLength(1);
  expect(lines.filter((line) => line.startsWith("page"))).toEqual([]);
});

test("a page that arrived by a full load then plays a Turbo visit once", async ({ page }) => {
  await open(page, "direction=left");
  await fullLoad(page);
  await settled(page, "b");
  // The motion can end before the new page's modules run. Clicked then, the link is a plain
  // full load back, not a Turbo visit (seen once in 145 runs). Module scripts run in document
  // order, and studio/page_transitions comes ahead of Turbo in the head, so Turbo means both.
  await page.waitForFunction(() => window.Turbo);
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
  await open(page, STRICT);
  await page.reload();
  await newDocumentRevealed(page);
  const lines = await nothingPlayed(page, "a");
  expect(lines).toEqual(expect.arrayContaining(["pageswap plain", "pagereveal plain"]));
  expect(await page.evaluate(() => document.documentElement.dataset.pageTransition)).toBeUndefined();
  expect(await page.locator("[data-vt-held]").evaluate((el) => getComputedStyle(el).viewTransitionName)).toBe("none");
});

test("a full load of the same path plays nothing", async ({ page }) => {
  await open(page, STRICT);
  await fullLoad(page, "same-full");
  await newDocumentRevealed(page);
  const lines = await nothingPlayed(page, "a");
  expect(lines).toContain("pageswap transition");
  expect(lines).toContain("pagereveal plain");
});

test("a redirect plays once, and a redirect back to this path plays nothing", async ({ page }) => {
  await open(page, STRICT);
  const bounce = (query) => page.evaluate((url) => window.location.assign(url), `/lab/page_transitions_redirect?${query}`);
  await bounce(STRICT);
  await settled(page, "b");
  expectOneMotion(await logged(page), "pt-out-left", "pt-in-from-right");
  await loaded(page);
  await page.evaluate(() => sessionStorage.removeItem("pt-log"));
  await bounce(STRICT);
  await newDocumentRevealed(page);
  const lines = await nothingPlayed(page, "b");
  expect(lines).toContain("pagereveal plain");
});

test("a native form's page-load overlay is not frozen into the old page's picture", async ({ page }) => {
  await open(page, `${STRICT}&overlay=1&slow=400`);
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
  await installRecorder(page);
  await page.route("**/e2e/modules/studio/page_transitions*", (route) => route.abort());
  await page.goto(`${LAB}?${STRICT}`);
  await page.waitForFunction(() => window.Turbo);
  await page.evaluate(() => sessionStorage.removeItem("pt-log"));
  await page.unroute("**/e2e/modules/studio/page_transitions*");
  await fullLoad(page);
  await arrivalSettled(page);
  await page.waitForFunction(() => window.Turbo);
  await shared.frames(page);
  const lines = await logged(page);
  expect(lines).toContain("pagereveal transition");
  expect(rootMotion(lines)).toEqual([]);
  expect(lines, "a view transition was started on a load that plays nothing").not.toContain("startViewTransition");
});

test("the stack carries its name for the motion alone, on both pages", async ({ page }) => {
  await open(page, STRICT);
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
  await open(page, STRICT);
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
  // By name too: the lab's navbar is dark on a dark page, so its pixels hide a move.
  expect((await logged(page)).some((line) => line.startsWith("::view-transition-group(studio-header)"))).toBe(true);
  // The ceiling and why it is not 0: expectChromeHoldsStill in page_transitions.spec.js.
  expect(await share(before.stack, during.stack), "the banner stack moved").toBeLessThan(0.1);
  expect(await share(before.header, during.header), "the navbar moved").toBeLessThan(0.1);
});

test("leaving a page scrolled, the stack does not slide in", async ({ page }) => {
  await open(page, STRICT);
  await scrolledTo(page, 800);
  await page.evaluate(() => document.querySelector('[data-test="other-full"]').click());
  await settled(page, "b");
  const frames = await page.evaluate(() => window.__frames);
  expect(new Set(frames.map((frame) => frame.root)).size).toBeGreaterThan(3);
  expect(new Set(frames.map((frame) => frame.stack)).size, "the stack slid in from above the viewport").toBe(1);
  expect(await logged(page)).not.toContain("::view-transition-group(studio-bar-stack) -ua-view-transition-group-anim-studio-bar-stack");
});

test("arriving scrolled by a full load, the taller old navbar does not draw under the new one", async ({ page }) => {
  await open(page, STRICT);
  await scrolledTo(page, 800);
  // The collapsed height, once the navbar has landed: read mid-ease it is neither size.
  await navAtRest(page);
  const shorter = await page.locator(".vt-pinned-header").evaluate((el) => el.offsetHeight);
  await page.evaluate(() => document.querySelector('[data-test="other-full"]').click());
  await settled(page, "b");
  const taller = await page.locator(".vt-pinned-header").evaluate((el) => el.offsetHeight);
  expect(taller, "the old navbar is not taller, so this measured nothing").toBeGreaterThan(shorter);
  await page.evaluate(() => sessionStorage.removeItem("pt-log"));
  await loaded(page);
  await page.goBack();
  await settled(page, "a");
  expect(await page.evaluate(() => window.scrollY), "Back did not arrive scrolled").toBe(800);
  expectOneMotion(await logged(page), "pt-out-right", "pt-in-from-left");
  const live = (await page.evaluate(() => window.__frames)).filter((frame) => frame.live);
  expect(live.length).toBeGreaterThan(3);
  expect(new Set(live.map((frame) => frame.oldHeader))).toEqual(new Set(["0"]));
});

test("the same arrival by a Turbo visit, Back from a scrolled page, draws one navbar", async ({ page }) => {
  await open(page, "direction=left&style=unfold");
  // Turbo keeps the position for Back from its own scroll listener: heard, not hoped for.
  await scrolledTo(page, 800);
  const leave = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.evaluate(() => document.querySelector('[data-test="other"]').click());
  await leave;
  // turbo:load fires mid-move; the frames below must be Back's alone.
  await settled(page, "b");
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
  await open(page, `${STRICT}&twice=1&morph=both`);
  await expect(page.locator(".studio-bar-stack")).toHaveCount(2);
  await fullLoad(page);
  await settled(page, "b");
  const lines = await logged(page);
  expectOneMotion(lines, "pt-out-left", "pt-in-from-right");
  expect(lines.filter((line) => line.includes("agent-portrait"))).toEqual([]);
  await expect(page.locator("[data-vt-held]")).toHaveCount(1);
});

test("Back across a full load plays the move the other way, and Forward the direction", async ({ page }) => {
  await open(page, STRICT);
  await fullLoad(page);
  await settled(page, "b");
  await page.evaluate(() => sessionStorage.removeItem("pt-log"));
  await loaded(page);
  await page.goBack();
  await settled(page, "a");
  expectOneMotion(await logged(page), "pt-out-right", "pt-in-from-left");
  await page.evaluate(() => sessionStorage.removeItem("pt-log"));
  await loaded(page);
  await page.goForward();
  await settled(page, "b");
  expectOneMotion(await logged(page), "pt-out-left", "pt-in-from-right");
});

test("an image the new page is still loading does not hold the motion", async ({ page }) => {
  await open(page, `${STRICT}&img=hung`);
  await fullLoad(page);
  await settled(page, "b");
  expectOneMotion(await logged(page), "pt-out-left", "pt-in-from-right");
  expect(await page.locator('[data-test="eager-image"]').evaluate((img) => img.complete)).toBe(false);
});

test("a slow response keeps the old page live until it answers", async ({ page }) => {
  await open(page, `${STRICT}&slow=700`);
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
  await open(page, `${STRICT}&split=500`);
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

// Timed from the hold's own start, not from navigation start: the reveal script starts the
// 3-second timer when it adds the render-blocking link, and everything before that (the
// server's answer, the head's parse) is the host's speed, not the cap. From navigation start
// a loaded Mac read 4428 ms against 4000. The link is seen by a MutationObserver, whose
// callback runs at the end of the script that added it.
test("a body slower than the cap paints at the cap, and the motion still plays", async ({ page }) => {
  await open(page, `${STRICT}&split=5000`);
  await page.addInitScript(() => window.addEventListener("pagereveal", () => {
    window.ptLog(`revealed ${!!document.querySelector('[data-test="page-b"]')}`);
  }));
  await page.addInitScript(() => new MutationObserver((records) => {
    for (const record of records) {
      for (const node of record.addedNodes) {
        if (node.nodeName === "LINK" && node.rel === "expect" && window.__holdAt === undefined) window.__holdAt = performance.now();
      }
    }
  }).observe(document, { childList: true, subtree: true }));
  await fullLoad(page);
  await page.locator('[data-test="page-b"]').waitFor({ timeout: 10000 });
  await settled(page, "b");
  const { holdAt, firstPaint } = await page.evaluate(() => ({
    holdAt: window.__holdAt,
    firstPaint: performance.getEntriesByName("first-contentful-paint")[0].startTime,
  }));
  expect(holdAt, "the reveal script never held the first render, so this measured nothing").toBeDefined();
  const paint = firstPaint - holdAt;
  expect(paint).toBeGreaterThan(2500);
  expect(paint).toBeLessThan(4000);
  const lines = await logged(page);
  expect(lines, "the body arrived before the cap, so this measured nothing").toContain("revealed false");
  expectOneMotion(lines, "pt-out-left", "pt-in-from-right");
});

test("with no direction, a full load has no sheet, no script, no at-rule and nothing acting", async ({ page }) => {
  const requests = [];
  page.on("request", (request) => requests.push(request.url()));
  await open(page, "");
  await fullLoad(page);
  const lines = await nothingPlayed(page);
  expect(lines).toEqual(expect.arrayContaining(["pageswap plain", "pagereveal plain"]));
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
  await installRecorder(page);
  await page.goto(`${LAB}?${STRICT}`);
  await page.waitForFunction(() => window.Turbo && document.documentElement.dataset.pageTransitionDirection);
  const supported = await page.evaluate(() => "onpagereveal" in window);
  await fullLoad(page);
  await expect(page.locator('[data-test="page-b"]')).toBeVisible();
  // No pagereveal here to wait on: past the load and page b's modules, then two frames.
  await page.waitForFunction(() => document.readyState === "complete" && window.Turbo);
  await shared.frames(page);
  const lines = await logged(page);
  const left = await page.evaluate(() => sessionStorage.getItem("studio-page-transition-style"));
  await browser.close();
  expect(supported, "the flag did not turn the feature off, so this measured nothing").toBe(false);
  expect(lines).toContain("pageswap plain");
  expect(lines.filter((line) => line.startsWith("::view-transition"))).toEqual([]);
  expect(lines, "a view transition was started on a load that plays nothing").not.toContain("startViewTransition");
  expect(left).toBeNull();
  expect(errors).toEqual([]);
});

test.describe("with reduced motion", () => {
  test.use({ contextOptions: { reducedMotion: "reduce" } });

  test("a full load is plain on both sides, and leaves no style behind", async ({ page }) => {
    const errors = watchPageErrors(page);
    await open(page, STRICT);
    await fullLoad(page);
    // Page b first, then its modules: a window.Turbo wait ahead of it answered on page a.
    const lines = await nothingPlayed(page);
    expect(lines).toEqual(expect.arrayContaining(["pageswap plain", "pagereveal plain"]));
    expect(await page.evaluate(() => sessionStorage.getItem("studio-page-transition-style"))).toBeNull();
    expect(errors).toEqual([]);
  });
});

test("a back link that loads the page fully plays the move the other way", async ({ page }) => {
  await open(page, STRICT);
  await fullLoad(page, "other-back-full");
  await settled(page, "b");
  expectOneMotion(await logged(page), "pt-out-right", "pt-in-from-left");
});
