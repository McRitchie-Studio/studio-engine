const { test, expect } = require("@playwright/test");
const { watchPageErrors } = require("./helpers");

// [e2e] The banner editor on /admin/emails/:key — typing repaints the banner,
// and Save reports whether there is anything to save.
//
// WHY THIS TIER. Both behaviours exist only once a browser has run the
// component. A markup test can assert that an input carries `x-model` and that a
// button carries `:disabled`, and both assertions stay green while the component
// throws on init, or paints the wrong node, or leaves a raw "{name}" on screen.
// The property is what a person SEES after typing, so it is asserted by typing.
//
// WHAT IT PROTECTS. The page repaints the SERVER-RENDERED banner in place rather
// than re-rendering a second copy of the email in JavaScript — the placeholder
// rule is therefore implemented twice, once in Studio::Banner and once here.
// That duplication is deliberate (the alternative is a round trip per keystroke)
// and it is exactly the kind that drifts silently, so the browser side is pinned
// here and the Ruby side in test/integration/banner_copy_test.rb.
test.describe("email banner editor", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/lab/email_banner_editor");
    await page.waitForTimeout(150);
  });

  const bannerHeader = (page) => page.locator("[data-banner-header]").innerText();
  const bannerSubtext = (page) => page.locator("[data-banner-subtext]").innerText();

  test("typing a header repaints the banner", async ({ page }) => {
    const errors = watchPageErrors(page);

    expect((await bannerHeader(page)).trim()).toBe("Welcome Alex!");

    await page.fill("#header", "Good to see you, {name}");
    await page.waitForTimeout(120);

    expect((await bannerHeader(page)).trim()).toBe("Good to see you, Alex");
    expect(errors, errors.join(", ")).toHaveLength(0);
  });

  test("typing sub-text repaints the banner", async ({ page }) => {
    await page.fill("#subtext", "tap the button below");
    await page.waitForTimeout(120);

    expect((await bannerSubtext(page)).trim()).toBe("tap the button below");
  });

  // A raw "{name}" on screen is the most visible way the browser-side rule can
  // diverge from the server's.
  test("no placeholder is ever left unrendered", async ({ page }) => {
    await page.fill("#header", "Hi {name}, welcome to {app}");
    await page.waitForTimeout(120);

    const header = await bannerHeader(page);
    expect(header).not.toContain("{name}");
    expect(header).not.toContain("{app}");
    expect(header.trim()).toBe("Hi Alex, welcome to Studio");
  });

  // The case the fallback header exists for, and the one that is easy to ship
  // broken because the operator previewing it usually has a name on file.
  test("a recipient with no name falls back instead of greeting nobody", async ({ page }) => {
    await page.fill("#header", "Welcome {name}!");
    await page.click("[data-preview-target]");
    await page.click('[data-option-id="member-2"]');
    await page.waitForTimeout(150);

    const header = (await bannerHeader(page)).trim();
    expect(header).toBe("Your Magic Link");
    expect(header).not.toContain("Welcome !");
  });

  test("switching recipient repaints without a reload", async ({ page }) => {
    expect((await bannerHeader(page)).trim()).toBe("Welcome Alex!");

    await page.click("[data-preview-target]");
    await page.click('[data-option-id="member-2"]');
    await page.waitForTimeout(150);
    expect((await bannerHeader(page)).trim()).toBe("Your Magic Link");

    await page.click("[data-preview-target]");
    await page.click('[data-option-id="admin-1"]');
    await page.waitForTimeout(150);
    expect((await bannerHeader(page)).trim()).toBe("Welcome Alex!");
  });

  // The avatar is the reason this is a custom listbox rather than a <select>:
  // a native option cannot carry an image. Asserted for BOTH shapes, because
  // the fallback is the one that renders for a member with no avatar — the
  // common case, and the one that would go unnoticed if it broke.
  test("the recipient picker shows an avatar for each option", async ({ page }) => {
    await expect(page.locator("[data-target-avatar]")).toBeVisible();

    await page.click("[data-preview-target]");
    await page.waitForTimeout(120);

    await expect(page.locator('[data-option-id="admin-1"] [data-option-avatar]')).toBeVisible();
    const initials = page.locator('[data-option-id="member-2"] [data-option-initials]');
    await expect(initials).toBeVisible();
    expect((await initials.innerText()).trim()).toBe("ME");
  });

  test("the subject preview resolves both placeholders", async ({ page }) => {
    const subject = await page.locator("[data-subject-preview]").innerText();

    expect(subject.trim()).toBe("Your Studio sign-in link");
  });

  // --- the one save button reports state ------------------------------------

  // Hidden until touched, then it STAYS. Hiding it again on revert would make it
  // flicker in and out while someone edits, and would hide the very feedback that
  // says "your change has been undone".
  test("save appears on first edit and enables only on a real delta", async ({ page }) => {
    const save = page.locator("[data-save-all]");

    await expect(save).toBeHidden();

    await page.fill("#subtext", "changed");
    await page.waitForTimeout(120);
    await expect(save).toBeVisible();
    await expect(save).toBeEnabled();
  });

  // The case named explicitly: type "A" into the subject and delete it. The
  // button must stay VISIBLE and go back to DISABLED — without this, "dirty"
  // degrades into "has been touched" and the button stops carrying information.
  test("typing and undoing leaves the button visible but disabled", async ({ page }) => {
    const save = page.locator("[data-save-all]");

    await page.fill("#subject", "Your {app} sign-in linkA");
    await page.waitForTimeout(120);
    await expect(save).toBeEnabled();

    await page.fill("#subject", "Your {app} sign-in link");
    await page.waitForTimeout(120);
    await expect(save).toBeVisible();
    await expect(save).toBeDisabled();
    await expect(page.locator("[data-unsaved]")).toBeVisible();
  });

  // --- the tint -------------------------------------------------------------

  // The tint moved into this card from a card of its own, and it repaints live —
  // it is the control that trades a legible greeting against a visible picture,
  // so it has to be judged against the picture while it moves.
  test("the tint repaints the banner as it moves", async ({ page }) => {
    const scrimColor = () => page.evaluate(() =>
      document.querySelector("[data-banner-scrim]").style.backgroundColor);

    const before = await scrimColor();

    await page.fill("[data-scrim-range]", "80");
    await page.waitForTimeout(150);

    const after = await scrimColor();
    expect(after).not.toBe(before);
    expect(after.replace(/\s/g, "")).toContain("0.8");
  });

  test("a tint of zero clears the wash rather than defaulting back", async ({ page }) => {
    await page.fill("[data-scrim-range]", "0");
    await page.waitForTimeout(150);

    const color = await page.evaluate(() =>
      document.querySelector("[data-banner-scrim]").style.backgroundColor);
    expect(color.replace(/\s/g, "")).toContain("0)");
  });

  // --- the copy below the banner --------------------------------------------

  // THE ONE THAT BREAKS SILENTLY. The dirty check compares the form against what
  // the server echoed, and a checkbox holds `true` while the server sends "1" —
  // so without normalisation the page is dirty the moment it loads, and the Save
  // button appears before anyone has typed. Nothing in the markup shows that;
  // only a browser that has run the component can.
  test("a page nobody has touched does not offer to save" , async ({ page }) => {
    await expect(page.locator("[data-save-all]")).toBeHidden();

    await page.click("#cta_enabled");
    await page.click("#cta_enabled");
    await page.waitForTimeout(150);

    await expect(page.locator("[data-save-all]"), "ticking and unticking is not a change")
      .toBeDisabled();
  });

  // Turning the button off dims its fields — a computed style, which is the only
  // form of this a String assertion cannot fake.
  test("the button's fields dim when the button is turned off", async ({ page }) => {
    const opacity = () => page.evaluate(() =>
      getComputedStyle(document.querySelector("[data-cta-fields]")).opacity);

    expect(parseFloat(await opacity())).toBeCloseTo(1, 1);

    await page.uncheck("#cta_enabled");
    await page.waitForTimeout(150);

    expect(parseFloat(await opacity())).toBeLessThan(1);
  });

  test("editing the body marks the page dirty", async ({ page }) => {
    await page.fill("#body", "Different copy entirely.");
    await page.waitForTimeout(150);

    await expect(page.locator("[data-save-all]")).toBeVisible();
    await expect(page.locator("[data-save-all]")).toBeEnabled();
  });

  // --- the logo -------------------------------------------------------------

  test("choosing None hides the logo and Standard brings it back", async ({ page }) => {
    const logo = page.locator("[data-banner-logo]");
    await expect(logo).toBeVisible();

    await page.click("[data-logo-hidden]");
    await page.waitForTimeout(120);
    await expect(logo).toBeHidden();

    await page.click("[data-logo-standard]");
    await page.waitForTimeout(120);
    await expect(logo).toBeVisible();
  });
});
