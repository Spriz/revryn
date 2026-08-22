import { test, expect, Browser, Page } from "@playwright/test";
import { registerAndSignIn } from "../fixtures/auth";

/**
 * BC-US-156 remediation scenarios beyond the user-fixable retry (which
 * lives in demo_aha.spec.ts): a self-healing transient failure, an
 * operator-only authorization failure resolved by revalidating the
 * dependency, and a non-retryable failure that hands over a support
 * bundle. Each drill arms a one-shot provider fault in the guided demo
 * workspace and drives the ordinary product surfaces.
 */

const LIVE_TIMEOUT = 30_000;

async function newUserPage(browser: Browser): Promise<Page> {
  const context = await browser.newContext();
  return context.newPage();
}

/** Walks a fresh demo workspace to a frozen invoice intent, arms the given
 * failure drill, and attempts the ERP draft. Returns the demo hub URL and
 * the operations path. */
async function armDrillAndSync(
  page: Page,
  drillButton: string,
): Promise<{ demoUrl: string; operationsPath: string }> {
  await page.goto("/start");
  await page.locator("#start-demo-workspace").click();
  await page.waitForURL(/\/teams\/.*\/demo$/, { timeout: 60_000 });
  const demoUrl = page.url();
  const teamId = demoUrl.split("/teams/")[1].split("/")[0];

  await page.locator("#demo-build-commercial").click();
  await expect(page.locator("#demo-phase-commercial")).toContainText("Ready", {
    timeout: LIVE_TIMEOUT,
  });

  await page.locator("#demo-invoice-action").click();
  await page.waitForURL(/\/subscriptions\//, { timeout: LIVE_TIMEOUT });
  await page.locator("#preview-form button").first().click();
  await expect(page.locator("#preview-result")).toBeVisible({ timeout: LIVE_TIMEOUT });
  page.once("dialog", (dialog) => dialog.accept());
  await page.locator("#freeze-button").click();
  await page.waitForURL(/\/invoices\//, { timeout: LIVE_TIMEOUT });
  const invoiceUrl = page.url();

  await page.goto(demoUrl);
  await page.locator("details:has(summary:text('More failure drills')) summary").click();
  await page.locator(drillButton).click();
  await page.goto(invoiceUrl);
  await page.locator("#synchronize-button").click();

  return { demoUrl, operationsPath: `/teams/${teamId}/operations` };
}

test("a transient provider blip heals itself without any clicks", async ({ browser }) => {
  test.setTimeout(180_000);
  const page = await newUserPage(browser);
  await registerAndSignIn(page);

  const { demoUrl, operationsPath } = await armDrillAndSync(
    page,
    "#demo-inject-failure-transient",
  );

  // While the retry policy waits, the inbox reports it as automatic —
  // explicitly not action-required. (The scheduled replay may already have
  // healed it by the time the page renders; both are correct.)
  await page.goto(operationsPath);
  const pendingOrHealed = page.locator(
    "[id^='operation-']:has-text('automatic retry pending'), #empty-inbox",
  );
  await expect(pendingOrHealed.first()).toBeVisible({ timeout: LIVE_TIMEOUT });
  await expect(page.locator("[id^='retry-']")).toHaveCount(0);

  // The scheduled replay (same operation key) succeeds on its own.
  await page.goto(demoUrl);
  await expect(page.locator("#demo-phase-invoice")).toContainText(
    "Approve the reconciled draft",
    { timeout: 60_000 },
  );
});

test("an authorization failure is operator-only: revalidate the dependency, then requeue", async ({
  browser,
}) => {
  test.setTimeout(180_000);
  const page = await newUserPage(browser);
  await registerAndSignIn(page);

  const { demoUrl, operationsPath } = await armDrillAndSync(
    page,
    "#demo-inject-failure-authorization",
  );

  await page.goto(operationsPath);
  const item = page.locator("[id^='operation-']").first();
  await expect(item).toContainText("operator-only", { timeout: LIVE_TIMEOUT });
  await expect(item).toContainText("team admin must revalidate");
  await expect(page.locator("[id^='retry-']")).toHaveCount(0);

  // Fix the dependency the operator way: revalidate the ERP connection.
  const teamId = operationsPath.split("/teams/")[1].split("/")[0];
  await page.goto(`/teams/${teamId}/settings`);
  await page.locator("#validate-connection").click();
  await expect(page.locator("body")).toContainText("Connection validated", {
    timeout: LIVE_TIMEOUT,
  });

  // Requeue from the inbox; the replay reuses the same operation key.
  await page.goto(operationsPath);
  page.once("dialog", (dialog) => dialog.accept());
  await page.locator("[id^='remediate-']").first().click();

  await page.goto(demoUrl);
  await expect(page.locator("#demo-phase-invoice")).toContainText(
    "Approve the reconciled draft",
    { timeout: 60_000 },
  );
});

test("a non-retryable failure is distinguished and hands over a support bundle", async ({
  browser,
}) => {
  test.setTimeout(180_000);
  const page = await newUserPage(browser);
  await registerAndSignIn(page);

  const { operationsPath } = await armDrillAndSync(page, "#demo-inject-failure-terminal");

  await page.goto(operationsPath);
  const item = page.locator("[id^='operation-']").first();
  await expect(item).toContainText("non-retryable", { timeout: LIVE_TIMEOUT });
  await expect(item).toContainText("Not retryable");

  // No self-service action is offered; the copyable bundle carries the
  // operation identity and correlation for support, never a payload.
  await expect(page.locator("[id^='retry-']")).toHaveCount(0);
  await expect(page.locator("[id^='remediate-']")).toHaveCount(0);
  const bundle = page.locator("[id^='bundle-']").first();
  await expect(bundle).toBeVisible();
  const value = await bundle.inputValue();
  expect(value).toContain("revryn-support operation=");
  expect(value).toContain("correlation=");
});
