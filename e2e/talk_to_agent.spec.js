const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests, watchPageErrors } = require("./helpers");

// [e2e] The talk-to-agent modal (studio/agent_chat/_talk_modal, studio/talk_to_agent
// and its lazy "talk-to-agent" controller) wrapping the shared agent chat, in a
// real browser, against the stand-in hub e2e/boot.rb runs (AgentChatStubHub#converse!:
// a message goes pending, then typing, then is answered "You said: <text>").
//
// What no other tier can see: that a click on a marked link opens the card on the
// page-scoped host instead of following the link; that the chat inside mounts and
// sends the link's opener with no typing, so the thinking line shows while the card
// is still opening; that the answer types itself in; that a second open of the same
// topic sends nothing; and that the card fits a phone.
//
// CONTROLS, each run against this file:
//   - remove "talk-to-agent" from LAZY in app/javascript/studio/stimulus.js: the
//     first spec fails, the click following the link to /agent_chat_lab.
//   - drop the sendOpener() call from poll in studio/agent_chat: the first spec
//     fails waiting for the opener's bubble.

const PAGE = "/talk_to_agent_lab";

// The lane's census counts bare test( declarations, so each viewport is its own test.
async function opensAndAnswers(page, viewport) {
    await page.setViewportSize(viewport);
    await blockOffsiteRequests(page);
    const errors = watchPageErrors(page);
    await page.goto(PAGE);
    await expect(page.locator('[data-test="talk-to-agent"]')).toHaveAttribute("data-talk-to-agent-ready", "true");

    await page.locator('[data-test="talk-pro"]').click();
    await expect(page).toHaveURL(new RegExp(`${PAGE}$`));
    const panel = page.locator('[data-test="talk-to-agent-panel"]');
    await expect(panel).toBeVisible();
    await expect(page.locator('[role="dialog"]')).toHaveAttribute("aria-label", "Talk to Alex about Pro");
    await expect(page.locator('[data-test="talk-to-agent-title"]')).toHaveText("Talk to Alex about Pro");

    // The opener goes without the visitor typing; the thinking line follows it.
    await expect(panel.locator('[data-test="agent-chat-sent"]')).toHaveText("Tell me about the Pro plan.");
    await expect(panel.locator('[data-test="agent-chat-typing-slot"]')).toBeVisible();
    const reply = panel.locator('[data-role="agent"] [data-agent-chat-text]');
    await expect(reply).toHaveText("You said: Tell me about the Pro plan.", { timeout: 15000 });

    // The conversation goes on in the box.
    const input = panel.locator('[data-test="agent-chat-input"]');
    await input.fill("And annual billing?");
    await input.press("Enter");
    await expect(panel.locator('[data-test="agent-chat-sent"]').filter({ hasText: "And annual billing?" })).toBeVisible();
    await expect(panel.locator('[data-role="agent"] [data-agent-chat-text]').last()).toHaveText("You said: And annual billing?", { timeout: 15000 });

    const card = await panel.boundingBox();
    expect(card.x).toBeGreaterThanOrEqual(0);
    expect(card.x + card.width).toBeLessThanOrEqual(viewport.width);
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    expect(overflow).toBeLessThanOrEqual(0);
    expect(errors).toEqual([]);
}

test("a link opens the modal and the agent starts answering the opener (1280px)", async ({ page }) => {
  await opensAndAnswers(page, { width: 1280, height: 800 });
});

test("a link opens the modal and the agent starts answering the opener (390px)", async ({ page }) => {
  await opensAndAnswers(page, { width: 390, height: 844 });
});

test("closing and reopening the same topic shows the thread and sends nothing new", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.goto(PAGE);
  await expect(page.locator('[data-test="talk-to-agent"]')).toHaveAttribute("data-talk-to-agent-ready", "true");

  await page.locator('[data-test="talk-builder"]').click();
  const panel = page.locator('[data-test="talk-to-agent-panel"]');
  await expect(panel.locator('[data-test="agent-chat-sent"]')).toHaveText("I'd like to talk about Builder.");
  await expect(panel.locator('[data-role="agent"] [data-agent-chat-text]')).toHaveText("You said: I'd like to talk about Builder.", { timeout: 15000 });

  await page.locator('[data-test="talk-to-agent-close"]').click();
  await expect(panel).toHaveCount(0);

  await page.locator('[data-test="talk-builder"]').click();
  await expect(panel.locator('[data-role="agent"] [data-agent-chat-text]')).toHaveText("You said: I'd like to talk about Builder.");
  await page.waitForTimeout(800);
  await expect(panel.locator('[data-test="agent-chat-sent"]')).toHaveCount(1);
  expect(errors).toEqual([]);
});

test("a modified click follows the link", async ({ page, context }) => {
  await blockOffsiteRequests(page);
  await page.goto(PAGE);
  await expect(page.locator('[data-test="talk-to-agent"]')).toHaveAttribute("data-talk-to-agent-ready", "true");
  const [opened] = await Promise.all([
    context.waitForEvent("page"),
    page.locator('[data-test="talk-pro"]').click({ modifiers: [process.platform === "darwin" ? "Meta" : "Control"] })
  ]);
  await opened.waitForLoadState();
  expect(new URL(opened.url()).pathname).toBe("/agent_chat_lab");
  await expect(page.locator('[data-test="talk-to-agent-panel"]')).toHaveCount(0);
});
