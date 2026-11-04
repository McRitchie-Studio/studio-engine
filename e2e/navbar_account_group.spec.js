const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// THE ACCOUNT GROUP (engine.css). The gear, the name and the avatar all open
// the link sidebar, so pointing at any one of them lights all three: gear and
// name in the primary colour, a glow on the avatar. It is computed style on
// :has(:hover), which the response bytes cannot show. The hover half sits inside
// @media (hover: hover): a tap leaves :hover on what was tapped, and on a touch
// screen nothing else takes it away, so the group stayed lit after the sidebar
// closed. The touch specs at the end hold that.

const DESKTOP = { width: 1280, height: 800 };
const GEAR = "header [data-nav-tools] [data-link-sidebar-trigger]";
const NAME = "header [data-nav-name]";
const AVATAR = "header [data-nav-account] [aria-hidden] > *";
const ACCOUNT = "header [data-nav-account]";
const HOST_GEAR = "header [data-nav-tools] [data-nav-menu-trigger] [aria-controls]";

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
    turn: getComputedStyle(document.querySelector(`${gear} svg`)).transform,
  };
}, [GEAR, NAME, AVATAR]);

// Waits out every running CSS transition, then reads. A poll for the resting
// value would pass at once on a defect that is still fading in: the avatar's glow
// starts at "none" and the gear's colour starts at rest.
const transitionsDone = (page) => page.evaluate(async () => {
  document.body.getBoundingClientRect();
  await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  const running = document.getAnimations().filter((a) => a instanceof CSSTransition);
  await Promise.allSettled(running.map((a) => a.finished));
});
const settled = async (page) => {
  await transitionsDone(page);
  return lit(page);
};

// Rewires the lab's page to the markup the engine renders for
// Studio.navbar_menu_trigger + Studio.navbar_account_sidebar
// (test/integration/navbar_account_sidebar_render_test.rb pins that markup).
const rewireToHostSidebar = (page) => page.evaluate((gear) => {
  const engineGear = document.querySelector(gear);
  const seat = document.createElement("span");
  seat.setAttribute("data-nav-menu-trigger", "");
  const hostGear = engineGear.cloneNode(true);
  hostGear.removeAttribute("data-link-sidebar-trigger");
  hostGear.setAttribute("aria-controls", "gear-sidebar gear-sidebar-mobile");
  seat.appendChild(hostGear);
  engineGear.replaceWith(seat);
  document.querySelector("header [data-nav-account]").setAttribute("aria-controls", "gear-sidebar gear-sidebar-mobile");
}, GEAR);

// Tabs forward to a control and proves it took keyboard focus.
const tabTo = async (page, target) => {
  for (let tab = 0; tab < 40; tab++) {
    await page.keyboard.press("Tab");
    if (await page.evaluate((selector) => document.activeElement.matches(selector), target)) break;
  }
  expect(await page.evaluate((selector) => document.activeElement.matches(`${selector}:focus-visible`), target), target).toBe(true);
};

const primaryColour = (page) => page.evaluate(() => {
  const probe = document.createElement("span");
  probe.style.color = "var(--color-primary)";
  document.body.appendChild(probe);
  const primary = getComputedStyle(probe).color;
  probe.remove();
  return primary;
});

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

// Keyboard focus lights the group where pointing does: the account control is
// one tab stop, and it takes the highlight the name's hover gives.
test("keyboard focus on the account lights the group as hovering the name does", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.setViewportSize(DESKTOP);
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/lab/bar_stack?one_row=1&sidebar=1");
  await page.mouse.move(5, 400);

  await page.hover(NAME);
  await expect.poll(async () => (await lit(page)).name).toBe((await lit(page)).primary);
  const hovered = await lit(page);
  await page.mouse.move(5, 400);
  await expect.poll(async () => (await lit(page)).glow).toBe("none");

  // The rail's gear comes before the account in the tab order.
  await tabTo(page, GEAR);
  await expect.poll(() => lit(page)).toEqual(hovered);
  await tabTo(page, ACCOUNT);
  await expect.poll(() => lit(page)).toEqual(hovered);
});

// AN ACCOUNT LINK (no sidebar): the name and avatar are one link, and pointing at
// either lights the name. There is no avatar glow to share in this shape. The lab's
// account opens the sidebar, so dropping aria-controls takes it out of the group, as
// a link is (test/views/user_nav_test.rb pins the link's markup); then only the
// name's group-hover can light it.
test("an account link lights the name from the name and from the avatar", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.setViewportSize(DESKTOP);
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/lab/bar_stack?one_row=1");
  await page.evaluate(() => document.querySelector("header [data-nav-account]").removeAttribute("aria-controls"));
  const color = () => page.evaluate((name) => getComputedStyle(document.querySelector(name)).color, NAME);
  const primary = await primaryColour(page);

  await page.mouse.move(5, 400);
  const rest = await color();
  expect(rest).not.toBe(primary);
  for (const target of [NAME, AVATAR]) {
    await page.hover(target);
    await expect.poll(color, { message: target }).toBe(primary);
    await page.mouse.move(5, 400);
    await expect.poll(color).toBe(rest);
  }
});

