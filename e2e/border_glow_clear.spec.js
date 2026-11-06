const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests } = require("./helpers");

// [e2e] The clear border glow (.studio-border-glow--clear) and the style guide's specimen
// cards, on the real guide (/lab/style_nav).
//
// Alex McRitchie, 2026-11-05: "a clear background and the glowing circumference", and
// each card had two Copy buttons, with the code under the second one.
//
// CONTROLS, each run against this file with the lab server restarted:
//   - the modifier's background-color: transparent removed: the fill spec, the face
//     painted the lit violet.
//   - the reduced-motion rule removed: the reduced-motion spec, the ring still animated.
//   - the class name's Copy kept beside a snippet: the one-Copy spec, 2 on a card.
//   - the snippet back on pr-16: the clear-of-the-button spec, "Copied" over the code.

const STYLE = "/lab/style_nav";
const CLEAR = "[data-border-glow-clear]";

async function open(page) {
  await page.setViewportSize({ width: 1280, height: 900 });
  await blockOffsiteRequests(page);
  await page.goto(STYLE);
  await page.locator(CLEAR).scrollIntoViewIfNeeded();
}

// The label's colour against the face as painted: a pixel inside the left padding, so the
// page, the card and any halo under the clear face all count.
const LABEL_CONTRAST = async ({ shot, selector }) => {
  const bitmap = await createImageBitmap(await (await fetch(`data:image/png;base64,${shot}`)).blob());
  const cv = document.createElement("canvas");
  cv.width = bitmap.width;
  cv.height = bitmap.height;
  const cx = cv.getContext("2d", { willReadFrequently: true });
  cx.drawImage(bitmap, 0, 0);
  const scale = bitmap.width / window.innerWidth;
  const el = document.querySelector(selector);
  const r = el.getBoundingClientRect();
  const d = cx.getImageData(Math.round((r.left + 6) * scale), Math.round((r.top + r.height / 2) * scale), 1, 1).data;
  const face = { r: d[0], g: d[1], b: d[2] };
  const [cr, cg, cb] = getComputedStyle(el).color.match(/[\d.]+/g).map(Number);
  const lum = ({ r, g, b }) => {
    const f = (v) => (v / 255 <= 0.03928 ? v / 255 / 12.92 : Math.pow((v / 255 + 0.055) / 1.055, 2.4));
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
  };
  const [hi, lo] = [lum(face), lum({ r: cr, g: cg, b: cb })].sort((x, y) => y - x);
  return { ratio: +((hi + 0.05) / (lo + 0.05)).toFixed(2), face: `rgb(${face.r}, ${face.g}, ${face.b})` };
};

test("the clear glow has no fill, keeps its ring and halo, and its label clears 4.5:1 in every theme", async ({ page }) => {
  await open(page);
  const button = page.locator(CLEAR);
  const read = () => button.evaluate((el) => ({
    fill: getComputedStyle(el).backgroundColor,
    image: getComputedStyle(el).backgroundImage,
    ring: getComputedStyle(el, "::before").animationName,
    halo: getComputedStyle(el, "::after").animationName,
  }));

  const results = [];
  for (const glass of [false, true]) {
    for (const dark of [false, true]) {
      await page.evaluate(({ glass, dark }) => {
        document.documentElement.classList.toggle("dark", dark);
        if (glass) document.documentElement.dataset.surfaceStyle = "glass";
        else delete document.documentElement.dataset.surfaceStyle;
      }, { glass, dark });
      await page.waitForTimeout(250);
      const style = await read();
      expect(style.fill, "a clear face").toBe("rgba(0, 0, 0, 0)");
      expect(style.image).toBe("none");
      expect(style.ring).toBe("studioBorderGlowSteam");
      expect(style.halo).toBe("studioBorderGlowSteam");
      const shot = (await page.screenshot()).toString("base64");
      results.push({ glass, dark, ...(await page.evaluate(LABEL_CONTRAST, { shot, selector: CLEAR })) });
    }
  }
  console.log(JSON.stringify(results));
  expect(results.filter((r) => !(r.ratio >= 4.5)), "labels under 4.5:1").toEqual([]);
});

test("under reduced motion the glow's ring and halo stand still", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await open(page);
  const names = await page.locator(CLEAR).evaluate((el) => [
    getComputedStyle(el, "::before").animationName,
    getComputedStyle(el, "::after").animationName,
  ]);
  expect(names).toEqual(["none", "none"]);
});

test("each specimen card has one Copy, and no code line runs under it", async ({ page }) => {
  await open(page);
  const cards = await page.evaluate(() => [...document.querySelectorAll("#tricks article.card")].map((card) => {
    const copies = [...card.querySelectorAll("button")].filter((b) => /^Cop(y|ied)$/.test(b.textContent.trim()));
    const pre = card.querySelector("pre");
    let clear = null;
    if (pre && copies.length === 1) {
      // "Copied" is the wider label: measure the button wearing it.
      const button = copies[0];
      const label = button.querySelector("span");
      const was = label.textContent;
      label.textContent = "Copied";
      const box = pre.getBoundingClientRect();
      const text = box.right - parseFloat(getComputedStyle(pre).paddingRight);
      clear = Math.round(button.getBoundingClientRect().left - text);
      label.textContent = was;
    }
    return { name: card.querySelector("code")?.textContent.trim().slice(0, 40), copies: copies.length, clear };
  }));
  expect(cards.length).toBeGreaterThan(10);
  expect(cards.filter((c) => c.copies !== 1), "cards with other than one Copy").toEqual([]);
  expect(cards.filter((c) => c.clear !== null && c.clear < 0), "code lines under the Copy button").toEqual([]);
});
