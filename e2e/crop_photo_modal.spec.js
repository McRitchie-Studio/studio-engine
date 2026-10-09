const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The crop-photo modal (studio/modals/_crop_photo) on its module scope,
// studio/cropper: it mounts Cropper.js at the ratio its opener asks for, locks
// while a crop is in progress, hands the cropped PNG to its opener, and says so
// when Cropper.js never arrives instead of taking a press that does nothing.
//
// /lab/style_modals renders the style guide's Modals section, whose page-scoped
// host mounts the real crop card on $store.dsModals. No lab page loads
// Cropper.js itself: it comes from cdnjs, and the lane answers every off-site
// request with an empty 200. So "the library never arrived" is this lane's
// natural state, and the specs that need a cropper answer that one request with
// a stand-in that records how it was constructed and exports a real canvas.
// What is under test is the engine's scope around the library, not the library.
//
// CONTROLS, each run against this file:
//   - construct Cropper with `aspectRatio: 1 / settings.aspectRatio`
//     (cropperOptions): the first spec fails at the ratio.
//   - return from the missing-library branch without setting the error: the
//     last spec fails, the card showing nothing.

const CROPPER_JS = /cdnjs\.cloudflare\.com\/ajax\/libs\/cropperjs\/.*cropper\.min\.js/;
const CARD = '[role="dialog"]';
const SAVE = `${CARD} button.btn-primary`;
const CANCEL = `${CARD} button:has-text("Cancel")`;
// A 2x2 PNG, so the card has a real image to hand the cropper.
const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR42mNk+M9Qz0AEYBxVSF+FAP5FDvcfRYWgAAAAAElFTkSuQmCC";
const DATA_URL = `data:image/png;base64,${PNG}`;

const STAND_IN = `
  window.Cropper = class {
    constructor(image, options) {
      window.__cropper = { options, source: image.getAttribute("src"), destroyed: false, built: (window.__cropper ? window.__cropper.built : 0) + 1 };
    }
    destroy() { window.__cropper.destroyed = true; }
    getCroppedCanvas(options) {
      window.__cropper.exported = options;
      const canvas = document.createElement("canvas");
      canvas.width = 8; canvas.height = 8;
      canvas.getContext("2d").fillRect(0, 0, 8, 8);
      return canvas;
    }
  };
`;

async function withCropper(page) {
  await blockOffsiteRequests(page);
  await page.route(CROPPER_JS, (route) => route.fulfill({ status: 200, contentType: "application/javascript", body: STAND_IN }));
}

// Records every crop-photo-confirmed the page hears, as plain data.
async function hearConfirms(page) {
  await page.evaluate(() => {
    window.__confirmed = [];
    window.addEventListener("crop-photo-confirmed", (event) => {
      const { blob, owner, filename, uncropped } = event.detail;
      window.__confirmed.push({ type: blob && blob.type, size: blob && blob.size, isBlob: blob instanceof Blob, owner, filename, uncropped });
    });
  });
}

const entry = (page) =>
  page.evaluate(() => {
    const current = Alpine.store("dsModals").current();
    return current ? { id: current.id, dismissible: current.props.dismissible, cropReady: current.props.cropReady } : null;
  });

test("an opener's image goes straight to the cropper at the asked ratio, and the crop locks the modal", async ({ page }) => {
  const errors = watchPageErrors(page);
  await withCropper(page);
  await page.goto("/lab/style_modals");
  await hearConfirms(page);

  await page.evaluate((imageUrl) => {
    Alpine.store("dsModals").open("crop-photo", { imageUrl, aspectRatio: 3, maxWidth: 900, transparent: false, owner: "iuh-lab" });
  }, DATA_URL);

  await expect(page.locator(SAVE)).toHaveText("Crop & Save");
  await expect.poll(() => page.evaluate(() => window.__cropper && window.__cropper.options.aspectRatio)).toBe(3);
  expect(await page.evaluate(() => window.__cropper.source)).toBe(DATA_URL);
  expect(await entry(page)).toEqual({ id: "crop-photo", dismissible: false, cropReady: true });

  // Locked: Escape does not discard a crop in progress.
  await page.keyboard.press("Escape");
  await page.waitForTimeout(400);
  expect(await entry(page), "Escape closed a modal with a crop in progress").not.toBeNull();

  await page.locator(SAVE).click();
  await expect.poll(() => page.evaluate(() => window.__confirmed.length)).toBe(1);
  const [confirmed] = await page.evaluate(() => window.__confirmed);
  expect(confirmed.isBlob).toBe(true);
  expect(confirmed.type).toBe("image/png");
  expect(confirmed.size).toBeGreaterThan(0);
  expect(confirmed.owner).toBe("iuh-lab");
  expect(await page.evaluate(() => window.__cropper.exported)).toEqual({ maxWidth: 900, imageSmoothingQuality: "high", fillColor: "#ffffff" });
  expect(await page.evaluate(() => window.__cropper.destroyed)).toBe(true);

  // Not in dispatch mode: the card closes itself.
  await expect.poll(() => entry(page)).toBeNull();
  expect(errors).toEqual([]);
});