// A HOST SIDEBAR (Turf Monster's shape): the host's gear in the menu trigger
// seat and an account that opens the host's sidebar. The lab draws the link
// sidebar, so the page is rewired (rewireToHostSidebar).
test("a host sidebar's gear and account light together too", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.setViewportSize(DESKTOP);
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/lab/bar_stack?one_row=1&sidebar=1");
  const primary = (await lit(page)).primary;

  await rewireToHostSidebar(page);

  const read = () => page.evaluate(([gear, name, avatar]) => ({
    gear: getComputedStyle(document.querySelector(gear)).color,
    name: getComputedStyle(document.querySelector(name)).color,
    glow: getComputedStyle(document.querySelector(avatar)).boxShadow,
  }), [HOST_GEAR, NAME, AVATAR]);

  await page.mouse.move(5, 400);
  expect((await read()).glow).toBe("none");

  for (const target of [HOST_GEAR, NAME, AVATAR]) {
    await page.hover(target);
    await expect.poll(async () => { const on = await read(); return [on.gear, on.name]; }, { message: target })
      .toEqual([primary, primary]);
    expect((await read()).glow, target).not.toBe("none");
    await page.mouse.move(5, 400);
    await expect.poll(async () => (await read()).glow).toBe("none");
  }
  expect(errors).toEqual([]);
});

// Keyboard focus is not pointing, so it stays outside the hover guard for a host
// sidebar as for the link sidebar above.
test("keyboard focus on a host sidebar's gear or account lights the group too", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.setViewportSize(DESKTOP);
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/lab/bar_stack?one_row=1&sidebar=1");
  await page.mouse.move(5, 400);
  await rewireToHostSidebar(page);
  const read = () => page.evaluate(([gear, name, avatar]) => ({
    gear: getComputedStyle(document.querySelector(gear)).color,
    name: getComputedStyle(document.querySelector(name)).color,
    glow: getComputedStyle(document.querySelector(avatar)).boxShadow,
  }), [HOST_GEAR, NAME, AVATAR]);
  const primary = await primaryColour(page);

  for (const target of [HOST_GEAR, ACCOUNT]) {
    await tabTo(page, target);
    await expect.poll(async () => { const on = await read(); return [on.gear, on.name]; }, { message: target }).toEqual([primary, primary]);
    expect((await read()).glow, target).not.toBe("none");
  }
});

// THE TOUCH SCREEN. Alex McRitchie, 2026-11-03: "after you close the modal on mobile
// the class should be removed... there is no hover on phones." Each spec first
// proves its premise: the browser reports no hover, and the tapped control really
// does still match :hover. Without that, a browser that clears :hover on its own
// would pass these specs with the guard gone. They leave motion at its default, so
// the gear's turn is read as well.
const expectNoHoverDevice = async (page) => {
  expect(await page.evaluate(() => matchMedia("(hover: none)").matches), "the device reports no hover").toBe(true);
};
const stillHovered = (page, target) => page.evaluate((selector) => document.querySelector(selector).matches(":hover"), target);
const sidebarOpen = (page) => page.evaluate(() => window.Alpine.store("sidebars").linkTreeOpen);

test.describe("on a touch tablet, where the rail shows the gear and the name", () => {
  test.use({ viewport: { width: 1024, height: 768 }, hasTouch: true, isMobile: true });

  test("tapping a control open and closed leaves nothing lit", async ({ page }) => {
    await blockOffsiteRequests(page);
    const errors = watchPageErrors(page);
    await page.goto("/lab/bar_stack?one_row=1&sidebar=1");
    await expectNoHoverDevice(page);
    const rest = await settled(page);
    expect(rest.glow).toBe("none");
    expect(rest.gear).not.toBe(rest.primary);

    for (const target of [GEAR, NAME, AVATAR]) {
      await page.tap(target);
      await expect.poll(() => sidebarOpen(page), { message: target }).toBe(true);
      expect(await settled(page), `${target}, open`).toEqual(rest);

      await page.tap(target);
      await expect.poll(() => sidebarOpen(page), { message: target }).toBe(false);
      expect(await stillHovered(page, target), `${target} keeps :hover`).toBe(true);
      expect(await settled(page), `${target}, closed`).toEqual(rest);
    }
    expect(errors).toEqual([]);
  });

  test("tapping a host sidebar's gear or account leaves nothing lit", async ({ page }) => {
    await blockOffsiteRequests(page);
    await page.goto("/lab/bar_stack?one_row=1&sidebar=1");
    await expectNoHoverDevice(page);
    await rewireToHostSidebar(page);
    const read = () => page.evaluate(([gear, name, avatar]) => ({
      gear: getComputedStyle(document.querySelector(gear)).color,
      name: getComputedStyle(document.querySelector(name)).color,
      glow: getComputedStyle(document.querySelector(avatar)).boxShadow,
      turn: getComputedStyle(document.querySelector(`${gear} svg`)).transform,
    }), [HOST_GEAR, NAME, AVATAR]);
    const rest = await read();

    for (const target of [HOST_GEAR, ACCOUNT]) {
      await page.tap(target);
      expect(await stillHovered(page, target), `${target} keeps :hover`).toBe(true);
      await transitionsDone(page);
      expect(await read(), target).toEqual(rest);
    }
  });
});

test.describe("on a phone, where the avatar stands alone", () => {
  test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });

  test("tapping the avatar open and closed leaves nothing lit", async ({ page }) => {
    await blockOffsiteRequests(page);
    const errors = watchPageErrors(page);
    await page.goto("/lab/bar_stack?one_row=1&sidebar=1");
    await expectNoHoverDevice(page);
    const rest = await settled(page);
    expect(rest.glow).toBe("none");

    await page.tap(AVATAR);
    await expect.poll(() => sidebarOpen(page)).toBe(true);
    await page.tap(AVATAR);
    await expect.poll(() => sidebarOpen(page)).toBe(false);
    expect(await stillHovered(page, AVATAR), "the avatar keeps :hover").toBe(true);
    expect(await settled(page)).toEqual(rest);
    expect(errors).toEqual([]);
  });
});
