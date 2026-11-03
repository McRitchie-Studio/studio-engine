const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests, watchPageErrors } = require("./helpers");

// [e2e] Hold to talk in the shared agent chat's composer (studio/agent_chat/_voice,
// studio/agent_chat_voice and its lazy "agent-chat-voice" controller) on
// /agent_chat_voice_lab, and the footer's standard Chat link. Everything is real
// but the ends: the take goes through the engine's POST /voice/takes to the MOCK
// transcriber (the test environment's default), and the words go through the proxy
// to the stand-in hub e2e/boot.rb runs (AgentChatStubHub#converse!), which names
// the speaker as the hub does.
//
// WHY A BROWSER. MediaRecorder on a live stream, a real hold on the button, the
// three lazy controllers finding each other, and whether the mic row fits a 390px
// composer are behaviour the server's bytes cannot show.
//
// THE MICROPHONE IS STUBBED before any page script runs, as e2e/voice_capture.spec.js
// does: a Web Audio oscillator at window.stubGain (0.3 a voice, 0 a muted microphone).
//
// CONTROLS, each run against this file:
//   - drop `voice` from the JSON body in send() (studio/agent_chat_voice): the
//     line says plain "Sent." and the first spec fails at the speaker.
//   - drop the dispatchEvent in send(): the spoken turn stays off the thread until
//     an idle poll and the first spec fails at the words.
//   - remove "agent-chat-voice" from LAZY in studio/stimulus: every signed-in
//     spec fails waiting for data-agent-chat-voice-state to move.
//   - in takeArrived, return instead of queueing while working: the queued spec
//     fails at the second take's POST.
//   - remove the `next === "starting"` branch in onState and the "listening" line:
//     the old-line spec fails at the cleared status.
//   - delete `voice && studio_agent_chat_voice?` for a bare `voice`: the signed-out
//     spec fails (a route exists, so the mic renders for a visitor).

const PAGE = "/agent_chat_voice_lab";
const SIGN_IN = "/agent_chat_voice_lab/sign_in";
const CHAT = '[data-test="agent-chat"]';
const MIC = '[data-test="agent-chat-voice"]';
const STATUS = '[data-test="agent-chat-voice-status"]';
const RECORDER = "[data-studio-controller='voice-recorder']";
const MOCK_TEXT = "This is a mock transcript of your voice.";
const PRIVACY = "When you speak to an agent, your recording is sent to OpenAI to turn it into text, then deleted. We never keep the audio.";

async function stubMicrophone(page, { gain = 0.3 } = {}) {
  await page.addInitScript(({ gain }) => {
    window.stubGain = gain;
    const mic = { deviceId: "mbp", label: "MacBook Pro Microphone (Built-in)" };
    const granted = () => sessionStorage.getItem("stub-mic-granted") === "1";
    const media = navigator.mediaDevices;
    media.enumerateDevices = async () => [{ kind: "audioinput", groupId: "", deviceId: granted() ? mic.deviceId : "", label: granted() ? mic.label : "" }];
    let source = null;
    media.getUserMedia = async () => {
      sessionStorage.setItem("stub-mic-granted", "1");
      if (!source) {
        const context = new AudioContext();
        const oscillator = context.createOscillator();
        oscillator.frequency.value = 220;
        const volume = context.createGain();
        oscillator.connect(volume);
        oscillator.start();
        source = { context, volume };
      }
      if (source.context.state === "suspended") await source.context.resume();
      source.volume.gain.value = window.stubGain;
      const out = source.context.createMediaStreamDestination();
      source.volume.connect(out);
      const track = out.stream.getAudioTracks()[0];
      Object.defineProperty(track, "label", { value: mic.label });
      track.getSettings = () => ({ deviceId: mic.deviceId });
      return out.stream;
    };
  }, { gain });
}

async function openSignedIn(page, options = {}) {
  await page.setViewportSize({ width: 390, height: 844 });
  await blockOffsiteRequests(page);
  await stubMicrophone(page, options);
  await page.goto(`${SIGN_IN}?as=${Date.now()}${Math.floor(Math.random() * 1e6)}`);
  await expect(page.locator(CHAT)).toHaveAttribute("data-agent-chat-ready", "true");
  await expect(page.locator(RECORDER)).toHaveAttribute("data-voice-recorder-ready", "true");
}

