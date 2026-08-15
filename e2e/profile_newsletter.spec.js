const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The newsletter row's confirmation, and the modal host that had to appear
// for it to have anywhere to open.
//
// WHY A BROWSER. The view suite can assert that the Unsubscribe button carries
// `@click="$store.profileModals.open('newsletter-unsubscribe')"`. That string is
// in the markup whether or not the store exists, whether or not the host mounted,
// and whether or not the id matches a registered template — three separate ways
// for the click to do nothing at all, none of which change a single byte of the
// response. Only a browser can say the dialog opened.
//
// It matters more than usual here because this PR CHANGED HOW THE HOST MOUNTS:
// the read page went from never mounting one to mounting it when a row declares
// `modals:`. The wiring is new, so "the attribute is present" is exactly the
// evidence that would not have caught getting it wrong.

const ROW = '[data-profile-section="newsletter"]';
const DIALOG = "#studio-modal-card, [x-show] .modal-card, [role='dialog']";

test("a subscribed account is offered the way out", async ({ page }) => {
  const pageErrors = watchPageErrors(page);

  await blockOffsiteRequests(page);
  await page.goto("/lab/profile?subscribed=1");

  await expect(page.locator(ROW)).toContainText("Subscribed");
  await expect(page.locator(ROW).getByRole("button", { name: "Unsubscribe" })).toBeVisible();

  expect(pageErrors, `the page threw: ${pageErrors.join(" | ")}`).toEqual([]);
});

test("leaving asks before it acts", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile?subscribed=1");

  // Nothing is open yet — so the assertion below is a TRANSITION, not a state the
  // page was already in.
  await expect(page.getByText("You'll stop receiving updates")).toHaveCount(0);

  await page.locator(ROW).getByRole("button", { name: "Unsubscribe" }).click();

  // THE CLAIM. The store exists, the host mounted, the id matched a registered
  // template, and a dialog is on screen. Any one of those being wrong leaves the
  // markup identical and the button inert.
  await expect(
    page.getByText("You'll stop receiving updates"),
    "the confirmation never opened — the store, the host or the modal id is wrong"
  ).toBeVisible();
});

// THE CONFIRMATION CARRIES THE FORM IT SUBMITS. A confirm whose button posts a
// form elsewhere on the page drifts the moment that form moves, so the DELETE is
// issued from exactly one place — and this is where that is checked, because the
// form only exists once the modal has rendered.
test("the confirmation owns the delete", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile?subscribed=1");

  // The card itself must carry no form: the row is a button, not a submit.
  await expect(page.locator(`${ROW} form`)).toHaveCount(0);

  await page.locator(ROW).getByRole("button", { name: "Unsubscribe" }).click();
  await expect(page.getByText("You'll stop receiving updates")).toBeVisible();

  const method = await page.evaluate(() => {
    const el = document.querySelector('form input[name="_method"]');
    return el ? el.value : null;
  });
  expect(method, "leaving is a DELETE, and the form for it lives in the confirmation").toBe("delete");
});

test("cancelling closes without acting", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile?subscribed=1");
  await page.locator(ROW).getByRole("button", { name: "Unsubscribe" }).click();
  await expect(page.getByText("You'll stop receiving updates")).toBeVisible();

  await page.getByRole("button", { name: "Cancel" }).click();

  // A confirmation with no way out is a trap, and this is the transition that
  // proves the store's close() is wired to the same host that opened it.
  await expect(page.getByText("You'll stop receiving updates")).toHaveCount(0);
});

// The other half of the card. Joining is ONE CLICK — a plain form, no modal —
// because it is reversible from this same card and a confirm would be friction
// protecting nothing.
test("joining needs no confirmation", async ({ page }) => {
  const pageErrors = watchPageErrors(page);

  await blockOffsiteRequests(page);
  await page.goto("/lab/profile");

  const form = page.locator(`${ROW} form`);
  await expect(form, "joining is a plain form — it works with no JavaScript at all").toHaveCount(1);
  await expect(form).toHaveAttribute("action", "/profile/newsletter");
  await expect(page.locator(`${ROW} input[name="_method"]`)).toHaveCount(0);

  expect(pageErrors, `the page threw: ${pageErrors.join(" | ")}`).toEqual([]);
});
