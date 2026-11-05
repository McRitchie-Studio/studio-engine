const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The Tricks board, and the tricks on a real button. The markup cannot show
// any of this: whether an old knob reaches the ring, whether a lit button's own
// ::after closes the bloom's hole, and whether a bubble paints behind its button
// are all resolved values.
//
// CONTROLS, each red for its reason: a new knob that stops reading the old one in the
// .studio-team-glow rule (the alias spec); the lit ::after inset rule removed (the
// lit spec); `z-index: 1` off `.fizz-stack > :not(.fizz-layer)` (the fizz spec).

const LAB = "/lab/style_nav";

// Pseudo geometry and paint for one host. Reduced motion stops the sweep, so two
// hosts can be compared at the same angle.
const paint = (selector) => (page) =>
  page.locator(selector).evaluate((el) => {
    const read = (pseudo) => {
      const style = getComputedStyle(el, pseudo);
      return [style.backgroundImage, style.padding, style.top, style.opacity, style.filter, style.borderTopWidth];
    };
    return { before: read("::before"), after: read("::after"), position: getComputedStyle(el).position };
  });

async function stage(page, html) {
  await page.evaluate((markup) => {
    const host = document.createElement("div");
    host.id = "stage";
    host.innerHTML = markup;
    document.body.prepend(host);
  }, html);
}

test("Tricks opens with Buttons, then Button tricks", async ({ page }) => {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  await page.goto(LAB);

  const titles = await page.locator("section#tricks h3").allInnerTexts();
  expect(titles.slice(0, 3)).toEqual(["Buttons", "Button tricks", "Page header"]);

  const names = await page.locator("section#button-tricks article code[x-ref=klass]").allInnerTexts();
  expect(names).toEqual([
    expect.stringContaining(".edge-rotate-glow"),
    expect.stringContaining(".studio-border-glow"),
    expect.stringContaining(".sheen"),
    expect.stringContaining(".pulse-cta"),
    expect.stringContaining(".fizz-stack"),
    expect.stringContaining(".hold-btn"),
    expect.stringContaining(".hold-btn"),
    expect.stringContaining("burst"),
    expect.stringContaining("cannons"),
  ]);
  expect(errors).toEqual([]);
});

test("the old glow class and old knobs paint exactly as the new names do", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto(LAB);

  await stage(page, `
    <div id="new-plain" class="edge-rotate-glow bg-surface rounded-xl">a</div>
    <div id="old-plain" class="studio-team-glow bg-surface rounded-xl">a</div>
    <div id="new-knobs" class="edge-rotate-glow bg-surface rounded-xl"
         style="--edge-rotate-glow-color: rgb(255, 0, 0); --edge-rotate-glow-color-b: rgb(0, 0, 255); --edge-rotate-glow-thickness: 2px; --edge-rotate-glow-bloom: 3px; --edge-rotate-glow-opacity: 0.5">a</div>
    <div id="old-knobs" class="studio-team-glow bg-surface rounded-xl"
         style="--studio-team-glow-color: rgb(255, 0, 0); --studio-team-glow-color-b: rgb(0, 0, 255); --studio-team-glow-thickness: 2px; --studio-team-glow-bloom: 3px; --studio-team-glow-opacity: 0.5">a</div>
    <div id="moved-class" class="edge-rotate-glow bg-surface rounded-xl"
         style="--studio-team-glow-color: rgb(255, 0, 0); --studio-team-glow-color-b: rgb(0, 0, 255); --studio-team-glow-thickness: 2px; --studio-team-glow-bloom: 3px; --studio-team-glow-opacity: 0.5">a</div>
    <div id="one-old-knob" class="studio-team-glow bg-surface rounded-xl" style="--studio-team-glow-color: rgb(255, 0, 0)">a</div>
  `);

  const newPlain = await paint("#new-plain")(page);
  expect(newPlain.before[0]).toContain("conic-gradient");
  expect(newPlain.position).toBe("relative");
  expect(await paint("#old-plain")(page)).toEqual(newPlain);

  const newKnobs = await paint("#new-knobs")(page);
  expect(newKnobs.before[0]).toContain("rgb(255, 0, 0)");
  expect(newKnobs.before[0]).toContain("rgb(0, 0, 255)");
  expect(newKnobs.before[1]).toBe("2px");
  expect(newKnobs.before[3]).toBe("0.5");
  expect(await paint("#old-knobs")(page)).toEqual(newKnobs);
  expect(await paint("#moved-class")(page)).toEqual(newKnobs);

  // Setting ONLY the old color: it reaches both wedges, as it always did.
  const oneKnob = await paint("#one-old-knob")(page);
  expect(oneKnob.before[0].match(/rgb\(255, 0, 0\)/g)).toHaveLength(2);

  // An old knob set from JS and from a consumer's own class rule, the way hub and
  // Turf do it, still lands.
  await page.addStyleTag({ content: ".consumer-rule { --studio-team-glow-thickness: 7px; }" });
  await page.locator("#old-plain").evaluate((el) => {
    el.classList.add("consumer-rule");
    el.style.setProperty("--studio-team-glow-opacity", "0");
  });
  // Turf's e2e reads this computed value, so the old knob stays declared on the old class.
  expect(await page.locator("#old-plain").evaluate((el) => getComputedStyle(el).getPropertyValue("--studio-team-glow-opacity").trim())).toBe("0");
  const moved = await paint("#old-plain")(page);
  expect(moved.before[1]).toBe("7px");
  // Opacity crosses over 0.4s, as it always has.
  await expect.poll(async () => (await paint("#old-plain")(page)).before[3]).toBe("0");
});

