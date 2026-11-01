const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The engine's voice capture layer (docs/VOICE_CAPTURE.md) on
// /lab/voice_capture at phone width: the microphone chip
// (studio/voice/_microphone_chip, studio/microphone_chip), its help dialog,
// and the record button (studio/voice/_recorder, studio/voice_recorder) on
// the one level meter (studio/level_meter). Ported from Voicebox's
// microphone_chip_test.rb and the recorder half of record_flow_test.rb.
//
// WHY A BROWSER. MediaRecorder, an AnalyserNode on a live stream, a native
// <dialog>, localStorage across a reload and the lazy controllers registering
// are behaviour the server's bytes cannot show.
//
// THE MICROPHONES ARE STUBBED before any page script runs. Before the first
// getUserMedia the browser lists them without names or ids, as a real one
// does; a take grants permission (kept in sessionStorage, so a reload keeps
// it). The stream is a Web Audio oscillator at window.stubGain (0.3 is a
// voice, 0 a muted microphone) wearing the opened device's label.
// window.micCalls keeps every constraint the page asked for.
//
// CONTROLS, run against this file:
//   - set SILENCE_RMS to 0 in studio/level_meter.js: "a silent take is
//     refused" fails (a take event arrives).
//   - drop `audioConstraints(deviceId)` for `{ audio: true }` in
//     studio/microphone.js's openMicrophone: "picking another microphone"
//     fails at the exact deviceId.

const ROOT = "[data-lab='voice-capture']";
const CHIP = "[data-studio-controller='microphone-chip']";
const RECORDER = "[data-studio-controller='voice-recorder']";
const MICS = [
  { deviceId: "default", label: "Default - MacBook Pro Microphone (Built-in)" },
  { deviceId: "mbp", label: "MacBook Pro Microphone (Built-in)" },
  { deviceId: "arctis", label: "Arctis Nova Pro Wireless (1038:12e0)" }
];

async function stubMicrophones(page, { gain = 0.3, denied = false } = {}) {
  await page.addInitScript(({ mics, gain, denied }) => {
    window.stubGain = gain;
    window.micCalls = [];
    window.labTakes = [];
    window.labSilent = 0;
    window.stubMics = mics;
    document.addEventListener("studio:voice-recorder:take", (event) => {
      const { blob, mimeType, durationMs, peakRms, microphone } = event.detail;
      window.labTakes.push({ size: blob.size, type: blob.type, isBlob: blob instanceof Blob, mimeType, durationMs, peakRms, microphone });
    });
    document.addEventListener("studio:voice-recorder:silent", () => { window.labSilent += 1; });
    const granted = () => sessionStorage.getItem("stub-mic-granted") === "1";
    const media = navigator.mediaDevices;
    media.enumerateDevices = async () => window.stubMics.map((m) => ({
      kind: "audioinput", groupId: "", deviceId: granted() ? m.deviceId : "", label: granted() ? m.label : ""
    }));
    if (navigator.permissions) {
      const query = navigator.permissions.query.bind(navigator.permissions);
      navigator.permissions.query = async (d) => (d && d.name === "microphone"
        ? { state: denied ? "denied" : (granted() ? "granted" : "prompt"), onchange: null } : query(d));
    }
    // ONE audio context for every take: Chrome caps how many a page may hold.
    let source = null;
    media.getUserMedia = async (c) => {
      window.micCalls.push(JSON.parse(JSON.stringify(c)));
      if (denied) throw new DOMException("no", "NotAllowedError");
      const exact = c && c.audio && c.audio.deviceId && c.audio.deviceId.exact;
      // exact "default" opens the system default under its real name; a bare
      // request opens the first device.
      const mic = exact ? window.stubMics.find((m) => m.deviceId === exact) : window.stubMics[1];
      if (!mic) throw new DOMException("gone", "OverconstrainedError");
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
  }, { mics: MICS, gain, denied });
}

async function openLab(page, query = "") {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(`/lab/voice_capture${query}`);
  await expect(page.locator(CHIP)).toHaveAttribute("data-microphone-ready", "true");
  await expect(page.locator(RECORDER)).toHaveAttribute("data-voice-recorder-ready", "true");
}

async function recordATake(page, { holdMs = 700 } = {}) {
  const button = page.locator("[data-voice-recorder-button]");
  await button.click();
  await expect(page.locator(RECORDER)).toHaveAttribute("data-voice-recorder-state", "recording");
  await page.waitForTimeout(holdMs);
  await button.click();
  await expect(page.locator(RECORDER)).not.toHaveAttribute("data-voice-recorder-state", /recording|starting/);
}

const sideways = (page) => page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);

