import { test, expect } from "@playwright/test";

/**
 * Integrated certification, Personalehuset × Billing Core (BC-US-152
 * final milestone, BC-US-153). Phase 1: real hires drive the billable
 * annual-prepaid quantity and the billing page renders the LIVE preview
 * with traceability. Phase 2 (run_personalehuset.sh): map → freeze →
 * synchronize → reconcile, then assert the annual service period
 * propagated onto the frozen line.
 */

const suffix = `${Date.now().toString(36)}${Math.floor(Math.random() * 1e4)}`;

test("Personalehuset drives Billing Core through the public GraphQL contract", async ({ page }) => {
  test.setTimeout(180_000);

  await page.goto("/register");
  await page.fill("input[name=name]", "Integreret HR");
  await page.fill("input[name=email]", `int-${suffix}@example.com`);
  await page.fill("input[name=password]", "sikkerhed123");
  await page.click("#register-submit");
  await page.waitForURL("**/");

  await page.click("#new-org");
  await page.fill("input[name=name]", `Integreret ${suffix}`);
  await page.click("#create-org-submit");
  await page.waitForURL("**/orgs/**");
  const orgUrl = page.url();

  // A real hire: the seat quantity flows to Billing Core.
  await page.click("#org-employees");
  await page.fill("#new-employee-form input[name=full_name]", "Mette Medarbejder");
  await page.fill("#new-employee-form input[name=email]", `mette-${suffix}@example.com`);
  await page.click("#create-employee-submit");
  await page.waitForURL("**/employees/**");

  // Billing: minimum 5 seats billable × 599.00/year, LIVE from the
  // platform preview with fingerprint + line traceability.
  await page.goto(orgUrl);
  await page.click("#org-billing");
  await expect(page.locator("#preview-traceability")).toBeVisible({ timeout: 30_000 });
  const fingerprint = await page.locator("#preview-fingerprint").innerText();
  expect(fingerprint.length).toBeGreaterThan(8);
  await expect(page.locator("#preview-lines")).toContainText("Personalehuset seat");
  await expect(page.locator("#billable-seats")).toHaveText("5");
  await expect(page.locator("#seat-total")).toContainText("2,995.00 DKK");

  console.log(`INTEGRATED_ORG_SLUG=${new URL(orgUrl).pathname.split("/")[2]}`);
});
