const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] DEFECT 3 — the re-stamper swallowed by a phantom element
// (propagate-at-format-gem).
//
// THE BUG. studio/_at_time_script's header comment carried the adoption snippet. An
// ERB comment ends at the FIRST `%>` whatever it sits inside, so the comment
// terminated mid-sentence and the remaining prose rendered as page text. That prose
// contained a literal script open tag; the HTML tokenizer built a real
// HTMLScriptElement from it and switched to raw-text state, which consumes bytes
// verbatim until the first `</script`. So the phantom element SWALLOWED the real
// script whole — the browser then executed English prose and threw a SyntaxError,
// and the re-stamper never ran on any page of any host that followed the recipe.
//
// AND THE SHARPEST FACT IN THIS WHOLE LANE. The guard test written to catch exactly
// this was `assert_includes html, "__atTimeFmt"` — and it PASSED on the broken page,
// because the token survived INSIDE the text the phantom element ate. The test
// written to catch "stamps without a working script" was itself an instance of the
// disease it named.
//
// WHY THIS IS THE LANE'S BEST TEST. The server's response bytes are IDENTICAL
// whether the script runs or not: it always renders the app-timezone clock with the
// flag hidden, because it cannot know where the reader sits. So every assertion a
// Rails view test can make is green on a page whose client half is dead. Only a
// browser sitting in a real timezone can tell the two apart — and the difference is
// the whole feature.
//
// The fixed epoch is 1773491640 = 2026-03-14 12:34:00 UTC, rendered by the server as
// "at 12:34p" with no flag (see test/dummy/app/views/e2e_lab/at_time.html.erb).

const STAMP = "[data-at-stamp]";

test("a viewer abroad sees their own clock and their country's flag", async ({ browser }) => {
  // Tokyo is UTC+9 with NO daylight saving, so 12:34 UTC is 21:34 JST every day of
  // the year. A zone with DST would make this assertion a date-dependent time bomb.
  const context = await browser.newContext({ timezoneId: "Asia/Tokyo" });
  const page = await context.newPage();
  const pageErrors = watchPageErrors(page);

  await blockOffsiteRequests(page);
  await page.goto("/lab/at_time");

  // data-at-zone is written ONLY by stamp(). Its presence is the completion receipt
  // — the single crispest signal that the script did not merely parse but RAN.
  await expect(page.locator(STAMP)).toHaveAttribute("data-at-zone", "Asia/Tokyo");

  // The payoff assertion. The server said "12:34p"; a browser in Tokyo must say
  // "9:34p". No server-side tier can produce this string, and the broken page shows
  // the server's.
  //
  // The CLOCK is asserted, not the whole label. The label also carries a date once
  // the stamp is not today's ("at Mar 14, 9:34p"), and its year appears once the
  // stamp is not this year — so pinning the full string would arm a time bomb that
  // reddens this lane on 2027-01-01 for no defect at all. The clock is the part the
  // viewer's timezone determines, which is the part under test.
  const abroad = page.locator(`${STAMP} [data-at-text]`);
  await expect(abroad).toContainText("9:34p");
  await expect(
    abroad,
    "the stamp still reads the SERVER's clock — the re-stamper did not run"
  ).not.toContainText("12:34p");

  await expect(page.locator(`${STAMP} [data-at-flag]`)).toBeVisible();
  await expect(page.locator(`${STAMP} [data-at-flag]`)).toHaveText("🇯🇵");

  // The phantom element threw a SyntaxError on every load. Assert the absence.
  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);

  await context.close();
});

test("a viewer inside the US sees their own clock and no flag", async ({ browser }) => {
  // The flag is a signal; one that fired on every stamp would carry none. This is
  // the half that proves the flag is CONDITIONAL rather than simply absent — a dead
  // script also shows no flag, so "no flag" alone proves nothing, which is why the
  // clock is asserted alongside it.
  const context = await browser.newContext({ timezoneId: "America/Chicago" });
  const page = await context.newPage();
  const pageErrors = watchPageErrors(page);

  await blockOffsiteRequests(page);
  await page.goto("/lab/at_time");

  await expect(page.locator(STAMP)).toHaveAttribute("data-at-zone", "America/Chicago");
  // 12:34 UTC on 2026-03-14 is 07:34 CDT (US daylight time began 2026-03-08).
  const home = page.locator(`${STAMP} [data-at-text]`);
  await expect(home).toContainText("7:34a");
  await expect(home, "the stamp still reads the SERVER's clock").not.toContainText("12:34p");
  await expect(page.locator(`${STAMP} [data-at-flag]`)).toBeHidden();

  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);

  await context.close();
});

// The structural tell, asserted the way the FIXED guard learned to: not "the token
// appears in the markup" (which was green on the broken page) but "the element
// carrying the program BEGINS with the program". Leaked prose ahead of the open tag
// fails this, and so does a phantom element, because the phantom's text starts with
// English.
test("the re-stamper's script element begins with its own program", async ({ page }) => {
  await page.goto("/lab/at_time");

  const ran = await page.evaluate(() => window.__atTimeFmt === true);
  expect(ran, "window.__atTimeFmt is not set — the re-stamper never executed").toBe(true);

  const leading = await page.evaluate(() => {
    const script = Array.from(document.querySelectorAll("script")).find((el) =>
      el.textContent.includes("__atTimeFmt")
    );
    return script ? script.textContent.trimStart().slice(0, 40) : null;
  });

  expect(
    leading,
    `the script carrying the re-stamper begins with ${JSON.stringify(leading)}. Anything ` +
      "other than its IIFE means prose leaked ahead of the open tag."
  ).toMatch(/^\(function\s*\(\s*\)\s*\{/);
});