test("fizz runs behind a plain button, and hover adds a layer", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.goto(LAB);

  const stack = page.locator("section#button-tricks .fizz-stack").first();
  const button = stack.locator("> button.btn");
  await button.scrollIntoViewIfNeeded();

  expect(await stack.evaluate((el) => getComputedStyle(el).isolation)).toBe("isolate");
  expect(await stack.locator(".fizz-layer .fizz-bit").first().evaluate((el) => getComputedStyle(el).animationName)).toBe("fizz-boil");

  // The button takes the press, and its face is on top of every bubble.
  const stacking = await button.evaluate((el) => {
    const box = el.getBoundingClientRect();
    const hit = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2);
    return { hit: hit === el, z: getComputedStyle(el).zIndex, layer: getComputedStyle(el.parentElement.querySelector(".fizz-layer")).zIndex };
  });
  expect(stacking).toEqual({ hit: true, z: "1", layer: "0" });

  // The layer sits over the button's own box, whatever its size.
  const boxes = await stack.evaluate((el) => {
    const layer = el.querySelector(".fizz-layer").getBoundingClientRect();
    const face = el.querySelector("button").getBoundingClientRect();
    return [layer.width - face.width, layer.height - face.height].map(Math.round);
  });
  expect(boxes).toEqual([0, 0]);

  const extra = stack.locator("> .fizz-layer-extra");
  await page.mouse.move(0, 0);
  await expect.poll(() => extra.evaluate((el) => getComputedStyle(el).opacity)).toBe("0");
  await button.hover();
  await expect.poll(() => extra.evaluate((el) => getComputedStyle(el).opacity)).toBe("1");

  await page.emulateMedia({ reducedMotion: "reduce" });
  expect(await stack.locator(".fizz-bit").first().evaluate((el) => getComputedStyle(el).animationName)).toBe("none");
});

test("the tricks keep a lit button lit", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto(`${LAB}?surface=glass`);

  const after = (selector, property) => page.locator(selector).first().evaluate(
    (el, name) => getComputedStyle(el, "::after")[name], property);
  const host = (selector, property) => page.locator(selector).first().evaluate(
    (el, name) => getComputedStyle(el)[name], property);

  // The bloom's box stays clear of the lit rule's inset, or its hole closes and it
  // washes the whole face: 4px ring + 4px + 2 * 10px bloom.
  const glow = "section#button-tricks button.edge-rotate-glow";
  expect(await after(glow, "top")).toBe("-28px");
  expect(await after(glow, "boxShadow")).toBe("none");
  expect(await host(glow, "boxShadow")).toContain("inset");
  expect(await after("section#button-tricks button.studio-border-glow", "top")).toBe("-46px");

  // The inset light still rides ::after on a sheen, and overflow does not cut it.
  const sheen = "section#button-tricks button.sheen";
  expect(await host(sheen, "overflow")).toBe("visible");
  expect(await after(sheen, "boxShadow")).toContain("inset");
  expect(await after(sheen, "top")).toBe("-1px");

  // A plain lit button is unchanged by any of it.
  const plain = "section#tricks button.btn-primary:not(.edge-rotate-glow, .studio-border-glow, .sheen, .pulse-cta)";
  expect(await after(plain, "top")).toBe("-1px");
  expect(await after(plain, "boxShadow")).toContain("inset");
  expect(await host(plain, "boxShadow")).not.toContain("inset");
});

test("the pulse keeps the lit shadow through its beat", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.goto(`${LAB}?surface=glass`);

  const pulse = page.locator("section#button-tricks button.pulse-cta").first();
  const shadowLayers = () => pulse.evaluate((el) => getComputedStyle(el).boxShadow.split(/,(?![^(]*\))/).length);
  // Contact, glow and the ring.
  expect(await shadowLayers()).toBe(3);
});

test("confetti fires from the button itself", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto(LAB);

  await page.evaluate(() => {
    window.__fired = [];
    window.studioConfetti = {
      burst: (el) => window.__fired.push(["burst", el.tagName]),
      cannons: () => window.__fired.push(["cannons"]),
    };
  });
  await page.locator("section#button-tricks button", { hasText: "Burst" }).click();
  await page.locator("section#button-tricks button", { hasText: "Cannons" }).click();
  expect(await page.evaluate(() => window.__fired)).toEqual([["burst", "BUTTON"], ["cannons"]]);
});

test("the hero button trials a thinner fill, and the photo shows through", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/hero_button?surface=glass");

  const trial = page.locator("[data-test=hero-trial]");
  await expect(trial).toHaveText("Launch Your Website");
  expect(await trial.evaluate((el) => getComputedStyle(el).backgroundImage)).toContain("/ 0.85");
  expect(await trial.evaluate((el) => getComputedStyle(el).backdropFilter)).toContain("blur");
  expect(await page.locator("[data-test=hero-was]").evaluate((el) => getComputedStyle(el).backgroundImage)).toContain("/ 0.94");
  expect(await page.locator("[data-test=hero-photo]").evaluate((el) => getComputedStyle(el).backgroundImage)).toContain("lab-photo");
});