async function holdToTalk(page, { holdMs = 700 } = {}) {
  const recorder = page.locator(RECORDER);
  const box = await recorder.locator("[data-voice-recorder-button]").boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await expect(recorder).toHaveAttribute("data-voice-recorder-state", "recording");
  await page.waitForTimeout(holdMs);
  await page.mouse.up();
  await expect(recorder).not.toHaveAttribute("data-voice-recorder-state", /recording|starting/);
}

const sideways = (page) => page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);

test("a signed-out visitor has the chat and no microphone", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await blockOffsiteRequests(page);
  await page.goto(PAGE);
  await expect(page.locator(CHAT)).toHaveAttribute("data-agent-chat-ready", "true");
  await expect(page.locator('[data-test="agent-chat-input"]')).toBeVisible();
  await expect(page.locator(MIC)).toHaveCount(0);
  await expect(page.locator('[data-test="agent-chat-voice-privacy"]')).toHaveCount(0);
});

test("hold to talk through the proxy: the words post, the hub names the speaker, the agent answers", async ({ page }) => {
  const errors = watchPageErrors(page);
  await openSignedIn(page);
  await expect(page.locator('[data-test="agent-chat-voice-privacy"]')).toHaveText(PRIVACY);
  // The mic is in the composer, not beside it.
  await expect(page.locator(`form[data-test="agent-chat-form"] ${MIC} ${RECORDER}`)).toHaveCount(1);

  const sent = [];
  page.on("request", (request) => {
    if (request.url().endsWith("/agent_chat/messages") && request.method() === "POST") sent.push(request.postDataJSON());
  });

  await holdToTalk(page);

  await expect(page.locator(MIC)).toHaveAttribute("data-agent-chat-voice-state", "sent");
  await expect(page.locator(STATUS)).toHaveText("Sent. Spoken by Someone new.");
  await expect(page.locator('[data-test="agent-chat-sent"]').filter({ hasText: MOCK_TEXT })).toBeVisible();
  await expect(page.locator('[data-test="agent-chat-typing"]')).toBeVisible();

  expect(sent).toHaveLength(1);
  expect(sent[0].text).toBe(MOCK_TEXT);
  expect(Object.keys(sent[0].voice).sort()).toEqual(["check", "duration_ms", "score"]);
  expect(sent[0].voice.check).toBe("no_embedding");
  expect(sent[0].voice.duration_ms).toBeGreaterThan(0);

  await expect(page.locator('[data-test="agent-chat-messages"]')).toContainText(`You said: ${MOCK_TEXT}`, { timeout: 15000 });
  expect(await sideways(page)).toBeLessThanOrEqual(0);
  expect(errors).toEqual([]);
});

test("the old line clears on the next hold, and a new one says Listening", async ({ page }) => {
  await openSignedIn(page);
  await holdToTalk(page);
  await expect(page.locator(STATUS)).toHaveText("Sent. Spoken by Someone new.");

  const recorder = page.locator(RECORDER);
  const box = await recorder.locator("[data-voice-recorder-button]").boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await expect(recorder).toHaveAttribute("data-voice-recorder-state", "recording");
  await expect(page.locator(STATUS)).toHaveText("Listening...");
  // The button does not move under the finger when the line changes.
  const held = await recorder.locator("[data-voice-recorder-button]").boundingBox();
  expect(Math.abs(held.y - box.y)).toBeLessThan(2);
  await page.waitForTimeout(300);
  await page.mouse.up();
  await expect(page.locator(MIC)).toHaveAttribute("data-agent-chat-voice-state", "sent");
});

