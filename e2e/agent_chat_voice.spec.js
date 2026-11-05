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
//   - read the form's token before the meta tag in csrfToken: POST /voice/takes is
//     refused (e2e/boot.rb turns forgery on for this path) and the first spec fails.
//   - put <form method="dialog"> back in _microphone_help: the Close spec fails at
//     the POST and the draft.
//   - drop the [data-voice-recorder-state="recording"] rule in _voice, or
//     "heard" => "" in VOICE_RECORDER_COPY: the held-button spec fails.
//   - drop onFocusOut's stop, or the event.button check: their specs fail.
//   - delete `voice && studio_agent_chat_voice?` for a bare `voice`: the signed-out
//     spec fails (a route exists, so the mic renders for a visitor).
//   - drop the TAP_MS check in finish() (studio/voice_recorder): the tap spec fails
//     at "silent", then at the help opening on the second tap.
//   - put min-height back to 1.25rem on .studio-agent-voice-status: the 390px spec
//     fails at the quiet hint. Drop the .studio-mic-name nowrap, or restore the longer
//     prompt: it fails at the first hold.
//   - drop holdLine in onState: the long-old-line spec fails.
//   - delete onDialogKey's listeners (studio/microphone_chip): the held-key spec fails.
//   - delete the studio:agent-chat:sent dispatch in submit (studio/agent_chat): the
//     typed-send spec fails at the old line.
//   - hide no held line (`held.hidden = true`): the held spec fails.
//   - drop the picker's max-height in _voice: the short-window spec fails at the chip.

const PAGE = "/agent_chat_voice_lab";
const SIGN_IN = "/agent_chat_voice_lab/sign_in";
const CHAT = '[data-test="agent-chat"]';
const MIC = '[data-test="agent-chat-voice"]';
const STATUS = '[data-test="agent-chat-voice-status"]';
const RECORDER = "[data-studio-controller='voice-recorder']";
const MOCK_TEXT = "This is a mock transcript of your voice.";
const PRIVACY = "When you speak to an agent, your recording is sent to OpenAI to turn it into text, then deleted. We never keep the audio.";

async function stubMicrophone(page, { gain = 0.3, denied = false, spareMics = 0 } = {}) {
  await page.addInitScript(({ gain, denied, spareMics }) => {
    window.stubGain = gain;
    const mic = { deviceId: "mbp", label: "MacBook Pro Microphone (Built-in)" };
    const granted = () => sessionStorage.getItem("stub-mic-granted") === "1";
    const media = navigator.mediaDevices;
    const spares = Array.from({ length: spareMics }, (_, i) => ({ kind: "audioinput", groupId: "", deviceId: `spare-${i}`, label: `Spare Microphone ${i + 1}` }));
    media.enumerateDevices = async () => [{ kind: "audioinput", groupId: "", deviceId: granted() ? mic.deviceId : "", label: granted() ? mic.label : "" }, ...(granted() ? spares : [])];
    let source = null;
    media.getUserMedia = async () => {
      if (denied) throw new DOMException("Permission denied", "NotAllowedError");
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
  }, { gain, denied, spareMics });
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
  const takeTokens = [];
  page.on("request", (request) => {
    if (request.url().endsWith("/agent_chat/messages") && request.method() === "POST") sent.push(request.postDataJSON());
    if (request.url().endsWith("/voice/takes") && request.method() === "POST") takeTokens.push(request.headers()["x-csrf-token"]);
  });

  await holdToTalk(page);

  await expect(page.locator(MIC)).toHaveAttribute("data-agent-chat-voice-state", "sent");
  await expect(page.locator(STATUS)).toHaveText("Sent. Spoken by Someone new.");
  // Forgery is on for this path (e2e/boot.rb): "sent" means the real check passed.
  const meta = await page.locator("meta[name='csrf-token']").getAttribute("content");
  expect(meta).toBeTruthy();
  expect(takeTokens).toEqual([meta]);
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
  await page.waitForTimeout(300);
  await page.mouse.up();
  await expect(page.locator(MIC)).toHaveAttribute("data-agent-chat-voice-state", "sent");
});

// A window short enough that the composer sticks to its bottom, as on a long thread.
async function openStuck(page, options) {
  await openSignedIn(page, options);
  await page.setViewportSize({ width: 390, height: 460 });
  await page.evaluate(() => window.scrollTo(0, 0));
  const form = await page.locator('form[data-test="agent-chat-form"]').boundingBox();
  expect(form.y + form.height, "the composer is stuck to the window's bottom").toBeLessThanOrEqual(460);
  expect(await page.evaluate(() => document.documentElement.scrollHeight), "the page scrolls behind it").toBeGreaterThan(460);
}

