// bin/lib/booking_crop_measure.js — the measuring behind bin/booking-crop-measure.
//
// WHAT IT MEASURES. config.booking_crop wants three numbers from Google's
// embedded appointment page (docs/BOOKING.md): the top of the "Select an
// appointment time" box, its bottom ON ITS FULLEST DAY, and the page's height on
// that day. The top is fixed by the schedule's header. The bottom is not: the box
// is as tall as the month grid or the longest column of appointment slots,
// whichever is taller, and a day that is partly booked or partly over has fewer
// slots than a free one. So one look at the page measures today, not the
// schedule. This walks every bookable day of the months ahead and keeps the
// tallest box and the tallest page it saw.
//
// HOW IT FINDS THINGS. By role and attribute, never by Google's class names,
// which are generated and change: the box is the page's <main>, the month is
// table[role=grid] with a td[data-date] per day, each day's slots are a
// [role=list] of [role=listitem], and the month advances with the "Next month"
// button. If Google restructures the page this throws, and says what it could
// not find, rather than print numbers from the wrong element.
//
// The functions take a Playwright `page`, so the browser lane can drive them
// against a stub (e2e/booking_crop_measure.spec.js). Nothing here opens a
// browser or reaches Google on its own.

const EMBED_PARAM = "gv=true";
const WIDTHS = [640, 862];
const DEFAULT_MONTHS = 3;
// Short on purpose: a document's scrollHeight is never less than its viewport,
// so a tall viewport would report its own height as the page's.
const VIEWPORT_HEIGHT = 400;

function embedUrl(url) {
  const [base, query = ""] = String(url).trim().split("?");
  const kept = query.split("&").filter((pair) => pair && pair !== EMBED_PARAM);
  return `${base}?${kept.concat(EMBED_PARAM).join("&")}`;
}

// One look at the page as it stands. Runs in the page.
function snapshot() {
  const box = document.querySelector("main");
  const grid = box && box.querySelector("table[role=grid]");
  if (!box || !grid) return null;
  const rect = box.getBoundingClientRect();
  const lists = Array.from(box.querySelectorAll("[role=list]"));
  const slots = lists.map((list) => list.querySelectorAll("[role=listitem]").length);
  const fullest = slots.indexOf(Math.max(0, ...slots));
  return {
    top: Math.round(rect.top + window.scrollY),
    bottom: Math.round(rect.bottom + window.scrollY),
    pageHeight: document.documentElement.scrollHeight,
    gridRows: Array.from(grid.querySelectorAll("tr")).filter((row) => row.querySelector("td[data-date]")).length,
    slotRows: Math.max(0, ...slots),
    fullestDay: fullest >= 0 && lists[fullest] ? lists[fullest].getAttribute("aria-label") : null,
    month: grid.getAttribute("aria-label"),
  };
}

// The page redraws after a click; wait until two looks in a row agree.
async function settled(page, limit = 40) {
  let last = null;
  for (let tries = 0; tries < limit; tries += 1) {
    await page.waitForTimeout(120);
    const now = await page.evaluate(snapshot);
    if (now && last && JSON.stringify(now) === JSON.stringify(last)) return now;
    last = now;
  }
  if (!last) {
    throw new Error("Google's page has no <main> holding a table[role=grid]: its layout has changed, or this is not an appointment schedule.");
  }
  return last;
}

// The bookable days in the month on show, as data-date values.
function bookableDays() {
  const cells = Array.from(document.querySelectorAll("main table[role=grid] td[data-date]"));
  const labelled = cells.some((cell) => /no available times/i.test(cell.querySelector("button")?.getAttribute("aria-label") || ""));
  return cells
    .filter((cell) => {
      const button = cell.querySelector("button");
      if (!button || button.disabled) return false;
      return !labelled || !/no available times/i.test(button.getAttribute("aria-label") || "");
    })
    .map((cell) => cell.getAttribute("data-date"));
}

