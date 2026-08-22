import { test, expect, Page } from "@playwright/test";

/**
 * Standalone Playwright certification for the Personalehuset showcase
 * (BC-US-152/153). No Billing Core anywhere: annual prepaid per active
 * employee with a minimum commitment, add-ons, and prospective proration
 * all priced through the application-local seam fixtures.
 */

const suffix = `${Date.now().toString(36)}${Math.floor(Math.random() * 1e4)}`;

async function register(page: Page, email: string, name: string) {
  await page.goto("/register");
  await page.fill("input[name=name]", name);
  await page.fill("input[name=email]", email);
  await page.fill("input[name=password]", "sikkerhed123");
  await page.click("#register-submit");
  await page.waitForURL("**/");
}

test("HR runs the directory end to end and the seam prices the year", async ({ browser }) => {
  test.setTimeout(180_000);
  const page = await (await browser.newContext()).newPage();
  await register(page, `hr-${suffix}@example.com`, "HR");

  await page.click("#new-org");
  await page.fill("input[name=name]", `Personale ${suffix}`);
  await page.click("#create-org-submit");
  await page.waitForURL("**/orgs/**");
  const orgUrl = page.url();

  // Structure: department, location, custom field, extra checklist item.
  await page.fill("form[action$='/departments'] input[name=name]", "Engineering");
  await page.click("#create-department-submit");
  await page.fill("form[action$='/locations'] input[name=name]", "Aarhus HQ");
  await page.click("#create-location-submit");
  await page.fill("#custom-field-form input[name=key]", "tshirt");
  await page.fill("#custom-field-form input[name=label]", "T-shirt size");
  await page.click("#create-field-submit");

  // Hire a manager and an employee; assign manager + custom field.
  await page.click("#org-employees");
  await page.fill("#new-employee-form input[name=full_name]", "Mette Manager");
  await page.fill("#new-employee-form input[name=email]", `mette-${suffix}@example.com`);
  await page.locator("#new-employee-form select[name=department_id]").selectOption({ label: "Engineering" });
  await page.click("#create-employee-submit");
  await page.waitForURL("**/employees/**");

  await page.goto(orgUrl);
  await page.click("#org-employees");
  await page.fill("#new-employee-form input[name=full_name]", "Erik Employee");
  await page.fill("#new-employee-form input[name=email]", `erik-${suffix}@example.com`);
  await page.click("#create-employee-submit");
  await page.waitForURL("**/employees/**");

  await page.locator("#profile-form select[name=manager_id]").selectOption({ label: "Mette Manager" });
  await page.fill("#profile-form input[name='custom[tshirt]']", "L");
  await page.click("#profile-save");
  await expect(page.locator("#profile-form input[name='custom[tshirt]']")).toHaveValue("L");

  // Onboarding checklist toggles.
  await page.locator("#onboarding-list form button").first().click();
  await expect(page.locator("#onboarding-list li.done")).toHaveCount(1);

  // Search + CSV export.
  await page.goto(orgUrl);
  await page.click("#org-employees");
  await page.fill("#search-form input[name=q]", "Mette");
  await page.click("#search-submit");
  await expect(page.locator("#employee-list")).toContainText("Mette Manager");
  await expect(page.locator("#employee-list")).not.toContainText("Erik Employee");

  // Billing: 2 active but minimum 5 → billable 5 × 599.00 = 2,995.00.
  await page.goto(orgUrl);
  await page.click("#org-billing");
  await expect(page.locator("#active-employees")).toHaveText("2");
  await expect(page.locator("#billable-seats")).toHaveText("5");
  await expect(page.locator("#seat-total")).toContainText("2,995.00 DKK");
  await expect(page.locator("#prospective-growth")).toContainText("0.00 DKK");

  // Add-ons flow into the annual total.
  await page.locator("#billing-settings-form input[name=onboarding_addon]").check();
  await page.click("#billing-save");
  await expect(page.locator("#addon-total")).toContainText("990.00 DKK");
  await expect(page.locator("#year-total")).toContainText("3,985.00 DKK");

  // Change history captured everything.
  await page.goto(orgUrl);
  await page.click("#org-changelog");
  await expect(page.locator("#changelog-list")).toContainText("Hired Mette Manager");
  await expect(page.locator("#changelog-list")).toContainText("Changed billing settings");
});

test("membership isolation: a stranger cannot open another organization", async ({ browser }) => {
  const owner = await (await browser.newContext()).newPage();
  await register(owner, `iso-ejer-${suffix}@example.com`, "Ejer");
  await owner.click("#new-org");
  await owner.fill("input[name=name]", `Privat ${suffix}`);
  await owner.click("#create-org-submit");
  await owner.waitForURL("**/orgs/**");
  const orgUrl = owner.url();

  const stranger = await (await browser.newContext()).newPage();
  await register(stranger, `iso-fremmed-${suffix}@example.com`, "Fremmed");
  const response = await stranger.goto(orgUrl);
  expect(response!.status()).toBe(403);
});

test("invitation joins a colleague through the single-use link", async ({ browser }) => {
  const owner = await (await browser.newContext()).newPage();
  await register(owner, `inv-ejer-${suffix}@example.com`, "Ejer");
  await owner.click("#new-org");
  await owner.fill("input[name=name]", `Invitation ${suffix}`);
  await owner.click("#create-org-submit");
  await owner.waitForURL("**/orgs/**");

  await owner.click("#org-members");
  const colleagueEmail = `inv-kollega-${suffix}@example.com`;
  await owner.fill("#invite-form input[name=email]", colleagueEmail);
  await owner.click("#invite-submit");
  const flash = await owner.locator("#flash-notice").innerText();
  const inviteUrl = flash.match(/https?:\/\/\S+\/invitations\/\S+/)![0];

  const colleague = await (await browser.newContext()).newPage();
  await register(colleague, colleagueEmail, "Kollega");
  await colleague.goto(inviteUrl);
  await colleague.click("#accept-invitation");
  await colleague.waitForURL("**/orgs/**");
  await expect(colleague.locator("#org-employees")).toBeVisible();
});
