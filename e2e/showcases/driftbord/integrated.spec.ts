import { test, expect } from "@playwright/test";

/**
 * Integrated certification, Driftbord × Billing Core (BC-US-151 final
 * milestone, BC-US-153). The Django showcase runs in integrated mode
 * against a live Billing Core team (the guided demo workspace, whose
 * FakeERP connection lets the flow reach a reconciled invoice intent
 * without real external writes).
 *
 * Phase 1 (this spec, browser): real product usage in Driftbord —
 * organization, membership-driven seats, a real automation run — and the
 * billing page rendering the LIVE Billing Core invoice preview with
 * fingerprint + line traceability.
 *
 * Phase 2 (run.sh, GraphQL): ERP mappings, freeze, synchronize, and
 * reconcile the draft against the fake adapter.
 */

const suffix = `${Date.now().toString(36)}${Math.floor(Math.random() * 1e4)}`;

test("Driftbord drives Billing Core through the public GraphQL contract", async ({ page }) => {
  test.setTimeout(180_000);

  // Register + workspace in the SHOWCASE.
  await page.goto("/register/");
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

  // A real workflow that meters usage: project → rule → move.
  await page.click("#new-project");
  await page.fill("input[name=name]", "Integration");
  await page.click("#create-project-submit");
  await page.waitForURL("**/projects/**");
  const projectUrl = page.url();

  await page.locator("form:has(#create-label-submit) input[name=name]").fill("live");
  await page.click("#create-label-submit");

  await page.locator("#board-list a").first().click();
  const backlog = page.locator(".column").first();
  await backlog.locator("input[name=title]").fill("Push to Billing Core");
  await backlog.locator("button", { hasText: "Add" }).click();
  const boardUrl = page.url();

  await page.goto(projectUrl);
  await page.click("#project-rules");
  await page.fill("#create-rule-form input[name=name]", "Live labelling");
  await page
    .locator("#create-rule-form select[name=trigger_column_id]")
    .selectOption({ label: "Main board / In progress" });
  await page.locator("#create-rule-form select[name=action]").selectOption("add_label");
  await page.locator("#create-rule-form select[name=add_label_id]").selectOption({ label: "live" });
  await page.click("#create-rule-submit");

  await page.goto(boardUrl);
  await page.locator(".task a", { hasText: "Push to Billing Core" }).click();
  await page.locator("#move-task-form select").selectOption({ label: "In progress" });
  await page.click("#move-task-submit");
  await expect(page.locator("#task-column")).toHaveText("In progress");

  // The billing page now renders the LIVE invoice preview from Billing
  // Core — fingerprint plus line-level traceability (BC-US-151).
  await page.goto(orgUrl);
  await page.click("#org-billing");
  await expect(page.locator("#preview-traceability")).toBeVisible({ timeout: 30_000 });
  const fingerprint = await page.locator("#preview-fingerprint").innerText();
  expect(fingerprint.length).toBeGreaterThan(8);
  await expect(page.locator("#preview-lines")).toContainText("Driftbord seat");
  await expect(page.locator("#active-members")).toHaveText("1");

  // Hand the organization slug to phase 2 via test output.
  console.log(`INTEGRATED_ORG_SLUG=${new URL(orgUrl).pathname.split("/")[2]}`);
});
