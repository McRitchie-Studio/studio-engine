const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests, watchPageErrors } = require("./helpers");

// [e2e] A meeting's recording beside its transcript (studio/knowledge_docs/_preview_transcript
// and studio/knowledge_transcript), in a real browser.
//
// What no other tier can see: that a click on a cue MOVES A REAL PLAYER, which
// needs media a browser decoded and a controller that actually connected; that
// it still happens when the markup arrives inside a lazy <turbo-frame> after
// the page has loaded, which is the only way the document page ever delivers
// it; and that following the cue being spoken scrolls the cue list and never
// the page.
//
// The recording is two minutes of silence e2e/boot.rb writes (a WAV, served as a
// static file, so seeks are real ranged reads). The transcript is 60 invented
// cues, one every two seconds.
//
// CONTROLS, each run against this file:
//   - remove "knowledge-transcript" from LAZY in app/javascript/studio/stimulus.js:
//     the first two specs fail waiting for the transcript to become ready.
//   - make `seek` in studio/knowledge_transcript set nothing (`media.currentTime = at`
//     deleted): the first spec fails at currentTime, still 0.
//   - make `follow` use cue.scrollIntoView(): the second spec fails at the page's
//     own scroll position, which moved.
//   - drop the pause in `scrolled`: the second spec fails where the list must
//     stay where the reader left it.

const PAGE = "/lab/knowledge_transcript";
const FRAME = "/lab/knowledge_transcript/frame";

const player = (page) => page.locator("[data-knowledge-player]");
const cueAt = (page, stamp) => page.locator(".knowledge-cue").filter({ has: page.getByRole("button", { name: stamp, exact: true }) });
const media = (page) => player(page).evaluate((el) => ({
  time: el.currentTime, paused: el.paused, duration: el.duration, ready: el.readyState
}));

// Whether the cue is wholly inside the cue list's own visible box.
const insideList = (cue) => cue.evaluate((el) => {
  const list = el.closest("[data-knowledge-cues]").getBoundingClientRect();
  const box = el.getBoundingClientRect();
  return box.top >= list.top - 1 && box.bottom <= list.bottom + 1;
});

test("a click on a cue seeks the player to that cue and plays, in markup that arrived in a lazy turbo-frame", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  const frames = [];
  page.on("request", (request) => {
    if (new URL(request.url()).pathname === FRAME) frames.push(request.headers()["turbo-frame"] || "");
  });

  await page.goto(PAGE);
  await page.waitForLoadState("load");
  // NOT VACUOUS: the frame is below the fold, so nothing of the transcript is in
  // the page the browser loaded. It is fetched, by Turbo, only once scrolled to.
  await page.waitForTimeout(300);
  expect(frames, "the lazy frame loaded before it was scrolled into view").toEqual([]);
  await expect(page.locator("[data-knowledge-player]")).toHaveCount(0);

  await page.locator("turbo-frame#knowledge-preview").scrollIntoViewIfNeeded();
  const transcript = page.locator("#knowledge-transcript");
  await expect(transcript).toHaveAttribute("data-knowledge-transcript-ready", "");
  expect(frames).toEqual(["knowledge-preview"]);
  await expect(transcript).not.toHaveAttribute("data-studio-controller-failed", /.*/);
  await expect(page.locator(".knowledge-cue")).toHaveCount(60);

  // The media is real: the browser read its length from the file.
  await expect.poll(async () => (await media(page)).duration).toBeCloseTo(120, 0);
  const before = await media(page);
  expect(before.time).toBe(0);
  expect(before.paused).toBe(true);

  await page.getByRole("button", { name: "0:40", exact: true }).click();

  await expect.poll(async () => (await media(page)).time, "the click did not move the player").toBeGreaterThanOrEqual(40);
  const after = await media(page);
  expect(after.time).toBeLessThan(46);
  expect(after.paused, "the click seeks AND plays").toBe(false);
  await expect(cueAt(page, "0:40")).toHaveClass(/knowledge-cue-current/);
  await expect(page.locator(".knowledge-cue-current")).toHaveCount(1);

  // Playback moves the mark on its own: 0:42 is the next cue.
  await expect(cueAt(page, "0:42")).toHaveClass(/knowledge-cue-current/, { timeout: 6000 });
  await expect(page.locator(".knowledge-cue-current")).toHaveCount(1);

  // A click on the line itself, not only on its time, seeks too.
  await cueAt(page, "0:10").locator(".knowledge-cue-text").click();
  await expect.poll(async () => (await media(page)).time).toBeLessThan(16);
  expect((await media(page)).time).toBeGreaterThanOrEqual(10);

  // Stored text is text: the cue's markup-looking words are on the page as words.
  await expect(cueAt(page, "0:10").locator(".knowledge-cue-text")).toContainText("<b>widget</b>");
  await expect(page.locator(".knowledge-cue b")).toHaveCount(0);
  expect(errors).toEqual([]);
});