test("a held button does not move in a stuck composer, and one live line says Listening", async ({ page }) => {
  await openStuck(page);
  const recorder = page.locator(RECORDER);
  const button = recorder.locator("[data-voice-recorder-button]");
  const before = await button.boundingBox();
  await page.mouse.move(before.x + before.width / 2, before.y + before.height / 2);
  await page.mouse.down();
  // After the first audible frame: that is when the recorder's own line would land.
  await expect(recorder).toHaveAttribute("data-voice-recorder-heard", "true");
  await page.waitForTimeout(400);
  const held = await button.boundingBox();
  expect(Math.abs(held.y - before.y), "the button stays under the finger").toBeLessThan(2);
  await expect(page.locator(STATUS)).toHaveText("Listening...");
  await expect(recorder.locator("[data-voice-recorder-status]")).toBeHidden();
  await page.mouse.up();
  await expect(page.locator(MIC)).toHaveAttribute("data-agent-chat-voice-state", "sent");
});

test("the quiet hint speaks on the one line and does not move a held button", async ({ page }) => {
  await openStuck(page, { gain: 0 });
  const recorder = page.locator(RECORDER);
  const button = recorder.locator("[data-voice-recorder-button]");
  const before = await button.boundingBox();
  await page.mouse.move(before.x + before.width / 2, before.y + before.height / 2);
  await page.mouse.down();
  await expect(page.locator(STATUS)).toHaveText("I can't hear anything yet. Is your microphone on?", { timeout: 6000 });
  const held = await button.boundingBox();
  expect(Math.abs(held.y - before.y)).toBeLessThan(2);
  await page.mouse.up();
  await expect(page.locator(MIC)).toHaveAttribute("data-agent-chat-voice-state", "silent");
});

test("the microphone help's Close keeps the draft and posts nothing", async ({ page }) => {
  await openSignedIn(page);
  const posts = [];
  page.on("request", (request) => { if (request.url().endsWith("/agent_chat/messages") && request.method() === "POST") posts.push(request.url()); });
  const input = page.locator('[data-test="agent-chat-input"]');
  await input.fill("my draft");

  await page.locator(`${MIC} .studio-mic-chip`).click();
  await page.locator(`${MIC} [data-microphone-help-link]`).click();
  const dialog = page.locator(`${MIC} [data-microphone-dialog]`);
  await expect(dialog).toBeVisible();
  await dialog.getByRole("button", { name: "Close" }).click();

  await expect(dialog).toBeHidden();
  await expect(page.locator(`${MIC} [data-microphone-help-link]`), "focus goes back to what opened it").toBeFocused();
  await page.waitForTimeout(300);
  expect(posts).toEqual([]);
  await expect(input).toHaveValue("my draft");
  await expect(page.locator('[data-test="agent-chat-sent"]')).toHaveCount(0);
});

test("a right-click on the talk button starts no take", async ({ page }) => {
  await openSignedIn(page);
  const recorder = page.locator(RECORDER);
  const box = await recorder.locator("[data-voice-recorder-button]").boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down({ button: "right" });
  await page.waitForTimeout(200);
  await expect(recorder).toHaveAttribute("data-voice-recorder-state", "idle");
  await page.mouse.up({ button: "right" });
});