// Walk the bookable days of `months` months at one frame width.
// `patience` is how long to wait for Google's page to draw, in milliseconds.
async function measureAt(page, url, width, { months = DEFAULT_MONTHS, patience = 30000 } = {}) {
  await page.setViewportSize({ width, height: VIEWPORT_HEIGHT });
  await page.goto(embedUrl(url), { waitUntil: "load" });
  await page.locator("main table[role=grid]").first().waitFor({ state: "visible", timeout: patience }).catch(() => {});

  const views = [await settled(page, Math.max(3, Math.ceil(patience / 750)))];
  let days = 0;
  let monthsWalked = 0;
  for (let month = 0; month < months; month += 1) {
    const dates = await page.evaluate(bookableDays);
    if (month > 0 && dates.length === 0) break;
    monthsWalked += 1;
    for (const date of dates) {
      await page.locator(`main table[role=grid] td[data-date="${date}"] button`).first().click();
      views.push(await settled(page));
      days += 1;
    }
    const next = page.getByRole("button", { name: "Next month" });
    if ((await next.count()) === 0 || (await next.first().isDisabled())) break;
    if (month + 1 < months) {
      await next.first().click();
      views.push(await settled(page));
    }
  }

  const fullest = views.reduce((best, view) => (view.bottom > best.bottom ? view : best), views[0]);
  const tops = Array.from(new Set(views.map((view) => view.top))).sort((a, b) => a - b);
  return {
    width,
    top: tops[0],
    tops,
    bottom: fullest.bottom,
    pageHeight: Math.max(...views.map((view) => view.pageHeight)),
    atRest: { bottom: views[0].bottom, slotRows: views[0].slotRows, pageHeight: views[0].pageHeight },
    gridRows: Array.from(new Set(views.map((view) => view.gridRows))).sort((a, b) => a - b),
    slotRows: Math.max(...views.map((view) => view.slotRows)),
    fullestDay: fullest.fullestDay,
    daysWalked: days,
    monthsWalked,
  };
}

async function measure(page, url, { widths = WIDTHS, ...options } = {}) {
  const measured = [];
  for (const width of widths) measured.push(await measureAt(page, url, width, options));
  return measured;
}

// The Hash to declare: the highest top, the lowest bottom and the tallest page
// across the widths measured, so the window holds the box at every one of them.
function derive(measured) {
  return {
    top: Math.min(...measured.map((at) => at.top)),
    bottom: Math.max(...measured.map((at) => at.bottom)),
    frame_height: Math.max(...measured.map((at) => at.pageHeight)),
  };
}

function configLine(crop) {
  return `config.booking_crop = { top: ${crop.top}, bottom: ${crop.bottom}, frame_height: ${crop.frame_height} }`;
}

// A pixel either way is rounding (Google positions the box on half pixels), not
// a different layout, and is not worth a note.
const ROUNDING = 2;

function warnings(measured) {
  const notes = [];
  const spread = (values) => Math.max(...values) - Math.min(...values);
  measured.forEach((at) => {
    if (spread(at.tops) > ROUNDING) notes.push(`at ${at.width}px the box's top moved between ${at.tops[0]} and ${at.tops[at.tops.length - 1]}px while walking; the highest is used, so the window may show a strip above the box.`);
    if (at.daysWalked === 0) notes.push(`at ${at.width}px no bookable day was found, so only the page as it opened was measured. Measure again when the schedule has open days.`);
  });
  if (spread(measured.map((at) => at.top)) > ROUNDING || spread(measured.map((at) => at.bottom)) > ROUNDING) {
    notes.push("the box sits differently at the widths measured; the Hash covers all of them, so one of them shows a little more than the box.");
  }
  return notes;
}

function report(url, measured, { today = new Date() } = {}) {
  const lines = [`Measured ${embedUrl(url)} on ${today.toISOString().slice(0, 10)}`, ""];
  measured.forEach((at) => {
    lines.push(
      `  ${at.width}px wide: box ${at.top}-${at.bottom}px, page ${at.pageHeight}px tall.`,
      `    month grid: ${at.gridRows.join(" or ")} rows. Fullest day: ${at.slotRows} slot rows` +
        (at.fullestDay ? ` (${at.fullestDay}).` : "."),
      `    walked ${at.daysWalked} bookable days over ${at.monthsWalked} month(s). As it opened: box bottom ${at.atRest.bottom}px, ${at.atRest.slotRows} slot rows.`
    );
  });
  warnings(measured).forEach((note) => lines.push("", `  NOTE: ${note}`));
  lines.push("", "Paste into config/initializers/studio.rb:", "", `  ${configLine(derive(measured))}`, "");
  lines.push("Measure again when the schedule's title, description or meeting details change (they move the");
  lines.push("top), or when a day can hold more appointment slots than the fullest day above (that moves the bottom).");
  return lines.join("\n");
}

module.exports = { WIDTHS, DEFAULT_MONTHS, embedUrl, measure, measureAt, derive, configLine, warnings, report };