test("the chip names the microphone a take opened, and a heard take hands the page its blob", async ({ page }) => {
  const pageErrors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  await stubMicrophones(page);
  await openLab(page);

  const chip = page.locator(CHIP);
  await expect(chip).toHaveAttribute("data-microphone-state", "prompt");
  await expect(chip.locator("[data-microphone-label]")).toHaveText("Microphone: tap Record to allow");

  for (const selector of [".studio-mic-chip", ".studio-recorder-button"]) {
    const box = await page.locator(selector).boundingBox();
    expect(box.height, `${selector} is a 44px tap target`).toBeGreaterThanOrEqual(44);
    expect(box.x).toBeGreaterThanOrEqual(0);
    expect(box.x + box.width).toBeLessThanOrEqual(390);
  }
  expect(await sideways(page), "nothing scrolls sideways at 390px").toBeLessThanOrEqual(0);

  await page.locator(".studio-mic-chip").click();
  await expect(chip.locator("[data-microphone-note]")).toContainText("Tap Record once and allow the microphone");
  await expect(chip.locator(".studio-mic-option")).toHaveCount(0);
  await page.locator(".studio-mic-chip").click();

  const button = page.locator("[data-voice-recorder-button]");
  await button.click();
  const recorder = page.locator(RECORDER);
  await expect(recorder).toHaveAttribute("data-voice-recorder-state", "recording");
  await expect(chip).toHaveAttribute("data-microphone-state", "ready");
  await expect(chip).toHaveAttribute("data-microphone-live", "true");
  await expect(chip.locator("[data-microphone-label]")).toHaveText("MacBook Pro Microphone");
  await expect(page.locator(".studio-mic-chip")).toHaveAttribute("aria-label", "Microphone: MacBook Pro Microphone. Tap to pick another.");
  await expect(chip, "the dot never heard the microphone").toHaveAttribute("data-microphone-heard", "true");
  await expect(recorder).toHaveAttribute("data-voice-recorder-heard", "true");
  await expect.poll(() => recorder.evaluate((el) => parseFloat(el.style.getPropertyValue("--studio-recorder-level") || "0")),
    "the ring never moved").toBeGreaterThan(0);
  await page.waitForTimeout(600);
  await button.click();

  await expect(recorder).toHaveAttribute("data-voice-recorder-state", "captured");
  await expect(chip).toHaveAttribute("data-microphone-live", "false");
  const takes = await page.evaluate(() => window.labTakes);
  expect(takes).toHaveLength(1);
  expect(takes[0].isBlob).toBe(true);
  expect(takes[0].size, "the take carries audio").toBeGreaterThan(0);
  expect(takes[0].mimeType).toMatch(/^audio\//);
  expect(takes[0].durationMs).toBeGreaterThan(300);
  expect(takes[0].peakRms).toBeGreaterThan(0.01);
  expect(takes[0].microphone).toEqual({ label: "MacBook Pro Microphone", deviceId: "mbp" });
  // Before permission only a bare request can ask; the stream it opened is the
  // system default, so there is no second open.
  expect(await page.evaluate(() => window.micCalls)).toEqual([{ audio: true }]);
  expect(await sideways(page)).toBeLessThanOrEqual(0);
  expect(pageErrors, `the page threw: ${pageErrors.join(" | ")}`).toEqual([]);
});

test("picking another microphone opens that exact deviceId on the next take, and survives a reload", async ({ page }) => {
  await blockOffsiteRequests(page);
  await stubMicrophones(page);
  await openLab(page);
  await recordATake(page);

  const chip = page.locator(CHIP);
  await page.locator(".studio-mic-chip").click();
  const options = chip.locator(".studio-mic-option");
  await expect(options).toHaveCount(2);
  await expect(options.filter({ hasText: "MacBook Pro Microphone" })).toHaveAttribute("aria-current", "true");
  await expect(chip.locator(".studio-mic-in-use")).toHaveText("In use");
  for (const box of await options.evaluateAll((els) => els.map((el) => el.getBoundingClientRect().height))) {
    expect(box, "each option is a 44px tap target").toBeGreaterThanOrEqual(44);
  }

  await options.filter({ hasText: "Arctis Nova Pro Wireless" }).click();
  const dialog = page.locator("[data-microphone-dialog]");
  await expect(dialog).toBeVisible();
  await expect(chip).toHaveAttribute("data-microphone-help", "switched");
  await expect(dialog.locator("[data-microphone-help-headline]")).toHaveText("Switched to Arctis Nova Pro Wireless ✓");
  await expect(dialog.locator("[data-microphone-help-title]")).toHaveText("How to change your microphone in Chrome");
  await expect(dialog.locator("[data-microphone-help-steps] li")).toHaveCount(4);
  const dialogBox = await dialog.boundingBox();
  expect(dialogBox.x + dialogBox.width, "the dialog fits a phone").toBeLessThanOrEqual(390);
  await dialog.getByRole("button", { name: "Close" }).click();
  await expect(dialog).toBeHidden();
  await expect(page.locator(".studio-mic-chip"), "focus goes back to the chip").toBeFocused();

  await expect(chip.locator("[data-microphone-label]")).toHaveText("Arctis Nova Pro Wireless");
  expect(await page.evaluate(() => localStorage.getItem("studio.microphone"))).toBe("arctis");

  await recordATake(page);
  let calls = await page.evaluate(() => window.micCalls);
  expect(calls.at(-1)).toEqual({ audio: { deviceId: { exact: "arctis" } } });
  expect((await page.evaluate(() => window.labTakes)).at(-1).microphone.label).toBe("Arctis Nova Pro Wireless");

  await page.reload();
  await expect(page.locator(CHIP)).toHaveAttribute("data-microphone-ready", "true");
  await expect(page.locator(CHIP).locator("[data-microphone-label]")).toHaveText("Arctis Nova Pro Wireless");
  await recordATake(page);
  calls = await page.evaluate(() => window.micCalls);
  expect(calls).toEqual([{ audio: { deviceId: { exact: "arctis" } } }]);
});

test("a headset plugged in shows up at once (devicechange), and one pulled out is gone", async ({ page }) => {
  await blockOffsiteRequests(page);
  await stubMicrophones(page);
  await openLab(page);
  await recordATake(page);

  const chip = page.locator(CHIP);
  await page.locator(".studio-mic-chip").click();
  await expect(chip.locator(".studio-mic-option")).toHaveCount(2);

  await page.evaluate(() => {
    window.stubMics = [...window.stubMics, { deviceId: "yeti", label: "Yeti Stereo Microphone (046d:0ab7)" }];
    navigator.mediaDevices.dispatchEvent(new Event("devicechange"));
  });
  await expect(chip.locator(".studio-mic-option")).toHaveCount(3);
  await expect(chip.locator(".studio-mic-option").filter({ hasText: "Yeti Stereo Microphone" })).toBeVisible();

  await page.evaluate(() => {
    window.stubMics = window.stubMics.filter((m) => m.deviceId !== "arctis");
    navigator.mediaDevices.dispatchEvent(new Event("devicechange"));
  });
  await expect(chip.locator(".studio-mic-option")).toHaveCount(2);
  await expect(chip.locator(".studio-mic-option").filter({ hasText: "Arctis" })).toHaveCount(0);
});

test("a silent take is refused, named, and the second one in a row opens the help", async ({ page }) => {
  await blockOffsiteRequests(page);
  await stubMicrophones(page, { gain: 0 });
  await openLab(page);

  await recordATake(page);
  const recorder = page.locator(RECORDER);
  await expect(recorder).toHaveAttribute("data-voice-recorder-state", "silent");
  await expect(recorder).toHaveAttribute("data-voice-recorder-heard", "false");
  await expect(page.locator("[data-voice-recorder-status]")).toHaveText(
    "I couldn't hear anything from MacBook Pro Microphone. Pick another microphone and try again.");
  await expect(page.locator("[data-microphone-dialog]")).toBeHidden();

  await recordATake(page);
  await expect(page.locator("[data-microphone-dialog]")).toBeVisible();
  await expect(page.locator(CHIP)).toHaveAttribute("data-microphone-help", "silent");
  await expect(page.locator("[data-microphone-help-headline]")).toHaveText("I couldn't hear anything from MacBook Pro Microphone.");

  expect(await page.evaluate(() => window.labTakes), "no blob is handed over").toEqual([]);
  expect(await page.evaluate(() => window.labSilent)).toBe(2);
});

test("a refused microphone says so on the chip, the recorder and the help", async ({ page }) => {
  await blockOffsiteRequests(page);
  await stubMicrophones(page, { denied: true });
  await openLab(page);
  await expect(page.locator(CHIP)).toHaveAttribute("data-microphone-state", "denied");
  await expect(page.locator(CHIP).locator("[data-microphone-label]")).toHaveText("Microphone not allowed");

  await page.locator("[data-voice-recorder-button]").click();
  await expect(page.locator(RECORDER)).toHaveAttribute("data-voice-recorder-state", "denied");
  await expect(page.locator("[data-voice-recorder-status]")).toHaveText("Allow the microphone to record.");
  await expect(page.locator("[data-microphone-dialog]")).toBeVisible();
  await expect(page.locator(CHIP)).toHaveAttribute("data-microphone-help", "denied");
});

test("hold to talk: pressing records, letting go hands over the take", async ({ page }) => {
  await blockOffsiteRequests(page);
  await stubMicrophones(page);
  await openLab(page, "?mode=hold");
  const recorder = page.locator(RECORDER);
  await expect(recorder).toHaveAttribute("data-voice-recorder-mode", "hold");

  const box = await page.locator("[data-voice-recorder-button]").boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await expect(recorder).toHaveAttribute("data-voice-recorder-state", "recording");
  await expect(recorder).toHaveAttribute("data-voice-recorder-heard", "true");
  await page.waitForTimeout(500);
  await page.mouse.up();
  await expect(recorder).toHaveAttribute("data-voice-recorder-state", "captured");
  expect(await page.evaluate(() => window.labTakes.length)).toBe(1);
});

test("dark mode: the chip and the button read on the dark surface", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.emulateMedia({ colorScheme: "dark" });
  await stubMicrophones(page);
  await openLab(page);
  const colours = await page.evaluate(() => {
    const read = (selector) => getComputedStyle(document.querySelector(selector));
    return { chipText: read(".studio-mic-chip").color, chipBg: read(".studio-mic-chip").backgroundColor,
             buttonText: read(".studio-recorder-button").color, buttonBg: read(".studio-recorder-button").backgroundColor };
  });
  expect(colours.chipText).not.toBe(colours.chipBg);
  expect(colours.buttonText).not.toBe(colours.buttonBg);
  expect(colours.buttonBg, "the button is painted, not transparent").not.toBe("rgba(0, 0, 0, 0)");
  expect(await sideways(page)).toBeLessThanOrEqual(0);
});