test("the cue being spoken is followed inside the cue list, never by scrolling the page, and not while the reader scrolls", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto(FRAME);
  const transcript = page.locator("#knowledge-transcript");
  await expect(transcript).toHaveAttribute("data-knowledge-transcript-ready", "");
  await expect.poll(async () => (await media(page)).duration).toBeCloseTo(120, 0);

  const list = page.locator("[data-knowledge-cues]");
  const sizes = await list.evaluate((el) => ({ view: el.clientHeight, all: el.scrollHeight }));
  expect(sizes.all, "the cue list does not overflow, so there is nothing to follow").toBeGreaterThan(sizes.view * 2);
  expect(await insideList(cueAt(page, "1:40"))).toBe(false);

  // The player's own seek bar, which is not a click on any cue. The page CAN
  // scroll (the lab puts a screen and a half below the frame), so a page that
  // stays put was left alone, not stuck.
  // It is left part-way down, with the cue list half off the top of the
  // window, so centring a cue in the WINDOW would have to move it.
  expect(await page.evaluate(() => document.documentElement.scrollHeight - window.innerHeight)).toBeGreaterThan(400);
  await page.evaluate(() => window.scrollTo(0, 200));
  const pageScroll = await page.evaluate(() => window.scrollY);
  expect(pageScroll).toBe(200);
  await player(page).evaluate((el) => { el.currentTime = 100.5; });
  await expect(cueAt(page, "1:40")).toHaveClass(/knowledge-cue-current/);
  await expect.poll(() => insideList(cueAt(page, "1:40")), "the current cue was not brought into view").toBe(true);
  expect(await page.evaluate(() => window.scrollY), "following scrolled the page, not the list").toBe(pageScroll);

  await page.evaluate(() => window.scrollTo(0, 0));

  // The reader scrolls the list back to the top. The next cue is marked, and the
  // list stays where they put it.
  await list.hover();
  await page.mouse.wheel(0, -100000);
  await expect.poll(() => list.evaluate((el) => el.scrollTop)).toBe(0);
  await player(page).evaluate((el) => { el.currentTime = 110.5; });
  await expect(cueAt(page, "1:50")).toHaveClass(/knowledge-cue-current/);
  await page.waitForTimeout(400);
  expect(await list.evaluate((el) => el.scrollTop), "the list was pulled away from the reader").toBe(0);
  expect(await insideList(cueAt(page, "1:50"))).toBe(false);

  // Asking for a cue resumes following at once.
  await page.getByRole("button", { name: "0:04", exact: true }).click();
  await player(page).evaluate((el) => { el.pause(); el.currentTime = 90.5; });
  await expect(cueAt(page, "1:30")).toHaveClass(/knowledge-cue-current/);
  await expect.poll(() => insideList(cueAt(page, "1:30"))).toBe(true);
});

test("the player sits beside the cues on a wide screen and above them on a phone, both in view at once", async ({ page }) => {
  await blockOffsiteRequests(page);
  const boxes = () => page.evaluate(() => {
    const box = (selector) => document.querySelector(selector).getBoundingClientRect().toJSON();
    return { player: box("[data-knowledge-player]"), list: box("[data-knowledge-cues]"), height: window.innerHeight, width: window.innerWidth,
             overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth };
  });

  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto(FRAME);
  await expect(page.locator("#knowledge-transcript")).toHaveAttribute("data-knowledge-transcript-ready", "");
  const wide = await boxes();
  expect(wide.player.right, "side by side: the player ends before the cues begin").toBeLessThanOrEqual(wide.list.left);
  expect(Math.abs(wide.player.top - wide.list.top)).toBeLessThan(4);
  expect(wide.list.bottom, "the cue list scrolls inside itself, so it ends within the window").toBeLessThanOrEqual(wide.height);

  await page.setViewportSize({ width: 375, height: 667 });
  const phone = await boxes();
  expect(phone.player.bottom, "stacked: the player is above the cues").toBeLessThanOrEqual(phone.list.top);
  expect(phone.list.width).toBeGreaterThan(300);
  expect(phone.overflow, "the page scrolls sideways at phone width").toBe(0);
  // The player stays put while the cues scroll: scrolling the list moves neither.
  await page.locator("[data-knowledge-cues]").evaluate((el) => { el.scrollTop = 600; });
  const scrolled = await boxes();
  expect(scrolled.player.top).toBe(phone.player.top);
  expect(scrolled.list.top).toBe(phone.list.top);
  expect(phone.list.bottom - phone.player.top, "the player and the cue list do not fit one phone screen").toBeLessThanOrEqual(phone.height);
});

test("with no recording the cues are plain text and the transcript's script is never fetched", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  const asked = [];
  page.on("request", (request) => {
    if (/knowledge_transcript/.test(new URL(request.url()).pathname.replace(FRAME, ""))) asked.push(request.url());
  });

  await page.goto(`${FRAME}?recording=0`);
  await page.waitForLoadState("load");
  await page.waitForTimeout(300);

  await expect(page.locator(".knowledge-cue")).toHaveCount(60);
  await expect(page.locator(".knowledge-cue").nth(20).locator(".knowledge-cue-time")).toHaveText("0:40");
  await expect(page.locator(".knowledge-cue button")).toHaveCount(0);
  await expect(page.locator("[data-knowledge-player]")).toHaveCount(0);
  await expect(page.locator("#knowledge-transcript")).not.toHaveAttribute("data-studio-controller", /.*/);
  await page.locator(".knowledge-cue").nth(20).click();
  await expect(page.locator(".knowledge-cue-current")).toHaveCount(0);
  expect(asked, "a page with nothing to seek fetched the transcript controller").toEqual([]);
  expect(errors).toEqual([]);
});