test("a key held on the talk button stops the take when focus leaves", async ({ page }) => {
  await openSignedIn(page);
  const recorder = page.locator(RECORDER);
  await recorder.locator("[data-voice-recorder-button]").focus();
  await page.keyboard.down(" ");
  await expect(recorder).toHaveAttribute("data-voice-recorder-state", "recording");
  await page.waitForTimeout(500);
  await page.locator('[data-test="agent-chat-input"]').focus();
  await expect(recorder).not.toHaveAttribute("data-voice-recorder-state", /recording|starting/);
  await page.keyboard.up(" ");
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

// The button's whole box: a finger notices sideways and a resize as well as up.
function expectSameBox(now, before, when) {
  for (const side of ["x", "y", "width", "height"]) {
    expect(Math.abs(now[side] - before[side]), `${when}: the button's ${side} stays (${before[side]} -> ${now[side]})`).toBeLessThan(1);
  }
}

async function setTheme(page, theme) {
  if (theme !== "light") return;
  await page.evaluate(() => document.documentElement.classList.remove("dark"));
  await page.waitForTimeout(400);
}

for (const theme of ["dark", "light"]) {
  test(`at 390px outside a stuck composer, in ${theme}: the first hold and the quiet hint leave the button where it is`, async ({ page }) => {
    await openSignedIn(page, { gain: 0 });
    await setTheme(page, theme);
    const recorder = page.locator(RECORDER);
    const button = recorder.locator("[data-voice-recorder-button]");
    const chip = page.locator(`${MIC} .studio-mic-chip`);
    const form = await page.locator('form[data-test="agent-chat-form"]').boundingBox();
    expect(form.y + form.height, "this composer sits in the page, not stuck to the bottom").toBeLessThan(844 - 13);
    // The first hold: the chip still says the prompt, whole, on one line.
    await expect(chip.locator("[data-microphone-label]")).toHaveText("Microphone: hold to allow");
    expect(await chip.locator("[data-microphone-label]").evaluate((el) => el.scrollWidth <= el.clientWidth), "the prompt fits at 390px").toBe(true);

    const before = await button.boundingBox();
    await page.mouse.move(before.x + before.width / 2, before.y + before.height / 2);
    await page.mouse.down();
    await expect(recorder).toHaveAttribute("data-voice-recorder-state", "recording");
    // The chip names the microphone the take opened.
    await expect(chip.locator("[data-microphone-label]")).toHaveText("MacBook Pro Microphone");
    expectSameBox(await button.boundingBox(), before, "recording, the chip's label changed");
    await expect(page.locator(STATUS)).toHaveText("I can't hear anything yet. Is your microphone on?", { timeout: 6000 });
    const line = await page.locator(STATUS).boundingBox();
    expect(line.height, "the hint really wraps at this width: the reserve is what is being measured").toBeGreaterThan(30);
    expectSameBox(await button.boundingBox(), before, "the quiet hint wrapped");
    await page.mouse.up();
    await expect(page.locator(MIC)).toHaveAttribute("data-agent-chat-voice-state", "silent");
    expect(await sideways(page)).toBeLessThanOrEqual(0);
  });
}

test("a long old line clearing under the finger does not move the button, stuck or not", async ({ page }) => {
  await openStuck(page);
  await page.route("**/voice/takes", (route) => route.fulfill({
    status: 429, contentType: "application/json", headers: { "Retry-After": "40" }, body: JSON.stringify({ error: "Too many." })
  }));
  await holdToTalk(page);
  await expect(page.locator(STATUS)).toContainText("Try again in 40 seconds.");
  const tall = await page.locator(STATUS).boundingBox();
  expect(tall.height, "taller than the two lines reserved").toBeGreaterThan(50);

  const recorder = page.locator(RECORDER);
  const button = recorder.locator("[data-voice-recorder-button]");
  const before = await button.boundingBox();
  await page.mouse.move(before.x + before.width / 2, before.y + before.height / 2);
  await page.mouse.down();
  await expect(recorder).toHaveAttribute("data-voice-recorder-state", "recording");
  await expect(page.locator(STATUS)).toHaveText("Listening...");
  expectSameBox(await button.boundingBox(), before, "the old line cleared");
  await page.waitForTimeout(400);
  await page.mouse.up();
});

test("a tap asks for a hold: nothing is sent, the microphone is not blamed, and the help stays shut", async ({ page }) => {
  // gain 0: were these judged as takes, each would be silent, and the second opens the help.
  await openSignedIn(page, { gain: 0 });
  let posts = 0;
  page.on("request", (request) => { if (request.url().endsWith("/voice/takes")) posts += 1; });
  const recorder = page.locator(RECORDER);
  const box = await recorder.locator("[data-voice-recorder-button]").boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);

  // Let go at once (the microphone may not be open yet), then once it is recording.
  await page.mouse.down();
  await page.mouse.up();
  await expect(recorder).toHaveAttribute("data-voice-recorder-state", "tapped");
  for (let i = 0; i < 2; i += 1) {
    await page.mouse.down();
    await expect(recorder).toHaveAttribute("data-voice-recorder-state", "recording");
    await page.mouse.up();
    await expect(recorder).toHaveAttribute("data-voice-recorder-state", "tapped");
  }
  await expect(page.locator(MIC)).toHaveAttribute("data-agent-chat-voice-state", "tapped");
  await expect(page.locator(STATUS)).toHaveText("Hold the button while you talk, then let go.");
  await expect(page.locator(`${MIC} .studio-recorder-status`)).toBeHidden();
  await expect(recorder.locator("[data-voice-recorder-label]")).toHaveText("Hold to talk");
  await expect(page.locator(`${MIC} [data-microphone-dialog]`)).toBeHidden();
  expect(posts).toBe(0);

  // Real failures still go to the help: a held take, silent, twice.
  await holdToTalk(page);
  await expect(page.locator(MIC)).toHaveAttribute("data-agent-chat-voice-state", "silent");
  await holdToTalk(page);
  await expect(page.locator(`${MIC} [data-microphone-dialog]`)).toBeVisible();
});

test("a refused microphone still opens the help, and says so on the one line", async ({ page }) => {
  await openSignedIn(page, { denied: true });
  const recorder = page.locator(RECORDER);
  const box = await recorder.locator("[data-voice-recorder-button]").boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await page.mouse.up();
  await expect(recorder).toHaveAttribute("data-voice-recorder-state", "denied");
  const dialog = page.locator(`${MIC} [data-microphone-dialog]`);
  await expect(dialog).toBeVisible();
  await page.waitForTimeout(200);
  await expect(dialog, "letting go of the mouse does not dismiss it").toBeVisible();
  await expect(page.locator(MIC)).toHaveAttribute("data-agent-chat-voice-state", "refused");
  await expect(page.locator(STATUS)).toHaveText("Allow the microphone to record.");
  await expect(page.locator(`${MIC} .studio-recorder-status`)).toBeHidden();
});

for (const key of [" ", "Enter"]) {
  test(`a key held on the talk button does not dismiss the refused-microphone help: ${key === " " ? "Space" : key}`, async ({ page }) => {
    await openSignedIn(page, { denied: true });
    const recorder = page.locator(RECORDER);
    const dialog = page.locator(`${MIC} [data-microphone-dialog]`);
    await recorder.locator("[data-voice-recorder-button]").focus();
    await page.keyboard.down(key);
    await expect(dialog).toBeVisible();
    await expect(dialog.getByRole("button", { name: "Close" }), "focus lands on Close, under the held key").toBeFocused();
    // Playwright sends a second down of a held key as a repeat, as the OS does.
    for (let i = 0; i < 3; i += 1) await page.keyboard.down(key);
    await page.keyboard.up(key);
    await page.waitForTimeout(200);
    await expect(dialog, "repeats and the keyup leave it open").toBeVisible();

    // A new press is a person answering it.
    await page.keyboard.press(key);
    await expect(dialog).toBeHidden();
  });
}

test("a later typed send clears the line a take left, through the real proxy", async ({ page }) => {
  await openSignedIn(page);
  await holdToTalk(page);
  await expect(page.locator(STATUS)).toHaveText("Sent. Spoken by Someone new.");

  const input = page.locator('[data-test="agent-chat-input"]');
  await input.fill("Typed after talking.");
  await input.press("Enter");
  await expect(page.locator('[data-test="agent-chat-sent"]').filter({ hasText: "Typed after talking." })).toBeVisible();
  await expect(page.locator(STATUS)).toHaveText("");
  await expect(page.locator(MIC)).toHaveAttribute("data-agent-chat-voice-state", "idle");
});

test("a typed send the app refuses keeps the line a take left", async ({ page }) => {
  await openSignedIn(page);
  await holdToTalk(page);
  await expect(page.locator(STATUS)).toHaveText("Sent. Spoken by Someone new.");
  await page.route("**/agent_chat/messages", (route) => route.fulfill({ status: 503, contentType: "application/json", body: JSON.stringify({ error: "Can't reach the chat right now." }) }));
  const input = page.locator('[data-test="agent-chat-input"]');
  await input.fill("Typed after talking.");
  await input.press("Enter");
  await expect(page.locator('[data-test="agent-chat-error"]')).toBeVisible();
  await expect(page.locator(STATUS)).toHaveText("Sent. Spoken by Someone new.");
});

for (const theme of ["dark", "light"]) {
  test(`a held turn says it was received and never asks for a resend, in ${theme}; a hub still saying failed keeps its line`, async ({ page }) => {
    const at = new Date().toISOString();
    await openSignedIn(page);
    await page.route("**/agent_chat/turns**", (route) => route.fulfill({
      status: 200, contentType: "application/json",
      body: JSON.stringify({
        pending: false,
        turns: [
          { id: 1, role: "user", text: "A held message", status: "held", created_at: at },
          { id: 2, role: "user", text: "A failed message", status: "failed", created_at: at }
        ]
      })
    }));
    await page.reload();
    await expect(page.locator(CHAT)).toHaveAttribute("data-agent-chat-ready", "true");
    await setTheme(page, theme);
    const held = page.locator('[data-turn-key="1:user"]');
    const failed = page.locator('[data-turn-key="2:user"]');
    await expect(held.locator('[data-test="agent-chat-held"]')).toHaveText("Your message was received, but it won't get an automatic answer.");
    await expect(held.locator('[data-test="agent-chat-failed"]')).toBeHidden();
    expect(await held.innerText(), "what a person can read").not.toContain("Send it again");
    await expect(failed.locator('[data-test="agent-chat-failed"]')).toBeVisible();
    await expect(failed.locator('[data-test="agent-chat-held"]')).toBeHidden();
    await expect(page.locator('[data-test="agent-chat-typing"]')).toBeHidden();
    const ratio = await held.locator('[data-test="agent-chat-held"]').evaluate((el) => {
      const channels = (css) => css.match(/[\d.]+/g).slice(0, 3).map(Number);
      const luminance = (rgb) => {
        const [r, g, b] = rgb.map((v) => { const c = v / 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; });
        return 0.2126 * r + 0.7152 * g + 0.0722 * b;
      };
      const [hi, lo] = [luminance(channels(getComputedStyle(el).color)), luminance(channels(getComputedStyle(document.body).backgroundColor))].sort((a, b) => b - a);
      return (hi + 0.05) / (lo + 0.05);
    });
    expect(ratio, "the held line reads on the page (AA)").toBeGreaterThanOrEqual(4.5);
    expect(await sideways(page)).toBeLessThanOrEqual(0);
  });
}

test("the picker fits a short stuck window: the chip stays on screen and every microphone is reachable", async ({ page }) => {
  await openStuck(page, { spareMics: 10 });
  await holdToTalk(page);
  await expect(page.locator(MIC)).toHaveAttribute("data-agent-chat-voice-state", "sent");
  const chip = page.locator(`${MIC} .studio-mic-chip`);
  await chip.click();
  const last = page.locator(`${MIC} [data-microphone-option="spare-9"]`);
  await expect(last).toHaveCount(1);

  const form = await page.locator('form[data-test="agent-chat-form"]').boundingBox();
  expect(form.y, "the composer's top is on screen").toBeGreaterThanOrEqual(0);
  const chipBox = await chip.boundingBox();
  expect(chipBox.y, "the chip stays on screen").toBeGreaterThanOrEqual(0);
  expect(chipBox.y + chipBox.height).toBeLessThanOrEqual(460);

  await page.locator(`${MIC} [data-microphone-help-link]`).scrollIntoViewIfNeeded();
  const link = await page.locator(`${MIC} [data-microphone-help-link]`).boundingBox();
  expect(link.y).toBeGreaterThanOrEqual(0);
  expect(link.y + link.height, "the last control in the picker scrolls into reach").toBeLessThanOrEqual(460);

  await last.click();
  await expect(page.locator(`${MIC} [data-microphone-dialog]`)).toBeVisible();
  expect(await sideways(page)).toBeLessThanOrEqual(0);
});

async function expectMicAt390(page, theme) {
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
}

async function expectFooterChatAt390(page, theme) {
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
}

test("the mic at 390px in dark: 44px targets, AA lines, nothing sideways", async ({ page }) => { await expectMicAt390(page, "dark"); });
test("the mic at 390px in light: 44px targets, AA lines, nothing sideways", async ({ page }) => { await expectMicAt390(page, "light"); });
test("the footer's Chat link at 390px in dark: a Contact link like its neighbours", async ({ page }) => { await expectFooterChatAt390(page, "dark"); });
test("the footer's Chat link at 390px in light: a Contact link like its neighbours", async ({ page }) => { await expectFooterChatAt390(page, "light"); });

test("a footer with no chat configured has no Chat link", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/site_footer");
  await expect(page.locator("footer[data-site-footer] nav[aria-label='Contact'] a", { hasText: /^Chat$/ })).toHaveCount(0);
  await expect(page.locator("footer[data-site-footer] nav[aria-label='Contact'] a", { hasText: /^Contact$/ })).toHaveCount(1);
});
