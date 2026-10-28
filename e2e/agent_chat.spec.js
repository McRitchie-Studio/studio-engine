const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests, watchPageErrors } = require("./helpers");

// [e2e] The shared agent chat (studio/agent_chat/_chat, studio/agent_chat and its
// lazy "agent-chat" controller), in a real browser, against the stand-in hub
// e2e/boot.rb runs (AgentChatStubHub#converse!: a message goes pending, then
// typing, then is answered "You said: <text>").
//
// What no other tier can see: that the lazy controller connects and mounts; that
// Enter sends through the proxy with the page's CSRF token and clears the box;
// that the typing line appears, moves from thinking to typing, and leaves when the
// poll brings the answer; that a hub that is down leaves the words in the box with
// a reason; and that the page does not scroll sideways at phone width.
//
// CONTROLS, each run against this file:
//   - remove "agent-chat" from LAZY in app/javascript/studio/stimulus.js: both
//     specs fail waiting for data-agent-chat-ready.
//   - clear `input.value` before the POST in `submit`: the second spec fails at
//     the kept draft.
//   - key turns by `turn.id` alone (turnKey in studio/agent_chat): the first spec
//     fails at the answer, which lands in the visitor's own bubble because it
//     shares their row id, so no agent turn ever appears.

const PAGE = "/agent_chat_lab";

test("a message sent with Enter is answered by polling, through thinking and typing", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.goto(PAGE);
  const chat = page.locator('[data-test="agent-chat"]');
  await expect(chat).toHaveAttribute("data-agent-chat-ready", "true");

  const input = page.locator('[data-test="agent-chat-input"]');
  await input.fill("Build me a booking app");
  await input.press("Enter");

  await expect(page.locator('[data-test="agent-chat-sent"]').filter({ hasText: "Build me a booking app" })).toBeVisible();
  await expect(input).toHaveValue("");
  const typing = page.locator('[data-test="agent-chat-typing-slot"]');
  await expect(typing).toBeVisible();
  await expect(page.locator('[data-test="agent-chat-typing"]')).toHaveAttribute("data-phase", "typing", { timeout: 10000 });

  const reply = page.locator('[data-role="agent"] [data-agent-chat-text]');
  await expect(reply).toHaveText("You said: Build me a booking app", { timeout: 15000 });
  await expect(typing).toBeHidden();
  // The hub answers one row as two turns sharing its id: the answer must sit
  // BELOW the visitor's words, never replace them.
  const turns = page.locator('[data-test="agent-chat-messages"] [data-agent-chat-turn]');
  await expect(turns).toHaveCount(2);
  await expect(turns.nth(0)).toHaveAttribute("data-role", "user");
  await expect(turns.nth(0)).toContainText("Build me a booking app");
  await expect(turns.nth(1)).toHaveAttribute("data-role", "agent");
  await expect(page.locator('[data-test="agent-chat-empty"]')).toBeHidden();

  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(overflow).toBeLessThanOrEqual(0);
  expect(errors).toEqual([]);
});

test("a hub that is down keeps the words in the box and says why", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto(PAGE);
  await expect(page.locator('[data-test="agent-chat"]')).toHaveAttribute("data-agent-chat-ready", "true");

  const input = page.locator('[data-test="agent-chat-input"]');
  await input.fill("Hello [hub-down]");
  await page.locator('[data-test="agent-chat-send"]').click();

  const error = page.locator('[data-test="agent-chat-error"]');
  await expect(error).toBeVisible();
  await expect(error).toContainText(/try again/i);
  await expect(input).toHaveValue("Hello [hub-down]");
  await expect(page.locator('[data-test="agent-chat-sent"]')).toHaveCount(0);
  await expect(page.locator('[data-test="agent-chat-send"]')).toBeEnabled();
});
