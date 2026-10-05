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
  await page.getByRole("button", { name: "Start" }).click();
  await expect(activeStep(page)).toHaveAttribute("data-key", "overall");
}

function waitForSave(page, key) {
  return page.waitForResponse((r) => r.url().endsWith(`/answers/${key}`) && r.request().method() === "PATCH");
}

test.beforeEach(async ({ page }) => {
  await blockOffsiteRequests(page);
});

test("shows the intro, then exactly one question per screen with progress", async ({ page }) => {
  const errors = watchPageErrors(page);
  await page.goto(SURVEY);

  await expect(page.getByRole("heading", { name: "How was your first game?" })).toBeVisible();
  expect(await visibleSteps(page)).toBe(1);
  await expect(page.locator("[data-survey-submit]")).toBeHidden();

  await page.getByRole("button", { name: "Start" }).click();
  expect(await visibleSteps(page)).toBe(1);
  await expect(page.locator("[data-survey-count]")).toHaveText("Question 1 of 6");
  await expect(page.locator("[data-survey-progress]")).toHaveAttribute("aria-valuenow", "1");
  // Focus moves to the question, so a screen reader announces it.
  await expect(page.locator("#studio-survey-overall-label")).toBeFocused();

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
  const animation = await activeStep(page).evaluate((el) => getComputedStyle(el).animationName);
  expect(animation).toBe("none");
});

test("the step slides in when motion is allowed", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await start(page);
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

test.describe("without JavaScript", () => {
  test.use({ javaScriptEnabled: false });

  test("every question shows in one form that submits", async ({ page }) => {
    await page.goto(SURVEY);
    expect(await visibleSteps(page)).toBe(7); // the intro and six questions
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
