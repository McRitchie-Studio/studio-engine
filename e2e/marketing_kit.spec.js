const { test, expect } = require("@playwright/test");

// The marketing kit (studio/marketing_kit/_kit, docs/SITE_FOOTER.md).
//
// WHY A BROWSER TIER EARNS ITS PLACE HERE. test/integration/marketing_kit_test.rb
// proves the markup. It cannot prove a click: the copy controller is lazy, so the
// attributes are in the server's bytes whether or not the program ever runs. Only
// a browser shows that the hex reached the clipboard, and that "Copied" is written
// after the clipboard answered, not before.

test.use({ permissions: ["clipboard-read", "clipboard-write"] });

const PAGE = "/lab/marketing_kit";
const swatch = (page, name) => page.locator("[data-test='kit-colours'] [data-studio-controller='copy-text']", { hasText: name });
const clipboard = (page) => page.evaluate(() => navigator.clipboard.readText());

test("a click on the colour's chip puts its hex on the clipboard and says so", async ({ page }) => {
  await page.goto(PAGE);
  const violet = swatch(page, "Violet");
  await expect(violet.locator("[role='status']")).toBeEmpty();

  await violet.locator(".mkit-chip").click();

  await expect(violet.locator("[role='status']")).toHaveText("Copied");
  await expect(violet.locator("[role='status']")).toBeVisible();
  expect(await clipboard(page)).toBe("#8E82FE");
  // Only the colour clicked says so.
  await expect(swatch(page, "Ink").locator("[role='status']")).toBeEmpty();
});

test("a click on the hex itself copies, and the confirmation goes away", async ({ page }) => {
  await page.goto(PAGE);
  const ink = swatch(page, "Ink");

  await ink.locator(".mkit-hex").click();

  await expect(ink.locator("[role='status']")).toHaveText("Copied");
  expect(await clipboard(page)).toBe("#1A1535");
  await expect(ink.locator("[role='status']")).toBeEmpty({ timeout: 4000 });
});

test("the keyboard copies too: the swatch is a button", async ({ page }) => {
  await page.goto(PAGE);
  const ink = swatch(page, "Ink");

  await ink.getByRole("button").focus();
  await page.keyboard.press("Enter");

  await expect(ink.locator("[role='status']")).toHaveText("Copied");
  expect(await clipboard(page)).toBe("#1A1535");
});

test("a copy the browser refuses never says Copied", async ({ page }) => {
  await page.addInitScript(() => {
    navigator.clipboard.writeText = () => Promise.reject(new Error("refused"));
    document.execCommand = () => false;
  });
  await page.goto(PAGE);
  const ink = swatch(page, "Ink");

  await ink.getByRole("button").click();

  await expect(ink.locator("[role='status']")).toHaveText("Could not copy");
});

test("with no async clipboard, as on plain http, the selection copy still reaches it", async ({ page }) => {
  await page.addInitScript(() => {
    navigator.clipboard.writeText = () => Promise.reject(new Error("no secure context"));
  });
  await page.goto(PAGE);
  const violet = swatch(page, "Violet");

  await violet.getByRole("button").click();

  await expect(violet.locator("[role='status']")).toHaveText("Copied");
  expect(await clipboard(page)).toBe("#8E82FE");
});

test("logos download by name, PNG first, and no image is broken", async ({ page }) => {
  await page.goto(PAGE);
  const logos = page.locator("[data-test='kit-logos']");

  const links = await logos.locator("a[download]").evaluateAll((all) =>
    all.map((a) => [a.textContent.trim(), a.getAttribute("href")]));
  expect(links).toEqual([
    ["Download Light", "/e2e/kit/both-light.png"],
    ["Download Dark", "/e2e/kit/both-dark.png"],
    ["Download Light", "/e2e/kit/both-light.svg"]
  ]);

  await expect(logos).not.toContainText("No files");
  const images = await logos.locator("img").evaluateAll(async (all) => {
    await Promise.all(all.map((img) => img.decode().catch(() => {})));
    return all.map((img) => [img.getAttribute("src"), img.naturalWidth > 0]);
  });
  expect(images).toEqual([
    ["/e2e/kit/both-light.svg?kit", true],
    ["/e2e/kit/both-dark.svg?kit", true],
    ["/e2e/kit/both-light.svg?kit", true]
  ]);
});

test("a click on Download Light hands the browser the file", async ({ page }) => {
  await page.goto(PAGE);

  const [download] = await Promise.all([
    page.waitForEvent("download"),
    page.locator("[data-test='kit-logos'] a[download]").first().click()
  ]);

  expect(download.suggestedFilename()).toBe("both-light.png");
});
