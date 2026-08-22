import { test, expect } from "@playwright/test";

/**
 * Integrated certification, Kystvej CRM × Billing Core (BC-US-150 final
 * milestone, BC-US-153). Phase 1 (this spec): membership-driven seats
 * flow to the platform and the billing page renders the LIVE invoice
 * preview with fingerprint + line traceability. Phase 2 (run_crm.sh):
 * map → freeze → synchronize → reconcile against the fake adapter.
 */

const suffix = `${Date.now().toString(36)}${Math.floor(Math.random() * 1e4)}`;

test("Kystvej CRM drives Billing Core through the public GraphQL contract", async ({ page }) => {
  test.setTimeout(180_000);

  await page.goto("/register");
  await page.fill("input[name=full_name]", "Integreret Ejer");
  await page.fill("input[name=email]", `int-${suffix}@example.com`);
  await page.fill("input[name=password]", "sikkerhed123");
  await page.click("#register-submit");
  await page.waitForURL("**/");

  await page.click("#new-org");
  await page.fill("input[name=name]", `Integreret ${suffix}`);
  await page.click("#create-org-submit");
  await page.waitForURL("**/orgs/**");
  const orgUrl = page.url();

  // Real CRM usage so the integration carries a lived-in organization.
  await page.click("#org-companies");
  await page.fill("#new-company-form input[name=name]", "Fjeldmark ApS");
  await page.click("#create-company-submit");

  // The billing page renders the LIVE preview: 1 seat at 99.00 DKK.
  await page.goto(orgUrl);
  await page.click("#org-billing");
  await expect(page.locator("#preview-traceability")).toBeVisible({ timeout: 30_000 });
  const fingerprint = await page.locator("#preview-fingerprint").innerText();
  expect(fingerprint.length).toBeGreaterThan(8);
  await expect(page.locator("#preview-lines")).toContainText("Kystvej seat");
  await expect(page.locator("#billable-seats")).toHaveText("1");
  await expect(page.locator("#seats-total")).toContainText("99.00 DKK");
  // The flat base is platform-priced via the minimum-commit component.
  await expect(page.locator("#base-total")).toContainText("249.00 DKK");
  await expect(page.locator("#period-total")).toContainText("348.00 DKK");

  console.log(`INTEGRATED_ORG_SLUG=${new URL(orgUrl).pathname.split("/")[2]}`);
});
