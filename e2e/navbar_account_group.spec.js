const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// THE ACCOUNT GROUP (engine.css). The gear, the name and the avatar all open
// the link sidebar, so pointing at any one of them lights all three: gear and
// name in the primary colour, a glow on the avatar. It is computed style on
// :has(:hover), which the response bytes cannot show.

const DESKTOP = { width: 1280, height: 800 };
const GEAR = "header [data-nav-tools] [data-link-sidebar-trigger]";
const NAME = "header [data-nav-name]";
const AVATAR = "header [data-nav-account] [aria-hidden] > *";

const lit = (page) => page.evaluate(([gear, name, avatar]) => {
  const probe = document.createElement("span");
  probe.style.color = "var(--color-primary)";
  document.body.appendChild(probe);
  const primary = getComputedStyle(probe).color;
  probe.remove();
  return {
    primary,
    gear: getComputedStyle(document.querySelector(gear)).color,
    name: getComputedStyle(document.querySelector(name)).color,
    glow: getComputedStyle(document.querySelector(avatar)).boxShadow,
  };
}, [GEAR, NAME, AVATAR]);

test("pointing at the gear, the name or the avatar lights all three", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.setViewportSize(DESKTOP);
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/lab/bar_stack?one_row=1&sidebar=1");

  await page.mouse.move(5, 400);
  const rest = await lit(page);
  expect(rest.glow).toBe("none");
  expect(rest.gear).not.toBe(rest.primary);

  for (const target of [GEAR, NAME, AVATAR]) {
    await page.hover(target);
    // The gear and the name fade in over their colour transition.
    await expect.poll(async () => { const on = await lit(page); return [on.gear, on.name]; }, { message: target })
      .toEqual([rest.primary, rest.primary]);
    expect((await lit(page)).glow, target).not.toBe("none");
    if (process.env.ACCOUNT_GROUP_SHOTS) {
      await page.locator("header [data-nav-tools]").locator("..").screenshot({
        path: `${process.env.ACCOUNT_GROUP_SHOTS}/hover-${[GEAR, NAME, AVATAR].indexOf(target)}.png`,
      });
    }
    await page.mouse.move(5, 400);
    await expect.poll(async () => (await lit(page)).glow).toBe("none");
  }
  expect(errors).toEqual([]);
});