test("a take recorded during transcription waits its turn and is sent", async ({ page }) => {
  await openSignedIn(page);
  let release;
  const held = new Promise((resolve) => { release = resolve; });
  let takes = 0;
  await page.route("**/voice/takes", async (route) => {
    takes += 1;
    if (takes === 1) await held;
    await route.continue();
  });
  const sent = [];
  page.on("request", (request) => {
    if (request.url().endsWith("/agent_chat/messages") && request.method() === "POST") sent.push(request.postDataJSON());
  });

  await holdToTalk(page);
  await expect(page.locator(MIC)).toHaveAttribute("data-agent-chat-voice-state", "transcribing");

  await holdToTalk(page);
  await expect(page.locator(MIC)).toHaveAttribute("data-agent-chat-voice-state", "queued");
  await expect(page.locator(STATUS)).toHaveText("Got that one too. It's next.");
  expect(takes).toBe(1);

  release();
  await expect.poll(() => sent.length).toBe(2);
  expect(takes).toBe(2);
  await expect(page.locator(MIC)).toHaveAttribute("data-agent-chat-voice-state", "sent");
  await expect(page.locator('[data-test="agent-chat-sent"]').filter({ hasText: MOCK_TEXT })).toHaveCount(2);
});

test("a silent take is refused on the device, and nothing is sent", async ({ page }) => {
  await openSignedIn(page, { gain: 0 });
  let posts = 0;
  page.on("request", (request) => { if (request.url().endsWith("/voice/takes")) posts += 1; });

  await holdToTalk(page);

  await expect(page.locator(MIC)).toHaveAttribute("data-agent-chat-voice-state", "silent");
  await expect(page.locator(STATUS)).toContainText("I couldn't hear anything");
  // Said once: the recorder's own line for it is hidden in the composer.
  await expect(page.locator(`${MIC} .studio-recorder-status`)).toBeHidden();
  expect(posts).toBe(0);
});

test("refusals each say so and send nothing", async ({ page }) => {
  await openSignedIn(page);
  const answers = [
    { status: 503, body: { error: "Voice isn't set up on this app yet, so I can't hear recordings. Type instead for now.", reason: "not_configured" },
      state: "not_configured", line: "Voice isn't set up on this app yet" },
    { status: 503, body: { error: "I couldn't transcribe that just now. Try again in a moment.", reason: "transcriber_failed", retry: true },
      state: "failed", line: "I couldn't transcribe that just now" },
    { status: 422, body: { error: "I couldn't hear any words in that. Check your microphone and try again.", reason: "no_speech" },
      state: "no_speech", line: "I couldn't hear any words in that" },
    { status: 429, body: { error: "Too many.", retry_after: 60 }, headers: { "Retry-After": "60" },
      state: "rate_limited", line: "Try again in 1 minute." },
    { status: 401, body: { error: "unauthenticated" }, state: "refused", line: "Sign in again to talk." }
  ];
  let chatPosts = 0;
  page.on("request", (request) => { if (request.url().endsWith("/agent_chat/messages")) chatPosts += 1; });
  for (const answer of answers) {
    await page.unroute("**/voice/takes");
    await page.route("**/voice/takes", (route) => route.fulfill({
      status: answer.status, contentType: "application/json", headers: answer.headers || {}, body: JSON.stringify(answer.body)
    }));
    await holdToTalk(page);
    await expect(page.locator(MIC)).toHaveAttribute("data-agent-chat-voice-state", answer.state);
    await expect(page.locator(STATUS)).toContainText(answer.line);
  }
  expect(chatPosts).toBe(0);
});

test("a send that fails puts the words in the box", async ({ page }) => {
  await openSignedIn(page);
  await page.route("**/agent_chat/messages", (route) => route.fulfill({
    status: 503, contentType: "application/json", body: JSON.stringify({ error: "Can't reach the chat right now.", retry: true })
  }));
  const input = page.locator('[data-test="agent-chat-input"]');
  await input.fill("my draft");

  await holdToTalk(page);

  await expect(page.locator(MIC)).toHaveAttribute("data-agent-chat-voice-state", "failed");
  await expect(page.locator(STATUS)).toContainText("Your words are in the box");
  await expect(input).toHaveValue(`my draft\n${MOCK_TEXT}`);
});

