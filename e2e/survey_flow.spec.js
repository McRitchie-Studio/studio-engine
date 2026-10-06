const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The survey stepper (studio/surveys/show + _script), at phone width.
//
// WHY THIS IS IN THE BROWSER LANE. The server renders one plain form with every
// question in it; test/integration/survey_flow_test.rb grades that form. The
// one-question-per-screen experience — which step is showing, the progress bar,
// tap-to-advance, number keys and Enter, the autosave PATCH, focus moving to
// each question, and resuming on reload — exists only once the script has run.
// A dead script still serves a page that submits, so nothing but a browser can
// tell the stepper apart from the fallback.
//
// The survey is test/dummy/config/surveys/first_game.rb, loaded by the engine
// from the dummy's config/surveys exactly as a consuming app's would be. Each
// test gets a fresh browser context, so a fresh session and a fresh response.

const PHONE = { width: 375, height: 740 };
const SURVEY = "/surveys/first-game";

test.use({ viewport: PHONE });

function activeStep(page) {
  return page.locator("[data-survey-step].is-active");
}

async function visibleSteps(page) {
  return page.locator("[data-survey-step]:visible").count();
}

async function start(page) {
  await page.goto(SURVEY);
  await expect(page.locator("[data-studio-survey].is-enhanced")).toHaveCount(1);
  await expect(activeStep(page)).toHaveAttribute("data-key", "overall");
}

// Press a key and wait for the step it should land on (tap-advance is delayed).
async function keyTo(page, key, nextKey) {
  await page.keyboard.press(key);
  await expect(activeStep(page)).toHaveAttribute("data-key", nextKey);
}

function waitForSave(page, key) {
  return page.waitForResponse((r) => r.url().endsWith(`/answers/${key}`) && r.request().method() === "PATCH");
}

test.beforeEach(async ({ page }) => {
  await blockOffsiteRequests(page);
});