test("Cancel releases the cropper, closes the card and confirms nothing", async ({ page }) => {
  await withCropper(page);
  await page.goto("/lab/style_modals");
  await hearConfirms(page);

  await page.evaluate((imageUrl) => Alpine.store("dsModals").open("crop-photo", { imageUrl }), DATA_URL);
  await expect.poll(() => page.evaluate(() => !!window.__cropper)).toBe(true);

  await page.locator(CANCEL).click();
  await expect.poll(() => entry(page)).toBeNull();
  expect(await page.evaluate(() => window.__cropper.destroyed)).toBe(true);
  expect(await page.evaluate(() => window.__confirmed)).toEqual([]);
});

test("with no image the card is the picker, and a picked file becomes the crop", async ({ page }) => {
  await withCropper(page);
  await page.goto("/lab/style_modals");

  await page.evaluate(() => Alpine.store("dsModals").open("crop-photo", {}));
  await expect(page.locator(SAVE)).toHaveText("Upload an Image to Continue");
  await expect(page.locator(SAVE)).toBeDisabled();
  expect((await entry(page)).cropReady, "an empty picker is not a crop in progress").toBeFalsy();

  await page.locator(`${CARD} input[type="file"]`).setInputFiles({ name: "me.png", mimeType: "image/png", buffer: Buffer.from(PNG, "base64") });

  await expect(page.locator(SAVE)).toHaveText("Crop & Save");
  await expect(page.locator(SAVE)).toBeEnabled();
  await expect.poll(() => page.evaluate(() => window.__cropper && window.__cropper.options.aspectRatio)).toBe(1);
  expect(await entry(page)).toEqual({ id: "crop-photo", dismissible: false, cropReady: true });
});

test("a file that is no image is refused on the card's own line", async ({ page }) => {
  await withCropper(page);
  await page.goto("/lab/style_modals");
  await page.evaluate(() => Alpine.store("dsModals").open("crop-photo", {}));

  await page.locator(`${CARD} input[type="file"]`).setInputFiles({ name: "notes.txt", mimeType: "text/plain", buffer: Buffer.from("hello") });
  await expect(page.locator(`${CARD} [role="alert"]`)).toHaveText("Please choose an image file.");
  await expect(page.locator(SAVE)).toBeDisabled();

  await page.locator(`${CARD} input[type="file"]`).setInputFiles({ name: "party.gif", mimeType: "image/gif", buffer: Buffer.from("GIF89a") });
  await expect(page.locator(`${CARD} [role="alert"]`)).toHaveText("GIFs aren't accepted here. Use a PNG, JPG or WebP.");
});

test("when Cropper.js never arrives the card says so, stays dismissible and confirms nothing", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/style_modals");
  await hearConfirms(page);
  expect(await page.evaluate(() => typeof window.Cropper), "this lane loaded a real Cropper.js").toBe("undefined");

  await page.evaluate((imageUrl) => Alpine.store("dsModals").open("crop-photo", { imageUrl }), DATA_URL);
  await expect(page.locator(SAVE)).toHaveText("Crop & Save");
  await expect(page.locator(`${CARD} [role="alert"]`)).toHaveCount(0);

  // The scope waits a few seconds for a late script, then reports.
  await expect(page.locator(`${CARD} [role="alert"]`)).toHaveText(
    "The photo cropper did not load. Reload the page and try again.", { timeout: 8_000 }
  );

  await page.locator(SAVE).click();
  expect(await page.evaluate(() => window.__confirmed)).toEqual([]);
  expect((await entry(page)).dismissible, "a card with no cropper must not be locked open").not.toBe(false);

  await page.locator(CANCEL).click();
  await expect.poll(() => entry(page)).toBeNull();
});
