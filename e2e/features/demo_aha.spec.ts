import { test, expect } from "@playwright/test";
import { registerAndSignIn } from "../fixtures/auth";

/**
 * BC-US-166 / BC-TASK-105: a clean install reaches a reconciled synthetic
 * invoice and a reconciled, closed customer-credit month without real ERP
 * credentials — entirely through the product's ordinary surfaces.
 *
 * The demo journey page derives every phase from durable domain rows, so
 * each assertion here is evidence that the real artifact exists (frozen
 * intent, reconciled ERP draft, booked document, credit grant, closed
 * aggregate voucher) — not that a wizard advanced a counter.
 *
 * Registration is passkey-first; a CDP virtual authenticator stands in for
 * platform biometrics.
 */

const LIVE_TIMEOUT = 20_000;

test("clean install reaches a reconciled invoice, credit, and closed month in the demo", async ({
  page,
}) => {
  test.setTimeout(300_000);
  await registerAndSignIn(page);

  // First-run: choose the guided demo workspace, not the real ERP path.
  await page.goto("/start");
  await expect(page.locator("#demo-erp-path")).toBeVisible();
  await expect(page.locator("#real-erp-path")).toBeVisible();
  await page.locator("#start-demo-workspace").click();
  await page.waitForURL(/\/teams\/.*\/demo$/, { timeout: 60_000 });
  const demoUrl = page.url();

  // Phase 1 (provider boundary) is the only completed phase on arrival.
  await expect(page.locator("#demo-phase-connection")).toContainText("Ready");
  await expect(page.locator("#demo-phase-commercial")).toContainText("Next step");
  await expect(page.locator("#demo-phase-invoice")).toContainText("Upcoming");

  // Phase 2: build the commercial model through ordinary catalog/contract
  // commands, then verify the page links the real artifacts.
  await page.locator("#demo-build-commercial").click();
  await expect(page.locator("#demo-phase-commercial")).toContainText("Ready", {
    timeout: LIVE_TIMEOUT,
  });
  await expect(page.locator("#demo-link-subscription")).toBeVisible();

  // Phase 3a: preview and freeze on the real subscription surface.
  await page.locator("#demo-invoice-action").click();
  await page.waitForURL(/\/subscriptions\//, { timeout: LIVE_TIMEOUT });
  await page.locator("#preview-form button[type=submit], #preview-form button").first().click();
  await expect(page.locator("#preview-result")).toBeVisible({ timeout: LIVE_TIMEOUT });

  // Freezing is deliberately confirmed — accept the immutability prompt.
  page.once("dialog", (dialog) => dialog.accept());
  await page.locator("#freeze-button").click();
  await page.waitForURL(/\/invoices\//, { timeout: LIVE_TIMEOUT });

  // Phase 3b: create the ERP draft through the durable sync operation.
  await page.locator("#synchronize-button").click();

  // The demo hub re-derives the journey as the draft reconciles.
  await page.goto(demoUrl);
  await expect(page.locator("#demo-phase-invoice")).toContainText(
    "Approve the reconciled draft",
    { timeout: 30_000 },
  );
  await expect(page.locator("#demo-invoice-evidence")).toContainText("Draft");

  // Phase 3c: approve the reconciled draft on the invoice page.
  await page.locator("#demo-invoice-action").click();
  await page.waitForURL(/\/invoices\//, { timeout: LIVE_TIMEOUT });
  await page.locator("#approve-form input[type=text]").fill("demo finance review");
  await page.locator("#approve-form button").click();

  // Phase 3d: book. The booked document is immutable, so confirm the dialog.
  page.once("dialog", (dialog) => dialog.accept());
  await page.locator("#book-button").click({ timeout: LIVE_TIMEOUT });

  await page.goto(demoUrl);
  await expect(page.locator("#demo-phase-invoice")).toContainText("Ready", {
    timeout: 30_000,
  });
  await expect(page.locator("#demo-invoice-evidence")).toContainText("Booked");

  // Interruption/resume: a full reload resumes the same durable journey.
  await page.reload();
  await expect(page.locator("#demo-phase-invoice")).toContainText("Ready");

  // Phase 4: record the goodwill credit into the subledger.
  await expect(page.locator("#demo-phase-credit")).toContainText("Next step");
  await page.locator("#demo-grant-credit").click();
  await expect(page.locator("#demo-phase-credit")).toContainText("Ready", {
    timeout: LIVE_TIMEOUT,
  });
  await expect(page.locator("#demo-credit-evidence")).toContainText("Goodwill grant");

  // Phase 5: the aggregate close on the real credit-closes surface.
  await page.locator("#demo-close-action").click();
  await page.waitForURL(/\/credit-closes$/, { timeout: LIVE_TIMEOUT });

  await page.locator("#close-policy-form input[name='policy[journal_number]']").fill("1");
  await page
    .locator("#close-policy-form input[name='policy[liability_account_number]']")
    .fill("2990");
  await page
    .locator("#close-policy-form input[name='policy[default_offset_account_number]']")
    .fill("5890");
  await page.locator("#close-policy-form button[type=submit], #close-policy-form button").last().click();

  await expect(page.locator("#generate-close-form")).toBeVisible({ timeout: LIVE_TIMEOUT });
  await page
    .locator("#generate-close-form button", { hasText: "Generate close" })
    .click();
  await page.waitForURL(/\/credit-closes\/.+/, { timeout: 30_000 });

  // Review → exact-hash approval → durable posting → reconciliation.
  await expect(page.locator("#close-state")).toContainText("ready");
  await page.locator("#approve-close-form input[type=text]").fill("monthly demo review");
  await page.locator("#approve-close-form button").click();
  await expect(page.locator("#close-state")).toContainText("approved", {
    timeout: LIVE_TIMEOUT,
  });

  await page.locator("#post-close").click();
  await expect(page.locator("#close-state")).toContainText("reconciled", { timeout: 60_000 });
  await expect(page.locator("#close-posting-status")).toContainText("succeeded");

  await page.locator("#close-period").click();
  await expect(page.locator("#close-state")).toContainText("closed", {
    timeout: LIVE_TIMEOUT,
  });

  // The final proof: every journey phase renders Ready from durable rows.
  await page.goto(demoUrl);
  await expect(page.locator("#demo-phase-close")).toContainText("Ready", { timeout: 30_000 });
  await expect(page.locator("#demo-close-evidence")).toContainText("Voucher");
  await expect(page.locator("#demo-close-evidence")).toContainText("Closing liability");
  await expect(page.locator("#demo-phase-commercial")).toContainText("Ready");
  await expect(page.locator("#demo-phase-invoice")).toContainText("Ready");
  await expect(page.locator("#demo-phase-credit")).toContainText("Ready");

  // BC-TASK-104: month-to-month opening continuity in the browser. The next
  // calendar month must open at exactly the accepted month's closing
  // balance — the liability carried forward, not recomputed.
  await page.goto(demoUrl.replace(/\/demo$/, "/credit-closes"));
  await expect(page.locator("#generate-close-form")).toBeVisible({ timeout: LIVE_TIMEOUT });

  const now = new Date();
  const nextMonth = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1));
  const nextMonthDate = nextMonth.toISOString().slice(0, 10);
  await page
    .locator("#generate-close-form input[name='close[period_date]']")
    .fill(nextMonthDate);
  await page.locator("#generate-close-form button", { hasText: "Generate close" }).click();
  await page.waitForURL(/\/credit-closes\/.+/, { timeout: 30_000 });

  // The goodwill liability of DKK 2,500.00 carries forward as the opening.
  await expect(page.locator("#close-amounts")).toContainText("2,500.00 DKK");
  await expect(page.locator("#close-state")).toContainText("ready");

  // A zero-delta month reconciles locally: approve, post, accept — no new
  // provider voucher is created for a month with no movements.
  await page.locator("#approve-close-form input[type=text]").fill("zero-delta month");
  await page.locator("#approve-close-form button").click();
  await expect(page.locator("#close-state")).toContainText("approved", {
    timeout: LIVE_TIMEOUT,
  });
  await page.locator("#post-close").click();
  await expect(page.locator("#close-state")).toContainText("reconciled", { timeout: 60_000 });
  await page.locator("#close-period").click();
  await expect(page.locator("#close-state")).toContainText("closed", {
    timeout: LIVE_TIMEOUT,
  });
});

test("a simulated provider outage recovers through the operations inbox", async ({ page }) => {
  test.setTimeout(180_000);
  await registerAndSignIn(page);

  await page.goto("/start");
  await page.locator("#start-demo-workspace").click();
  await page.waitForURL(/\/teams\/.*\/demo$/, { timeout: 60_000 });
  const demoUrl = page.url();

  await page.locator("#demo-build-commercial").click();
  await expect(page.locator("#demo-phase-commercial")).toContainText("Ready", {
    timeout: LIVE_TIMEOUT,
  });

  // Freeze the intent on the real subscription surface.
  await page.locator("#demo-invoice-action").click();
  await page.waitForURL(/\/subscriptions\//, { timeout: LIVE_TIMEOUT });
  await page.locator("#preview-form button").first().click();
  await expect(page.locator("#preview-result")).toBeVisible({ timeout: LIVE_TIMEOUT });
  page.once("dialog", (dialog) => dialog.accept());
  await page.locator("#freeze-button").click();
  await page.waitForURL(/\/invoices\//, { timeout: LIVE_TIMEOUT });
  const invoiceUrl = page.url();

  // Arm the one-shot outage from the demo hub, then attempt the draft.
  await page.goto(demoUrl);
  await page.locator("#demo-inject-failure").click();
  await expect(page.locator("#demo-phase-invoice")).toContainText("Next step");
  await page.goto(invoiceUrl);
  await page.locator("#synchronize-button").click();

  // The failure lands safely: durable operation failed, nothing partial,
  // and the journey hub explains the recovery.
  await page.goto(demoUrl);
  await expect(page.locator("#demo-phase-invoice")).toContainText("Needs attention", {
    timeout: 30_000,
  });
  await expect(page.locator("#demo-failure-explainer")).toBeVisible();

  // Remediate through the ordinary operations inbox.
  await page.locator("#demo-invoice-action").click();
  await page.waitForURL(/\/operations$/, { timeout: LIVE_TIMEOUT });
  await expect(page.locator("[id^='operation-']").first()).toContainText("action required", {
    timeout: LIVE_TIMEOUT,
  });
  await page.locator("[id^='retry-']").first().click();

  // The retried operation (same operation key — no duplicate draft)
  // reconciles and the journey resumes where it left off.
  await page.goto(demoUrl);
  await expect(page.locator("#demo-phase-invoice")).toContainText(
    "Approve the reconciled draft",
    { timeout: 30_000 },
  );
  await expect(page.locator("#demo-invoice-evidence")).toContainText("Draft");
});

test("the demo workspace resumes deterministically for a returning user", async ({ page }) => {
  test.setTimeout(120_000);
  await registerAndSignIn(page);

  await page.goto("/start");
  await page.locator("#start-demo-workspace").click();
  await page.waitForURL(/\/teams\/.*\/demo$/, { timeout: 60_000 });
  const demoUrl = page.url();

  await page.locator("#demo-build-commercial").click();
  await expect(page.locator("#demo-phase-commercial")).toContainText("Ready", {
    timeout: LIVE_TIMEOUT,
  });

  // A returning visit offers resume, not a second workspace, and the resumed
  // journey still shows the durably completed phase.
  await page.goto("/start");
  await expect(page.locator("#resume-demo-workspace")).toBeVisible();
  await page.locator("#resume-demo-workspace").click();
  await page.waitForURL(demoUrl, { timeout: LIVE_TIMEOUT });
  await expect(page.locator("#demo-phase-commercial")).toContainText("Ready");
});
