const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The board primitive drags: a card moves between columns, ranks inside a
// lane, and a locked card stays put, on the style guide's own Tasks section.
//
// WHY THIS NEEDS A BROWSER. The board's markup is the same whether it drags or
// not. A drag needs four things to have happened in order, none of them in the
// response: studio/alpine_shims published window.studioBoard before Alpine
// read the x-data; the engine's Stimulus application met
// data-studio-controller="board" and imported the controller; the controller
// imported SortableJS through the "sortablejs" pin; and the board's scope was
// handed the library and made its zones sortable. Break any one and the page
// renders exactly as before and no card moves.
//
// THE SECOND CLAIM is where SortableJS is NOT: no page fetches it until a board
// or a Sortable.create call asks for it.

const board = (page, index) => page.locator("section[data-test='studio-board']").nth(index);

// A board says it is draggable with data-alpine-ready, set once its zones are
// sortable. The Tasks section renders three.
async function boardsAreReady(page) {
  await expect(page.locator("section[data-test='studio-board'][data-alpine-ready='true']")).toHaveCount(3);
}

// SortableJS follows real pointer travel: a move that crosses its drag
// threshold, enough steps to read a direction, and a settle at the target
// before the button comes up.
async function drag(page, card, target, { dropAt = 0.5 } = {}) {
  await card.scrollIntoViewIfNeeded();
  const from = await card.boundingBox();
  const to = await target.boundingBox();
  const startX = from.x + from.width / 2;
  const startY = from.y + from.height / 2;
  const endX = to.x + to.width / 2;
  const endY = to.y + to.height * dropAt;

  await page.mouse.move(startX, startY);
  await page.mouse.down();
  await page.mouse.move(startX, startY - 6, { steps: 3 });
  for (let i = 1; i <= 16; i += 1) {
    const t = i / 16;
    await page.mouse.move(startX + (endX - startX) * t, startY + (endY - startY) * t, { steps: 3 });
  }
  await page.mouse.move(endX, endY, { steps: 3 });
  await page.mouse.up();
}

const idsIn = (zone) => zone.locator(".kanban-card").evaluateAll((cards) => cards.map((card) => card.id));

// Every studio:board-* event the page dispatches, in order.
async function recordBoardEvents(page) {
  await page.addInitScript(() => {
    window.__boardEvents = [];
    ["studio:board-moved", "studio:board-reordered"].forEach((name) => {
      window.addEventListener(name, (event) => window.__boardEvents.push({ name, detail: event.detail }));
    });
  });
}

test.beforeEach(async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.setViewportSize({ width: 1280, height: 1000 });
});

test("a card dragged to another column moves there, toasts and recounts", async ({ page }) => {
  const errors = watchPageErrors(page);
  await recordBoardEvents(page);
  await page.goto("/lab/board");
  await boardsAreReady(page);

  const kanban = board(page, 0);
  await expect(kanban).toHaveAttribute("data-studio-controller", "board");
  const card = kanban.locator("#card-engine-board-primitive");
  const designed = kanban.locator("#dropzone-designed");
  const building = kanban.locator("#dropzone-building");
  await expect(designed.locator(".kanban-card")).toHaveCount(2);
  await expect(building.locator(".kanban-card")).toHaveCount(1);

  await drag(page, card, building.locator(".kanban-card").first());

  await expect(building.locator("#card-engine-board-primitive")).toHaveCount(1);
  await expect(card).toHaveAttribute("data-stage", "building");
  await expect(designed.locator(".kanban-card")).toHaveCount(1);
  await expect(kanban.locator("[data-board-count='building']")).toHaveText("2");
  await expect(kanban.locator("[data-board-count='designed']")).toHaveText("1");
  await expect(kanban.locator("[data-test='studio-board-toasts']")).toContainText("Moved to Building");

  // The move, then the destination's new rank, which holds the card.
  const events = await page.evaluate(() => window.__boardEvents);
  expect(events.map((event) => event.name)).toEqual(["studio:board-moved", "studio:board-reordered"]);
  expect(events[0].detail).toMatchObject({ record: "engine-board-primitive", from: "designed", to: "building" });
  expect(events[1].detail.zone).toBe("building");
  expect(events[1].detail.ids).toContain("engine-board-primitive");
  expect(events[1].detail.ids).toHaveLength(2);

  expect(errors).toEqual([]);
});

