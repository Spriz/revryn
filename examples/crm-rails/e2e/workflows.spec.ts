import { test, expect, Browser, Page } from "@playwright/test";

/**
 * Standalone Playwright certification for the Kystvej CRM showcase
 * (BC-US-150/153). No Billing Core anywhere: the CRM is a complete
 * product; per-seat billing math comes from local fixtures behind the
 * application-local seam, with immediate seat increases and configurable
 * decrease timing demonstrated through the real member workflows.
 */

const suffix = `${Date.now().toString(36)}${Math.floor(Math.random() * 1e4)}`;

async function register(page: Page, email: string, name: string) {
  await page.goto("/register");
  await page.fill("input[name=full_name]", name);
  await page.fill("input[name=email]", email);
  await page.fill("input[name=password]", "sikkerhed123");
  await page.click("#register-submit");
  await page.waitForURL("**/");
}

test("a sales team works deals end to end and the seam prices seats", async ({ browser }) => {
  test.setTimeout(180_000);

  const owner = await (await browser.newContext()).newPage();
  await register(owner, `ejer-${suffix}@example.com`, "Ejer");

  await owner.click("#new-org");
  await owner.fill("input[name=name]", `Kystvej ${suffix}`);
  await owner.click("#create-org-submit");
  await owner.waitForURL("**/orgs/**");
  const orgUrl = owner.url();

  // CRM data: company + contact.
  await owner.click("#org-companies");
  await owner.fill("#new-company-form input[name=name]", "Fjeldmark ApS");
  await owner.fill("#new-company-form input[name=city]", "Aarhus");
  await owner.click("#create-company-submit");
  await expect(owner.locator("#company-list")).toContainText("Fjeldmark ApS");

  await owner.goto(orgUrl);
  await owner.click("#org-contacts");
  await owner.fill("#new-contact-form input[name=full_name]", "Bo Berg");
  await owner.fill("#new-contact-form input[name=email]", "bo@fjeldmark.dk");
  await owner
    .locator("#new-contact-form select[name=company_id]")
    .selectOption({ label: "Fjeldmark ApS" });
  await owner.click("#create-contact-submit");
  await expect(owner.locator("#contact-list")).toContainText("Bo Berg");

  // Deal through the pipeline with an integer-øre amount.
  await owner.goto(orgUrl);
  await owner.locator("[id^='pipeline-']").click();
  const lead = owner.locator(".column", { hasText: "Lead" });
  await lead.locator("input[name=title]").fill("Website relaunch");
  await lead.locator("input[name=amount_ore]").fill("1250000");
  await lead.locator("button", { hasText: "Add" }).click();
  await owner.locator(".task a", { hasText: "Website relaunch" }).click();
  await expect(owner.locator("#deal-amount")).toContainText("12500,00 DKK");

  await owner.locator("#move-deal-form select").selectOption({ label: "Proposal" });
  await owner.click("#move-deal-submit");
  await expect(owner.locator("#deal-stage")).toHaveText("Proposal");
  await owner.click("#mark-won");
  await expect(owner.locator("#deal-status")).toHaveText("won");

  // A note on the deal.
  await owner.fill("#note-form textarea", "Kontrakt underskrevet.");
  await owner.click("#note-submit");
  await expect(owner.locator("#note-list")).toContainText("Kontrakt underskrevet.");

  // Invite a colleague — the seat count rises immediately.
  await owner.goto(orgUrl);
  await owner.click("#org-members");
  const colleagueEmail = `kollega-${suffix}@example.com`;
  await owner.fill("#invite-form input[name=email]", colleagueEmail);
  await owner.click("#invite-submit");
  const flash = await owner.locator("#flash-notice").innerText();
  const inviteUrl = flash.match(/https?:\/\/\S+\/invitations\/\S+/)![0];

  const colleague = await (await browser.newContext()).newPage();
  await register(colleague, colleagueEmail, "Kollega");
  await colleague.goto(inviteUrl);
  await colleague.click("#accept-invitation");
  await colleague.waitForURL("**/orgs/**");

  // Billing seam: 2 active seats, base 249.00 + 2 × 99.00 = 447.00 DKK.
  await owner.goto(orgUrl);
  await owner.click("#org-billing");
  await expect(owner.locator("#active-seats")).toHaveText("2");
  await expect(owner.locator("#billable-seats")).toHaveText("2");
  await expect(owner.locator("#period-total")).toContainText("447.00 DKK");

  // Remove the colleague: with period_end timing the billable floor
  // holds until the rollover.
  await owner.goto(orgUrl);
  await owner.click("#org-members");
  await owner
    .locator("#members-table tr", { hasText: colleagueEmail })
    .locator("button", { hasText: "Remove" })
    .click();

  await owner.goto(orgUrl);
  await owner.click("#org-billing");
  await expect(owner.locator("#active-seats")).toHaveText("1");
  await expect(owner.locator("#billable-seats")).toHaveText("2");
  await owner.click("#rollover-period");
  await expect(owner.locator("#billable-seats")).toHaveText("1");

  // Annual prepay with the automation add-on: (249 + 99 + 149) × 10.
  await owner.locator("#billing-settings-form select[name=billing_interval]").selectOption("annual");
  await owner.locator("#billing-settings-form input[name=automation_addon]").check();
  await owner.click("#billing-save");
  await expect(owner.locator("#billing-interval")).toHaveText("annual");
  await expect(owner.locator("#period-total")).toContainText("4,970.00 DKK");

  // Audit history captured the whole story.
  await owner.goto(orgUrl);
  await owner.click("#org-activity");
  await expect(owner.locator("#activity-list")).toContainText("from Lead to Proposal");
  await expect(owner.locator("#activity-list")).toContainText("Invited");
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

test("CSV export round-trips through import without duplicates", async ({ browser }) => {
  const page = await (await browser.newContext()).newPage();
  await register(page, `csv-${suffix}@example.com`, "CSV");
  await page.click("#new-org");
  await page.fill("input[name=name]", `CSV ${suffix}`);
  await page.click("#create-org-submit");
  await page.waitForURL("**/orgs/**");

  await page.click("#org-contacts");
  await page.fill("#new-contact-form input[name=full_name]", "Eva Dam");
  await page.fill("#new-contact-form input[name=email]", "eva@example.com");
  await page.click("#create-contact-submit");

  const download = await Promise.all([
    page.waitForEvent("download"),
    page.click("#export-csv"),
  ]).then(([d]) => d);
  const path = await download.path();

  await page.setInputFiles("#import-form input[type=file]", path!);
  await page.click("#import-submit");
  await expect(page.locator("#flash-notice")).toContainText("Imported 1 contacts");
  await expect(page.locator("#contact-list tbody tr")).toHaveCount(1);
});
