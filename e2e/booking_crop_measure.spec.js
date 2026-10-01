const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests } = require("./helpers");
const measuring = require("../bin/lib/booking_crop_measure");

// The measuring behind bin/booking-crop-measure (bin/lib/booking_crop_measure.js;
// docs/BOOKING.md), which prints the Hash an app pastes into config.booking_crop.
//
// WHY IT IS IN THE BROWSER LANE. The tool reads a rendered page: where a box
// sits, how tall the document is, what a click on a day redraws. None of that
// exists without a browser.
//
// GOOGLE IS STUBBED, AND THE COMMAND ITSELF IS NEVER RUN HERE. The stub below is
// shaped like Google's embedded appointment page in the ways the tool reads it
// (a <main> holding a table[role=grid] of td[data-date] buttons and a
// [role=list] of [role=listitem] per day, and a "Next month" button), with
// numbers of its own. So this proves the walk and the arithmetic. It does not
// prove Google's page still has that shape: only a run of the command against a
// live schedule does, and that never happens in CI (the command refuses there).

const isGoogle = (url) => url.hostname === "calendar.google.com";
const SCHEDULE = "https://calendar.google.com/calendar/appointments/schedules/LAB-SCHEDULE";

// A 150px header, then the box: 1px border, 20px padding, a 196px month grid
// beside a column of 48px slot rows. Then 92px of credit lines. So the box runs
// from 150 to 150 + 42 + max(196, 48 x slots), and the page ends 92px lower.
//
// Month One opens on day 2 (2 slots: the grid is the taller, box bottom 388).
// Day 3 has 7. Month Two has a day of 9, THE FULLEST, and a day of 1. Month Three
// has nothing to book.
const page_ = (slotHeight = 48) => `<!doctype html><html><body style="margin:0;font:14px sans-serif">
<header style="height:150px">Call with someone</header>
<main style="box-sizing:border-box;margin:0 8px;border:1px solid #ccc;padding:20px">
  <h2 style="margin:0;height:0;overflow:visible">Select an appointment time</h2>
  <button type="button" aria-label="Next month" style="position:absolute;top:0;right:0">next</button>
  <div style="display:flex;align-items:flex-start">
    <table role="grid" style="height:196px;border-collapse:collapse;flex:none"></table>
    <div role="list" style="flex:1"></div>
  </div>
</main>
<footer style="height:92px">Google Calendar appointment scheduling</footer>
<script>
  var MONTHS = [
    { label: "Month One", days: { "20300102": 2, "20300103": 7 } },
    { label: "Month Two", days: { "20300201": 9, "20300202": 1 } },
    { label: "Month Three", days: {} }
  ];
  var month = 0, clicked = [];
  window.__clicked = clicked;
  function draw(selected) {
    var grid = document.querySelector("table"), list = document.querySelector("[role=list]");
    var dates = Object.keys(MONTHS[month].days);
    grid.setAttribute("aria-label", MONTHS[month].label);
    var html = "<tr><th>S</th></tr>";
    for (var row = 0; row < 6; row++) {
      var date = dates[row] || ("2030" + String(month + 1).padStart(2, "0") + String(20 + row));
      var open = dates.indexOf(date) >= 0;
      html += '<tr><td data-date="' + date + '"><button type="button" aria-label="' + (row + 1) + ', Someday' +
              (open ? '' : ', no available times') + '">' + (row + 1) + '</button></td></tr>';
    }
    grid.innerHTML = html;
    var slots = MONTHS[month].days[selected] || 0;
    list.setAttribute("aria-label", "Day " + (selected || "none"));
    list.innerHTML = Array.from({ length: slots }, function (_, i) {
      return '<div role="listitem" style="height:${slotHeight}px">slot ' + i + '</div>';
    }).join("");
    document.querySelector("[aria-label='Next month']").disabled = month === MONTHS.length - 1;
  }
  document.addEventListener("click", function (event) {
    var cell = event.target.closest("td[data-date]");
    if (cell) { clicked.push(cell.dataset.date); var date = cell.dataset.date; setTimeout(function () { draw(date); }, 60); }
    if (event.target.closest("[aria-label='Next month']")) { month += 1; setTimeout(function () { draw(null); }, 60); }
  });
  draw("20300102");
</script></body></html>`;

async function stub(page, body) {
  const asked = [];
  await blockOffsiteRequests(page);
  await page.route(isGoogle, (route) => {
    asked.push(route.request().url());
    return route.fulfill({ contentType: "text/html", body });
  });
  return asked;
}

