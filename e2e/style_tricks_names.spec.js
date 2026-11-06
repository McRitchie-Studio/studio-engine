const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The style guide's cards carry trick names, not markup snippets (task
// tricks-named-not-snippets). Alex McRitchie, 2026-11-06: "the HTML isn't real helpful
// since agents can get that information from other places. I really just need to have a
// good naming convention so I can convey an idea to my agents."
//
// What only a browser shows: that the name is the heading a person reads first, that
// no snippet box is left on the board, and that Copy really puts the agent line on the
// clipboard (an Alpine handler reading the button's own data, after a click).
//
// CONTROLS, each run 2026-11-06 and red for its reason: a <pre> put back in every
// card's label (the no-pre spec: 58 found); Copy wired to the token's own text, as the
// old card copied its class (the clipboard spec: received ".sheen", not the agent line).

const LAB = "/lab/style_nav";

test.use({ permissions: ["clipboard-read", "clipboard-write"] });

test("Tricks cards show their names as headings and no snippet boxes", async ({ page }) => {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.goto(LAB);

  const cards = page.locator("#tricks article.card");
  expect(await cards.count()).toBeGreaterThan(20);
  await expect(page.locator("#tricks pre, #loaders pre")).toHaveCount(0);

  const sheen = page.locator("#tricks article[data-trick='sheen']");
  await sheen.scrollIntoViewIfNeeded();
  const read = await sheen.evaluate((card) => {
    const name = card.querySelector("[data-trick-name]");
    const token = card.querySelector("[data-trick-token]");
    return {
      name: name.textContent.trim(),
      nameSize: parseFloat(getComputedStyle(name).fontSize),
      tokenSize: parseFloat(getComputedStyle(token).fontSize),
      nameAboveToken: name.getBoundingClientRect().bottom <= token.getBoundingClientRect().top,
    };
  });
  expect(read.name).toBe("Sheen");
  expect(read.nameSize, "the name reads larger than the token").toBeGreaterThan(read.tokenSize);
  expect(read.nameAboveToken).toBe(true);
  expect(errors).toEqual([]);
});

test("Copy puts the agent line on the clipboard", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto(LAB);

  const card = page.locator("#tricks article[data-trick='sheen']");
  await card.scrollIntoViewIfNeeded();
  const copy = card.getByRole("button", { name: "Copy the name for an agent" });
  await copy.click();
  await expect(copy).toHaveText("Copied");
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe("Sheen — .sheen; Sheen · loop — .sheen--loop");

  const variant = page.locator("#tricks article[data-trick='loader'][data-trick-variant='orbit']");
  await variant.scrollIntoViewIfNeeded();
  await variant.getByRole("button", { name: "Copy the name for an agent" }).click();
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe("Loader · orbit — config.loader = :orbit");
});
