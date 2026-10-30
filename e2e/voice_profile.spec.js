const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The voice row on /profile (studio/profiles/_voice_section and
// studio/voice_profile), at phone width, in a real browser.
//
// WHY A BROWSER. Every claim here is behaviour the server's bytes cannot show:
// the lazy controller registering, MediaRecorder and an AnalyserNode on a live
// microphone stream, the meter moving, a silent take refused, Save enabled
// only after three heard takes, and the POST carrying vectors and no audio.
//
// THE MICROPHONE IS GENERATED. Chrome's fake microphone cannot play chosen
// audio, so getUserMedia is replaced (before the page loads) with a Web Audio
// oscillator whose loudness the spec chooses: window.studioFakeMicGain 0.3 is
// a voice, 0 is a muted microphone. The page's own meter and silence rule judge
// it. The speaker vector comes from the "fake" embedder (window.studioFakeVoice).
//
// CONTROLS, run against this file:
//   - set SILENCE_RMS to 0 in studio/voice_profile.js: "a silent take is
//     refused" fails (the take is kept and phrase 2 becomes current).
//   - drop `embeddings: vectors` from the save body: "three heard takes save"
//     fails at the payload.

const ROW = '[data-profile-section="voice"]';

async function generatedMicrophone(page, { gain }) {
  await page.addInitScript((level) => {
    window.studioFakeMicGain = level;
    window.studioFakeVoice = "pat";
    // ONE audio context for every take: Chrome caps how many a page may hold,
    // and a context past the cap stays suspended, which reads as silence.
    let mic = null;
    navigator.mediaDevices.getUserMedia = async () => {
      if (!mic) {
        const context = new AudioContext();
        const oscillator = context.createOscillator();
        oscillator.frequency.value = 220;
        const volume = context.createGain();
        oscillator.connect(volume);
        oscillator.start();
        mic = { context, volume };
      }
      if (mic.context.state === "suspended") await mic.context.resume();
      mic.volume.gain.value = window.studioFakeMicGain;
      const out = mic.context.createMediaStreamDestination();
      mic.volume.connect(out);
      return out.stream;
    };
  }, gain);
}

async function openSetup(page) {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/lab/voice_profile");
  const row = page.locator(ROW);
  await expect(row.locator("[data-studio-controller='voice-profile']")).toHaveAttribute("data-voice-ready", "true");
  await row.getByRole("button", { name: "Set up your voice" }).click();
  await expect(row.locator("[data-voice-setup]")).toBeVisible();
  return row;
}

async function readOnePhrase(row, { heard }) {
  const root = row.locator("[data-studio-controller='voice-profile']");
  await row.locator("[data-voice-record]").click();
  await expect(root).toHaveAttribute("data-voice-state", "recording");
  if (heard) {
    await expect(root, "the meter never heard the microphone").toHaveAttribute("data-voice-heard", "true");
    await expect.poll(() => root.evaluate((el) => parseFloat(el.style.getPropertyValue("--studio-voice-level") || "0")),
      "the meter ring never moved").toBeGreaterThan(0);
  } else {
    await row.page().waitForTimeout(700);
  }
  await row.locator("[data-voice-record]").click();
  await expect(root).not.toHaveAttribute("data-voice-state", /recording|thinking/);
}

test("three heard takes save three vectors and no audio", async ({ page }) => {
  const pageErrors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  await generatedMicrophone(page, { gain: 0.3 });

  const posts = [];
  await page.route("**/profile/voice", async (route) => {
    posts.push({ method: route.request().method(), headers: route.request().headers(), body: route.request().postData() });
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ url: "/lab/voice_profile?saved=1" }) });
  });

  const row = await openSetup(page);
  await expect(row.getByText("This saves a voice pattern, not a recording.")).toBeVisible();
  const save = row.getByRole("button", { name: "Save" });
  await expect(save).toBeDisabled();

  for (let i = 0; i < 3; i++) {
    await expect(row.locator("[data-voice-phrase]").nth(i)).toHaveAttribute("data-phrase-state", "current");
    await readOnePhrase(row, { heard: true });
    await expect(row.locator("[data-voice-phrase]").nth(i)).toHaveAttribute("data-phrase-state", "done");
  }
  await expect(save).toBeEnabled();

  // Phone width: the row fits, nothing scrolls sideways.
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(overflow, "the voice row scrolls sideways at 390px").toBeLessThanOrEqual(0);

  await save.click();
  await page.waitForURL("**/lab/voice_profile?saved=1");

  expect(posts).toHaveLength(1);
  expect(posts[0].method).toBe("POST");
  expect(posts[0].headers["content-type"]).toContain("application/json");
  const body = JSON.parse(posts[0].body);
  expect(Object.keys(body.voice).sort()).toEqual(["embeddings", "model"]);
  expect(body.voice.model).toBe("fake-256");
  expect(body.voice.embeddings).toHaveLength(3);
  for (const vector of body.voice.embeddings) expect(vector).toHaveLength(256);
  expect(posts[0].body.length, "the save is a few KB of numbers, not a recording").toBeLessThan(40000);

  expect(pageErrors, `the page threw: ${pageErrors.join(" | ")}`).toEqual([]);
});

test("a silent take is refused and the phrase stays current", async ({ page }) => {
  await blockOffsiteRequests(page);
  await generatedMicrophone(page, { gain: 0 });

  const row = await openSetup(page);
  await readOnePhrase(row, { heard: false });

  const root = row.locator("[data-studio-controller='voice-profile']");
  await expect(root).toHaveAttribute("data-voice-last-take", "silent");
  await expect(row.locator("[data-voice-status]")).toContainText("I couldn't hear that one");
  await expect(row.locator("[data-voice-phrase]").first()).toHaveAttribute("data-phrase-state", "current");
  await expect(row.getByRole("button", { name: "Save" })).toBeDisabled();
});

test("a saved voice offers Re-record and Delete, and Delete removes it", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.setViewportSize({ width: 390, height: 844 });

  const deletes = [];
  await page.route("**/profile/voice", async (route) => {
    deletes.push({ method: route.request().method(), body: route.request().postData() || "" });
    await route.fulfill({ status: 303, headers: { location: "/lab/voice_profile" } });
  });

  await page.goto("/lab/voice_profile?saved=1");
  const row = page.locator(ROW);
  await expect(row).toContainText("Your voice is set up");
  await expect(row.getByRole("button", { name: "Re-record" })).toBeVisible();

  await row.getByRole("button", { name: "Delete" }).click();
  await page.waitForURL(/\/lab\/voice_profile$/);

  expect(deletes).toHaveLength(1);
  expect(deletes[0].body).toContain("_method=delete");
  await expect(page.locator(ROW).getByRole("button", { name: "Set up your voice" })).toBeVisible();
});