test("a depth-chart card ranks inside its lane and does not leave it", async ({ page }) => {
  const errors = watchPageErrors(page);
  await recordBoardEvents(page);
  await page.goto("/lab/board");
  await boardsAreReady(page);

  const depthChart = board(page, 2);
  const quarterbacks = depthChart.locator("#dropzone-QB");
  const runningBacks = depthChart.locator("#dropzone-RB");
  expect(await idsIn(quarterbacks)).toEqual(["card-dc-qb1", "card-dc-qb2", "card-dc-qb3"]);

  // The third string goes above the backup.
  await drag(page, depthChart.locator("#card-dc-qb3"), depthChart.locator("#card-dc-qb2"), { dropAt: 0.2 });
  await expect.poll(() => idsIn(quarterbacks)).toEqual(["card-dc-qb1", "card-dc-qb3", "card-dc-qb2"]);

  const events = await page.evaluate(() => window.__boardEvents);
  expect(events).toHaveLength(1);
  expect(events[0]).toMatchObject({
    name: "studio:board-reordered",
    detail: { zone: "QB", ids: ["dc-qb1", "dc-qb3", "dc-qb2"] }
  });

  // No group: a card carried over another lane drops back into its own.
  await drag(page, depthChart.locator("#card-dc-qb2"), runningBacks.locator(".kanban-card").first());
  expect(await idsIn(runningBacks)).toEqual(["card-dc-rb1", "card-dc-rb2"]);
  expect((await idsIn(quarterbacks)).sort()).toEqual(["card-dc-qb1", "card-dc-qb2", "card-dc-qb3"]);
  const moved = await page.evaluate(() => window.__boardEvents.filter((event) => event.name === "studio:board-moved"));
  expect(moved).toEqual([]);

  expect(errors).toEqual([]);
});

test("a locked card does not drag, and no card is dragged past it", async ({ page }) => {
  const errors = watchPageErrors(page);
  await page.goto("/lab/board");
  await boardsAreReady(page);

  const depthChart = board(page, 2);
  const quarterbacks = depthChart.locator("#dropzone-QB");
  const starter = depthChart.locator("#card-dc-qb1");
  await expect(starter).toHaveClass(/\bkanban-locked\b/);

  await drag(page, starter, depthChart.locator("#card-dc-qb3"), { dropAt: 0.8 });
  expect(await idsIn(quarterbacks)).toEqual(["card-dc-qb1", "card-dc-qb2", "card-dc-qb3"]);

  await drag(page, depthChart.locator("#card-dc-qb3"), starter, { dropAt: 0.2 });
  expect((await idsIn(quarterbacks))[0]).toBe("card-dc-qb1");

  expect(errors).toEqual([]);
});

test("a board's chrome state works on the scope, and its archive column is a drop target", async ({ page }) => {
  const errors = watchPageErrors(page);
  await page.goto("/lab/board");
  await boardsAreReady(page);

  const chrome = board(page, 1);
  const archived = chrome.locator("#dropzone-archived");
  await expect(archived).toBeHidden();
  await chrome.locator("[data-test='chrome-archived-toggle']").click();
  await expect(archived).toBeVisible();

  await drag(page, chrome.locator("#card-chrome-exit-marker"), archived.locator(".kanban-card").first());
  await expect(archived.locator("#card-chrome-exit-marker")).toHaveCount(1);
  await expect(chrome.locator("[data-test='studio-board-toasts']")).toContainText("Moved to Archived");

  expect(errors).toEqual([]);
});

// Every script or module the page asked for whose URL names one of `names`.
function watchRequests(page, names) {
  const seen = [];
  page.on("request", (request) => {
    const path = new URL(request.url()).pathname;
    if (names.some((name) => path.includes(name))) seen.push(path);
  });
  return seen;
}

test("SortableJS and the board controller are fetched only by a page with a board", async ({ page }) => {
  const errors = watchPageErrors(page);
  const fetched = watchRequests(page, ["sortable", "board_controller"]);

  await page.goto("/lab/bar_stack");
  await page.waitForLoadState("networkidle");
  expect(fetched).toEqual([]);
  // The shim stands in for the library, and the factory is published all the same.
  expect(await page.evaluate(() => [typeof window.Sortable, window.Sortable.studioShim, typeof window.studioBoard]))
    .toEqual(["object", true, "function"]);
  await expect(page.locator("link[rel='modulepreload'][href*='board_controller']")).toHaveCount(0);
  await expect(page.locator("script[src*='sortable']")).toHaveCount(0);

  await page.goto("/lab/board");
  await boardsAreReady(page);
  expect(fetched.filter((path) => path.includes("board_controller"))).toHaveLength(1);
  expect(fetched.filter((path) => path.includes("sortable"))).toHaveLength(1);
  expect(await page.evaluate(() => typeof window.Sortable)).toBe("function");

  expect(errors).toEqual([]);
});

test("a page script's Sortable.create loads SortableJS and then creates the sortable", async ({ page }) => {
  const errors = watchPageErrors(page);
  const fetched = watchRequests(page, ["sortable"]);
  await page.goto("/lab/bar_stack");
  await page.waitForLoadState("networkidle");
  expect(fetched).toEqual([]);

  // What a host's inline board script does: one create per zone, in a tick.
  const returned = await page.evaluate(() => {
    const zone = document.createElement("div");
    zone.id = "page-script-zone";
    zone.innerHTML = '<p class="row">one</p><p class="row">two</p>';
    document.body.appendChild(zone);
    return typeof window.Sortable.create(zone, { draggable: ".row", animation: 0 });
  });
  expect(returned).toBe("undefined");

  await expect.poll(() => page.evaluate(() => typeof window.Sortable)).toBe("function");
  await expect
    .poll(() => page.evaluate(() => !!window.Sortable.get(document.getElementById("page-script-zone"))))
    .toBe(true);
  expect(await page.evaluate(() => window.Sortable.get(document.getElementById("page-script-zone")).option("draggable")))
    .toBe(".row");
  expect(fetched).toHaveLength(1);

  expect(errors).toEqual([]);
});
