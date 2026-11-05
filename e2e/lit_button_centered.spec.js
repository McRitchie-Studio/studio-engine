const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests } = require("./helpers");

// [e2e] The lit primary is centered on the brand violet (task lit-button-centers-on-brand). The
// owner saw the hero word (text-primary) and the hero button as two purples: the old stops both
// stepped down from --color-cta and added chroma, so the button's midpoint sat about 0.1 darker
// in oklch lightness than the word. The fix steps lightness the same amount up and down with chroma
// unchanged, so the midpoint the gradient paints IS the token.
//
// What is read is paint: a screenshot of the hero button, sampled at its vertical middle in the
// padding (no label), against --color-primary as the browser resolves it. hero-solid holds alpha
// at 1, so a dark page's backdrop does not tint it; in light the trial button is solid itself.
//
// CONTROL: the old stops (l - 0.03 / l - 0.18, chroma + 0.03 / + 0.05) put the midpoint about
// 35 in sRGB units from the token on blue, and this spec reds at DELTA 12.

const DELTA = 12; // the largest per-channel sRGB difference allowed between midpoint and token

const pixels = async (page, browser, selector) => {
  const shot = await page.locator(selector).screenshot();
  const probe = await page.evaluate(() => {
    const el = document.createElement("span");
    el.style.color = "var(--color-primary)";
    document.body.append(el);
    const color = getComputedStyle(el).color;
    el.remove();
    return color;
  });
  const reader = await browser.newPage();
  const out = await reader.evaluate(async ([url, color]) => {
    const image = new Image();
    image.src = url;
    await image.decode();
    const canvas = document.createElement("canvas");
    canvas.width = image.width;
    canvas.height = image.height;
    const context = canvas.getContext("2d", { willReadFrequently: true });
    context.drawImage(image, 0, 0);
    const mid = [...context.getImageData(8, Math.floor(image.height / 2), 1, 1).data].slice(0, 3);
    context.fillStyle = color;
    context.fillRect(0, 0, 1, 1);
    const token = [...context.getImageData(0, 0, 1, 1).data].slice(0, 3);
    return { mid, token };
  }, [`data:image/png;base64,${shot.toString("base64")}`, probe]);
  await reader.close();
  return out;
};

const open = async (page, dark) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/hero_button?surface=glass");
  await page.addStyleTag({ content: "*, *::before, *::after { transition: none !important; }" });
  await page.evaluate((on) => document.documentElement.classList.toggle("dark", on), dark);
  expect(await page.evaluate(() => document.documentElement.dataset.surfaceStyle)).toBe("glass");
};

const assertCentered = ({ mid, token }) => {
  const worst = Math.max(...mid.map((v, i) => Math.abs(v - token[i])));
  expect(worst, `midpoint ${mid} vs --color-primary ${token}`).toBeLessThanOrEqual(DELTA);
};

test("the lit hero button's midpoint is --color-primary, light", async ({ page, browser }) => {
  await open(page, false);
  assertCentered(await pixels(page, browser, "[data-test=hero-trial]"));
});

test("the lit hero button's midpoint is --color-primary, dark", async ({ page, browser }) => {
  await open(page, true);
  assertCentered(await pixels(page, browser, "[data-test=hero-solid]"));
});

test("the hero word beside the button paints --color-primary", async ({ page }) => {
  await open(page, true);
  const [word, token] = await page.evaluate(() => {
    const el = document.createElement("span");
    el.style.color = "var(--color-primary)";
    document.body.append(el);
    const t = getComputedStyle(el).color;
    el.remove();
    return [getComputedStyle(document.querySelector("[data-test=hero-word]")).color, t];
  });
  expect(word).toBe(token);
});