for (const theme of ["dark", "light"]) {
  test(`the mic at 390px in ${theme}: 44px targets, theme tokens, nothing sideways`, async ({ page }) => {
    await openSignedIn(page);
    if (theme === "light") {
      await page.evaluate(() => document.documentElement.classList.remove("dark"));
      // The composer's background eases over (transition-colors): read it settled.
      await page.waitForTimeout(400);
    }
    await page.locator(STATUS).evaluate((el) => { el.textContent = "Sent. Spoken by Someone new."; });

    for (const selector of [".studio-recorder-button", ".studio-mic-chip"]) {
      const box = await page.locator(`${MIC} ${selector}`).boundingBox();
      expect(box.height, `${selector} is a 44px target`).toBeGreaterThanOrEqual(44);
      expect(box.x + box.width, `${selector} stays on the page`).toBeLessThanOrEqual(390);
    }
    const form = await page.locator('form[data-test="agent-chat-form"]').boundingBox();
    const talk = await page.locator(`${MIC} .studio-recorder-button`).boundingBox();
    expect(talk.y + talk.height, "the talk button sits inside the composer").toBeLessThanOrEqual(form.y + form.height);

    // The status line and the privacy line read on what is behind them (AA).
    const ratios = await page.evaluate((statusSelector) => {
      const channels = (css) => css.match(/[\d.]+/g).slice(0, 3).map(Number);
      const luminance = (rgb) => {
        const [r, g, b] = rgb.map((v) => { const c = v / 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; });
        return 0.2126 * r + 0.7152 * g + 0.0722 * b;
      };
      const contrast = (a, b) => { const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x); return (hi + 0.05) / (lo + 0.05); };
      const color = (selector) => channels(getComputedStyle(document.querySelector(selector)).color);
      const background = (selector) => channels(getComputedStyle(document.querySelector(selector)).backgroundColor);
      return {
        status: contrast(color(statusSelector), background('form[data-test="agent-chat-form"]')),
        privacy: contrast(color('[data-test="agent-chat-voice-privacy"]'), background("body"))
      };
    }, STATUS);
    expect(ratios.status).toBeGreaterThanOrEqual(4.5);
    expect(ratios.privacy).toBeGreaterThanOrEqual(4.5);

    // The picker opens inside the composer, full width, and closes.
    await page.locator(`${MIC} .studio-mic-chip`).click();
    const panel = await page.locator(`${MIC} .studio-mic-panel`).boundingBox();
    expect(panel.width).toBeGreaterThan(300);
    expect(await sideways(page)).toBeLessThanOrEqual(0);
    await page.locator(`${MIC} .studio-mic-chip`).click();
    expect(await sideways(page)).toBeLessThanOrEqual(0);
  });

  test(`the footer's Chat link at 390px in ${theme}: a Contact link like its neighbours`, async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await blockOffsiteRequests(page);
    await page.goto("/lab/site_footer?chat_footer=1");
    if (theme === "light") await page.evaluate(() => document.documentElement.classList.remove("dark"));

    const contact = page.locator("footer[data-site-footer] nav[aria-label='Contact']");
    const chat = contact.locator("a", { hasText: /^Chat$/ });
    await chat.scrollIntoViewIfNeeded();
    await expect(chat).toBeVisible();
    await expect(chat).toHaveAttribute("href", "/agent_chat_voice_lab");

    const styles = await page.evaluate(() => {
      const read = (el) => { const s = getComputedStyle(el); return [s.color, s.fontSize, s.fontWeight, s.textDecorationLine]; };
      const links = [...document.querySelectorAll("footer[data-site-footer] nav[aria-label='Contact'] a")];
      return { chat: read(links.find((a) => a.textContent.trim() === "Chat")), neighbour: read(links.find((a) => a.textContent.trim() === "Contact")) };
    });
    expect(styles.chat).toEqual(styles.neighbour);
    expect(await sideways(page)).toBeLessThanOrEqual(0);
  });
}

test("a footer with no chat configured has no Chat link", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/site_footer");
  await expect(page.locator("footer[data-site-footer] nav[aria-label='Contact'] a", { hasText: /^Chat$/ })).toHaveCount(0);
  await expect(page.locator("footer[data-site-footer] nav[aria-label='Contact'] a", { hasText: /^Contact$/ })).toHaveCount(1);
});