// Alex, 2026-10-05: "why don't we just start with the first question as the
// landing page. One less click." The FIRST PAINT is question 1: no intro
// screen, no Start button, no Back, and the count and bar already on 1 of 6.
test("the first paint is question 1, with no Start and no Back", async ({ page }) => {
  const errors = watchPageErrors(page);
  await page.goto(SURVEY);
  await expect(page.locator("[data-studio-survey].is-enhanced")).toHaveCount(1);

  expect(await visibleSteps(page)).toBe(1);
  await expect(activeStep(page)).toHaveAttribute("data-key", "overall");
  await expect(page.locator("[data-survey-count]")).toHaveText("Question 1 of 6");
  await expect(page.locator("[data-survey-progress]")).toHaveAttribute("aria-valuenow", "1");
  await expect(page.getByRole("button", { name: "Start" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Back" })).toBeHidden();
  await expect(page.getByRole("button", { name: "Next" })).toBeVisible();
  await expect(page.locator("[data-survey-submit]")).toBeHidden();

  // The intro is a lead line over question 1, and leaves with it.
  await expect(page.locator("[data-survey-intro]")).toBeVisible();
  await expect(page.locator("[data-survey-intro]")).toContainText("Six quick questions");
  // The title repeats question 1 here, so it stays the page's h1 for a screen
  // reader but is not painted twice: it renders in a 1px clip.
  const title = page.getByRole("heading", { level: 1, name: "How was your first game?" });
  await expect(title).toHaveCount(1);
  const titleBox = await title.boundingBox();
  expect(titleBox.width).toBeLessThanOrEqual(1);
  await expect(page.locator("#studio-survey-overall-label")).toBeVisible();

  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(overflow).toBeLessThanOrEqual(0);
  expect(errors).toEqual([]);
});

test("Next moves on one question per screen, focus follows, Back appears", async ({ page }) => {
  const errors = watchPageErrors(page);
  await start(page);
  const nextBox = await page.getByRole("button", { name: "Next" }).boundingBox();

  await page.keyboard.press("4");
  await expect(activeStep(page)).toHaveAttribute("data-key", "rules");
  expect(await visibleSteps(page)).toBe(1);
  await expect(page.locator("[data-survey-count]")).toHaveText("Question 2 of 6");
  await expect(page.locator("[data-survey-progress]")).toHaveAttribute("aria-valuenow", "2");
  // Focus moves to the question, so a screen reader announces it.
  await expect(page.locator("#studio-survey-rules-label")).toBeFocused();
  await expect(page.getByRole("button", { name: "Back" })).toBeVisible();
  await expect(page.locator("[data-survey-intro]")).toBeHidden();
  // Next holds its place whether or not Back is showing beside it.
  const movedBox = await page.getByRole("button", { name: "Next" }).boundingBox();
  expect(Math.abs(movedBox.x - nextBox.x)).toBeLessThanOrEqual(1);

  await page.getByRole("button", { name: "Back" }).click();
  await expect(activeStep(page)).toHaveAttribute("data-key", "overall");
  await expect(page.getByRole("button", { name: "Back" })).toBeHidden();
  await expect(page.locator("[data-survey-intro]")).toBeVisible();

  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(overflow).toBeLessThanOrEqual(0);
  expect(errors).toEqual([]);
});

test("a tap on a face autosaves and advances", async ({ page }) => {
  await start(page);
  const tile = page.locator("[data-key=overall] .studio-survey__tile").nth(3);
  const box = await tile.boundingBox();
  expect(box.width).toBeGreaterThanOrEqual(56);
  expect(box.height).toBeGreaterThanOrEqual(56);

  const saved = waitForSave(page, "overall");
  await tile.click();
  expect((await saved).status()).toBe(200);
  await expect(activeStep(page)).toHaveAttribute("data-key", "rules");
  await expect(page.locator("[data-survey-count]")).toHaveText("Question 2 of 6");
});

test("number keys choose and Enter continues; Back keeps the answer", async ({ page }) => {
  await start(page);

  const saved = waitForSave(page, "overall");
  await page.keyboard.press("5");
  await saved;
  await expect(activeStep(page)).toHaveAttribute("data-key", "rules");

  await page.keyboard.press("2");
  await expect(activeStep(page)).toHaveAttribute("data-key", "found_us");

  await page.getByRole("button", { name: "Back" }).click();
  await expect(activeStep(page)).toHaveAttribute("data-key", "rules");
  await expect(page.locator("[data-key=rules] input[value='2']")).toBeChecked();

  await page.keyboard.press("Enter");
  await expect(activeStep(page)).toHaveAttribute("data-key", "found_us");
});

test("a required question blocks Next with a message", async ({ page }) => {
  await start(page);
  await page.keyboard.press("Enter");

  await expect(activeStep(page)).toHaveAttribute("data-key", "overall");
  await expect(page.locator("#studio-survey-overall-error")).toHaveText("This one is required.");
});

test("the whole survey by keyboard reaches the thank-you screen", async ({ page }) => {
  const errors = watchPageErrors(page);
  await start(page);

  await page.keyboard.press("4"); // overall
  await expect(activeStep(page)).toHaveAttribute("data-key", "rules");
  await page.keyboard.press("5"); // rules
  await expect(activeStep(page)).toHaveAttribute("data-key", "found_us");
  await page.keyboard.press("2"); // found_us: a friend
  await expect(activeStep(page)).toHaveAttribute("data-key", "liked");
  await page.keyboard.press("1"); // multi: toggles, does not advance
  await page.keyboard.press("3");
  await expect(activeStep(page)).toHaveAttribute("data-key", "liked");
  await page.keyboard.press("Enter");
  await expect(activeStep(page)).toHaveAttribute("data-key", "one_word");
  await page.locator("[data-key=one_word] input").fill("Tense");
  await page.keyboard.press("Enter");
  await expect(activeStep(page)).toHaveAttribute("data-key", "anything_else");
  await expect(page.locator("[data-survey-submit]")).toBeVisible();
  await page.locator("[data-key=anything_else] textarea").fill("More maps please");
  await page.keyboard.press("Control+Enter");

  await expect(page).toHaveURL(/\/surveys\/first-game\/thanks$/);
  await expect(page.getByRole("heading", { name: "Thank you!" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Play another game" })).toBeVisible();
  expect(errors).toEqual([]);
});

test("a reload resumes at the first unanswered question", async ({ page }) => {
  await start(page);
  let saved = waitForSave(page, "overall");
  await page.keyboard.press("3");
  await saved;
  await expect(activeStep(page)).toHaveAttribute("data-key", "rules");
  saved = waitForSave(page, "rules");
  await page.keyboard.press("4");
  await saved;

  await page.reload();
  await expect(activeStep(page)).toHaveAttribute("data-key", "found_us");
  await expect(page.locator("[data-survey-status]")).toContainText("picking up where you left off");
});

test("reduced motion turns the step transition off", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await start(page);
  await keyTo(page, "4", "rules");
  const animation = await activeStep(page).evaluate((el) => getComputedStyle(el).animationName);
  expect(animation).toBe("none");
});

test("the step slides in when motion is allowed", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await start(page);
  await keyTo(page, "4", "rules");
  const animation = await activeStep(page).evaluate((el) => getComputedStyle(el).animationName);
  expect(animation).toBe("studio-survey-in-fwd");
});

test("a chosen tile is marked in the theme accent, dark and light", async ({ page }) => {
  await start(page);
  const tile = page.locator("[data-key=overall] .studio-survey__tile").nth(4);
  const other = page.locator("[data-key=overall] .studio-survey__tile").nth(0);
  await page.keyboard.press("5");
  await page.getByRole("button", { name: "Back" }).click();

  for (const mode of ["dark", "light"]) {
    if (mode === "light") await page.evaluate(() => document.documentElement.classList.remove("dark"));
    const chosen = await tile.evaluate((el) => getComputedStyle(el).borderTopColor);
    const plain = await other.evaluate((el) => getComputedStyle(el).borderTopColor);
    const accent = await page.evaluate(() => {
      const probe = document.createElement("div");
      probe.style.color = "var(--color-cta)";
      document.body.appendChild(probe);
      const value = getComputedStyle(probe).color;
      probe.remove();
      return value;
    });
    expect(chosen, `${mode}: the chosen face`).toBe(accent);
    expect(plain, `${mode}: an unchosen face`).not.toBe(accent);
  }
});

// The hint speaks to a keyboard, so it is a desktop affordance: at phone
// width and on a touch screen it never shows (Shannon's Cyvasse review).
test("the number-key hint stays off at phone width", async ({ page }) => {
  await start(page);
  const hint = page.locator("[data-survey-hint]");
  // The script did un-hide it (overall is a scale), so only the CSS can hide it.
  await expect(hint).not.toHaveAttribute("hidden", "");
  await expect(hint).toBeHidden();
});

test.describe("on a touch screen at desktop width", () => {
  test.use({ viewport: { width: 1024, height: 768 }, hasTouch: true, isMobile: true });

  test("the number-key hint stays off", async ({ page }) => {
    await start(page);
    expect(await page.evaluate(() => matchMedia("(pointer: coarse)").matches)).toBe(true);
    const hint = page.locator("[data-survey-hint]");
    await expect(hint).not.toHaveAttribute("hidden", "");
    await expect(hint).toBeHidden();
  });
});

test("the number-key hint shows on choice and scale questions only, at desktop width", async ({ page }) => {
  await page.setViewportSize({ width: 1024, height: 768 });
  await start(page);
  const hint = page.locator("[data-survey-hint]");
  await expect(hint).toBeVisible(); // overall: emoji scale
  await keyTo(page, "4", "rules");
  await keyTo(page, "5", "found_us");
  await keyTo(page, "2", "liked");
  await expect(hint).toBeVisible(); // multi choice
  await page.keyboard.press("Enter");
  await expect(activeStep(page)).toHaveAttribute("data-key", "one_word");
  await expect(hint).toBeHidden(); // short text
  await page.keyboard.press("Enter");
  await expect(activeStep(page)).toHaveAttribute("data-key", "anything_else");
  await expect(hint).toBeHidden(); // long text
  await page.getByRole("button", { name: "Back" }).click();
  await page.getByRole("button", { name: "Back" }).click();
  await expect(hint).toBeVisible();
});

test("re-tapping the chosen option leaves no flag for the next arrow key", async ({ page }) => {
  await start(page);
  await keyTo(page, "4", "rules");
  await keyTo(page, "5", "found_us");
  const chosen = page.locator("[data-key=found_us] .studio-survey__option").nth(1);
  await chosen.click(); // a tap that changes the answer advances
  await expect(activeStep(page)).toHaveAttribute("data-key", "liked");
  await page.getByRole("button", { name: "Back" }).click();
  await expect(activeStep(page)).toHaveAttribute("data-key", "found_us");

  // Tapping the option already chosen fires no change, so nothing advances...
  await chosen.click();
  await page.waitForTimeout(400);
  await expect(activeStep(page)).toHaveAttribute("data-key", "found_us");
  // ...and an arrow key then moves the choice without jumping off the question.
  await page.keyboard.press("ArrowDown");
  await expect(page.locator("[data-key=found_us] input").nth(2)).toBeChecked();
  await page.waitForTimeout(400);
  await expect(activeStep(page)).toHaveAttribute("data-key", "found_us");
});

test("an unchosen radio or checkbox ring reads at 3:1 against its card, dark and light", async ({ page }) => {
  await start(page);
  await keyTo(page, "4", "rules");
  await keyTo(page, "5", "found_us");
  const mark = page.locator("[data-key=found_us] .studio-survey__mark").first();

  for (const mode of ["dark", "light"]) {
    if (mode === "light") {
      await page.evaluate(() => document.documentElement.classList.remove("dark"));
      await page.waitForTimeout(300); // the card's background-color transition
    }
    const ratio = await mark.evaluate((el) => {
      const rgb = (c) => (c.match(/[\d.]+/g) || []).slice(0, 3).map(Number);
      const lum = ([r, g, b]) => {
        const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
        return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
      };
      const cardRgb = rgb(getComputedStyle(el.closest(".studio-survey__option")).backgroundColor);
      // A translucent ring is seen composited over the card.
      const parts = (getComputedStyle(el).borderTopColor.match(/[\d.]+/g) || []).map(Number);
      const alpha = parts.length > 3 ? parts[3] : 1;
      const ringRgb = parts.slice(0, 3).map((v, i) => v * alpha + cardRgb[i] * (1 - alpha));
      const ring = lum(ringRgb);
      const card = lum(cardRgb);
      return {
        value: (Math.max(ring, card) + 0.05) / (Math.min(ring, card) + 0.05),
        colors: `${getComputedStyle(el).borderTopColor} on ${getComputedStyle(el.closest(".studio-survey__option")).backgroundColor}`
      };
    });
    expect(ratio.value, `${mode}: ring vs card (${ratio.colors})`).toBeGreaterThanOrEqual(3);
  }
});

test.describe("without JavaScript", () => {
  test.use({ javaScriptEnabled: false });

  test("every question shows in one form that submits", async ({ page }) => {
    await page.goto(SURVEY);
    expect(await visibleSteps(page)).toBe(6); // six questions, under the title and intro
    await expect(page.getByRole("heading", { level: 1, name: "How was your first game?" })).toBeVisible();
    await expect(page.locator("[data-survey-intro]")).toBeVisible();
    await expect(page.getByRole("button", { name: "Start" })).toHaveCount(0);
    await page.locator("[data-key=overall] .studio-survey__tile").nth(2).click();
    await page.locator("[data-key=found_us] .studio-survey__option").nth(0).click();
    await page.locator("[data-survey-submit]").click();

    await expect(page).toHaveURL(/\/surveys\/first-game\/thanks$/);
    await expect(page.getByRole("heading", { name: "Thank you!" })).toBeVisible();
  });
});

test("the admin results panel lays out at phone width", async ({ page }) => {
  const errors = watchPageErrors(page);
  await page.goto("/survey_lab/sign_in?to=/admin/surveys");
  await expect(page.locator("[data-admin-survey-row='first-game']")).toBeVisible();

  await page.goto("/admin/surveys/first-game");
  await expect(page.locator("[data-survey-question='overall']")).toBeVisible();
  await expect(page.getByRole("link", { name: "Export CSV" })).toBeVisible();
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(overflow).toBeLessThanOrEqual(0);
  expect(errors).toEqual([]);
});

// Turbo restores the page on Back from its snapshot cache: a CLONE of the DOM,
// which keeps every attribute the stepper wrote but none of its listeners. The
// stepper must come alive again on that clone. Before the fix a data-enhanced
// marker survived into the clone, setup returned early, and Next did nothing.
test("the stepper still works after Turbo restores it on Back", async ({ page, context, baseURL }) => {
  const errors = watchPageErrors(page);
  await context.addCookies([{ name: "survey_lab_turbo", value: "1", url: baseURL }]);
  await start(page);
  await page.locator("[data-key=overall] .studio-survey__tile").nth(3).click();
  await expect(activeStep(page)).toHaveAttribute("data-key", "rules");

  // NOT VACUOUS: a marker on window survives a Turbo visit and dies with a full
  // page load, so this proves Back was a Turbo restore and not a reload.
  await page.evaluate(() => { window.__sameDocument = true; });
  await page.locator("[data-survey-lab-away]").click();
  await expect(page.locator("[data-lab-page='terms']")).toBeVisible();
  await page.goBack();
  await expect(page.locator("[data-studio-survey]")).toBeVisible();
  expect(await page.evaluate(() => window.__sameDocument)).toBe(true);

  // The restored clone comes back on the step it was left on, and every
  // control is live: Next advances, Back returns, a tap advances.
  await expect(activeStep(page)).toHaveAttribute("data-key", "rules");
  await page.locator("[data-key=rules] .studio-survey__tile").nth(4).click();
  await expect(activeStep(page)).not.toHaveAttribute("data-key", "rules");
  const after = await activeStep(page).getAttribute("data-key");
  await page.getByRole("button", { name: "Back" }).click();
  await expect(activeStep(page)).toHaveAttribute("data-key", "rules");
  await page.getByRole("button", { name: "Next" }).click();
  await expect(activeStep(page)).toHaveAttribute("data-key", after);
  expect(errors).toEqual([]);
});
