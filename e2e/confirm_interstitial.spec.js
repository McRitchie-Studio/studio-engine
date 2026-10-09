const { test, expect } = require("@playwright/test");
const { watchPageErrors } = require("./helpers");

// [e2e] The scanner-safe sign-in page (studio/_confirm_interstitial): it posts
// its own form, and it still has a way through when the script that posts
// never arrives.
//
// The page is a whole document with no layout and no import map. The auto-post
// is studio/confirm_interstitial, loaded by its own module tag; the fallback
// button shows itself four seconds in by CSS alone. So one failed request
// cannot leave a person on a spinner with nothing to press, and that is
// measured here with the module's request really failing: aborted, and
// answered 404.
//
// /lab/confirm_interstitial renders the engine partial as
// Studio::LinksController#show does; its POST lands on a lab action that
// answers "consumed by POST".
//
// CONTROLS, each run against this file:
//   - drop the `animation` from .magic-fallback: the three specs that wait
//     for the button fail, the button never showing.
//   - remove the module tag from the partial: the first spec fails, the page
//     never posting.

const MODULE = /\/studio\/confirm_interstitial\.js(?:\?|$)/;
const CONSUME = "/lab/confirm_interstitial/consume";
const FALLBACK = "#magic-fallback";
const BUTTON = "#magic-fallback button.magic-submit";

function countPosts(page) {
  const posts = [];
  page.on("request", (request) => {
    if (request.method() === "POST" && request.url().endsWith(CONSUME)) posts.push(request.url());
  });
  return posts;
}

test("the page posts its own form, once, with no press", async ({ page }) => {
  const errors = watchPageErrors(page);
  const posts = countPosts(page);

  await page.goto("/lab/confirm_interstitial");
  await page.waitForURL(`**${CONSUME}`);

  await expect(page.locator("body")).toHaveText("consumed by POST");
  expect(posts).toHaveLength(1);
  expect(errors).toEqual([]);
});

async function stillHasAWayThrough(page, fail) {
  const posts = countPosts(page);
  let requested = 0;
  await page.route(MODULE, (route) => { requested += 1; return fail(route); });

  await page.goto("/lab/confirm_interstitial");
  await expect(page.locator(".magic-spinner")).toBeVisible();

  // The script never ran: nothing has posted, and the button is not yet there
  // to press.
  await expect.poll(() => requested).toBe(1);
  await expect(page.locator(BUTTON)).toBeHidden();
  expect(await page.locator(FALLBACK).evaluate((el) => el.getBoundingClientRect().height)).toBe(0);
  expect(posts).toHaveLength(0);

  // Four seconds in, the button shows itself, with no script to show it.
  await expect(page.locator(BUTTON)).toBeVisible({ timeout: 8_000 });
  expect(posts, "the fallback appeared because of CSS, not because a post was made").toHaveLength(0);

  await page.locator(BUTTON).click();
  await page.waitForURL(`**${CONSUME}`);
  await expect(page.locator("body")).toHaveText("consumed by POST");
  expect(posts).toHaveLength(1);
}

test("with the module's request aborted the fallback button appears and signs in", async ({ page }) => {
  await stillHasAWayThrough(page, (route) => route.abort());
});

test("with the module answered 404 the fallback button appears and signs in", async ({ page }) => {
  await stillHasAWayThrough(page, (route) => route.fulfill({ status: 404, contentType: "text/plain", body: "Not Found" }));
});

test("the fallback takes no room until it shows", async ({ page }) => {
  await page.route(MODULE, (route) => route.abort());
  await page.goto("/lab/confirm_interstitial");

  const before = await page.locator(".magic-spinner").evaluate((el) => el.getBoundingClientRect().top);
  const hidden = await page.locator(FALLBACK).evaluate((el) => {
    const style = getComputedStyle(el);
    return { height: el.getBoundingClientRect().height, visibility: style.visibility, marginTop: style.marginTop };
  });
  expect(hidden).toEqual({ height: 0, visibility: "hidden", marginTop: "0px" });

  await expect(page.locator(BUTTON)).toBeVisible({ timeout: 8_000 });
  const after = await page.locator(".magic-spinner").evaluate((el) => el.getBoundingClientRect().top);
  expect(after, "the block grows below the spinner; main re-centres, so the spinner rises").toBeLessThan(before);
});