test("it walks every bookable day and measures the box on the fullest one", async ({ page }) => {
  const asked = await stub(page, page_());

  const [at] = await measuring.measure(page, SCHEDULE, { widths: [862], patience: 3000 });

  // It asked for the embeddable page, and nothing else of Google's.
  expect(asked).toEqual([`${SCHEDULE}?gv=true`]);
  // Every bookable day of both months, and none of the days with no times.
  expect(await page.evaluate(() => window.__clicked)).toEqual(["20300102", "20300103", "20300201", "20300202"]);

  expect(at.top).toBe(150);
  // NOT THE BOX AS IT OPENED (388): the 9-slot day in the SECOND month.
  expect(at.atRest).toEqual({ bottom: 388, slotRows: 2, pageHeight: 480 });
  expect(at.bottom).toBe(150 + 42 + 9 * 48);
  expect(at.pageHeight).toBe(150 + 42 + 9 * 48 + 92);
  expect(at.slotRows).toBe(9);
  expect(at.fullestDay).toBe("Day 20300201");
  expect(at.gridRows).toEqual([6]);
  expect(at.daysWalked).toBe(4);
  // Month Three has nothing to book, so the walk stops before it.
  expect(at.monthsWalked).toBe(2);

  expect(measuring.configLine(measuring.derive([at])))
    .toBe("config.booking_crop = { top: 150, bottom: 624, frame_height: 716 }");
});

test("it measures at both widths and --months bounds the walk", async ({ page }) => {
  await stub(page, page_());

  const measured = await measuring.measure(page, SCHEDULE, { months: 1, patience: 3000 });

  expect(measured.map((at) => at.width)).toEqual([640, 862]);
  // One month only: the fullest day it can see is the 7-slot one.
  measured.forEach((at) => {
    expect(at.monthsWalked).toBe(1);
    expect(at.daysWalked).toBe(2);
    expect(at.slotRows).toBe(7);
    expect(at.bottom).toBe(150 + 42 + 7 * 48);
  });
  const text = measuring.report(SCHEDULE, measured, { today: new Date("2030-01-02T12:00:00Z") });
  expect(text).toContain(`Measured ${SCHEDULE}?gv=true on 2030-01-02`);
  expect(text).toContain("640px wide: box 150-528px, page 620px tall.");
  expect(text).toContain("862px wide: box 150-528px, page 620px tall.");
  expect(text).toContain("month grid: 6 rows. Fullest day: 7 slot rows (Day 20300103).");
  expect(text).toContain("walked 2 bookable days over 1 month(s). As it opened: box bottom 388px, 2 slot rows.");
  expect(text).toContain("config.booking_crop = { top: 150, bottom: 528, frame_height: 620 }");
  expect(text).not.toContain("NOTE:");
});

test("a page that is not shaped like an appointment schedule is refused, not measured", async ({ page }) => {
  await stub(page, "<!doctype html><html><body><div><h2>Select an appointment time</h2></div></body></html>");

  await expect(measuring.measure(page, SCHEDULE, { widths: [862], patience: 400 }))
    .rejects.toThrow(/no <main> holding a table\[role=grid\]/);
});

test("the Hash covers every width measured, and says so only when they really differ", () => {
  const at = (width, top, bottom, pageHeight, more = {}) =>
    ({ width, top, tops: [top], bottom, pageHeight, daysWalked: 5, ...more });

  // The window must hold the box at every width: the highest top, the lowest
  // bottom, the tallest page.
  expect(measuring.derive([at(640, 162, 613, 725), at(862, 163, 600, 730)]))
    .toEqual({ top: 162, bottom: 613, frame_height: 730 });

  // A pixel of rounding is not a different layout.
  expect(measuring.warnings([at(640, 162, 613, 725), at(862, 163, 613, 725)])).toEqual([]);
  expect(measuring.warnings([at(640, 150, 613, 725), at(862, 163, 613, 725)]).join("\n"))
    .toContain("sits differently at the widths measured");
  expect(measuring.warnings([at(640, 150, 613, 725, { tops: [150, 190] })]).join("\n"))
    .toContain("top moved between 150 and 190px");
  expect(measuring.warnings([at(640, 150, 613, 725, { daysWalked: 0 })]).join("\n"))
    .toContain("no bookable day was found");

  // gv=true is added once, however the link was pasted.
  expect(measuring.embedUrl(SCHEDULE)).toBe(`${SCHEDULE}?gv=true`);
  expect(measuring.embedUrl(`${SCHEDULE}?gv=true&hl=en`)).toBe(`${SCHEDULE}?hl=en&gv=true`);
});
