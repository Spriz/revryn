import { test, expect, Browser, Page } from "@playwright/test";

/**
 * Standalone Playwright certification for the Driftbord showcase
 * (BC-US-151/153). No Billing Core anywhere: the app must be a complete
 * product on its own, with metered usage originating from real workflows
 * and the seam page reporting fixture-driven plan math.
 */

const suffix = `${Date.now().toString(36)}${Math.floor(Math.random() * 1e4)}`;

async function register(page: Page, email: string, name: string) {
  await page.goto("/register/");
  await page.fill("input[name=full_name]", name);
  await page.fill("input[name=email]", email);
  await page.fill("input[name=password]", "sikkerhed123");
  await page.click("#register-submit");
  await page.waitForURL("**/");
}

test("a team runs its work end to end, automation meters usage, the seam prices it", async ({
  browser,
}) => {
  test.setTimeout(180_000);

  const owner = await (await browser.newContext()).newPage();
  const ownerEmail = `ejer-${suffix}@example.com`;
  await register(owner, ownerEmail, "Ejer");

  // Organization and project scaffold.
  await owner.click("#new-org");
  await owner.fill("input[name=name]", `Fjordlys ${suffix}`);
  await owner.click("#create-org-submit");
  await owner.waitForURL("**/orgs/**");
  const orgUrl = owner.url();

  await owner.click("#new-project");
  await owner.fill("input[name=name]", "Website relaunch");
  await owner.click("#create-project-submit");
  await owner.waitForURL("**/projects/**");
  const projectUrl = owner.url();

  // A label the automation rule will apply.
  await owner.fill("#create-label-submit >> xpath=preceding-sibling::input[@name='name']", "");
  await owner.locator("form:has(#create-label-submit) input[name=name]").fill("needs-review");
  await owner.click("#create-label-submit");

  // Open the default board and create a task in Backlog.
  await owner.locator("#board-list a").first().click();
  await owner.waitForURL("**/boards/**");
  const boardUrl = owner.url();
  const backlog = owner.locator(".column").first();
  await backlog.locator("input[name=title]").fill("Draft launch copy");
  await backlog.locator("button", { hasText: "Add" }).click();

  // Automation: when a task reaches "In progress", label it.
  await owner.goto(projectUrl);
  await owner.click("#project-rules");
  await owner.fill("#create-rule-form input[name=name]", "Flag work in progress");
  await owner
    .locator("#create-rule-form select[name=trigger_column_id]")
    .selectOption({ label: "Main board / In progress" });
  await owner.locator("#create-rule-form select[name=action]").selectOption("add_label");
  await owner
    .locator("#create-rule-form select[name=add_label_id]")
    .selectOption({ label: "needs-review" });
  await owner.click("#create-rule-submit");
  await expect(owner.locator("#rules-table")).toContainText("Flag work in progress");

  // Move the task through the REAL workflow; the rule fires and meters.
  await owner.goto(boardUrl);
  await owner.locator(".task a", { hasText: "Draft launch copy" }).click();
  await owner.locator("#move-task-form select").selectOption({ label: "In progress" });
  await owner.click("#move-task-submit");
  await expect(owner.locator("#task-column")).toHaveText("In progress");
  await expect(owner.locator(".chip.on")).toContainText("needs-review");
  const taskUrl = owner.url();

  // Collaboration: comment + attachment metadata.
  await owner.fill("#comment-form textarea", "Første udkast er klar.");
  await owner.click("#comment-submit");
  await expect(owner.locator("#comment-list")).toContainText("Første udkast er klar.");
  await owner.locator("#attachment-form input[name=filename]").fill("copy-draft.docx");
  await owner.locator("#attachment-form button").click();
  await expect(owner.locator("#attachment-list")).toContainText("copy-draft.docx");

  // Invite a colleague; the single-use link lands in the flash.
  await owner.goto(orgUrl);
  await owner.click("#org-members");
  const colleagueEmail = `kollega-${suffix}@example.com`;
  await owner.fill("#invite-form input[name=email]", colleagueEmail);
  await owner.click("#invite-submit");
  const flash = await owner.locator("#flashes").innerText();
  const inviteUrl = flash.match(/https?:\/\/\S+\/invitations\/\S+\//)![0];

  // The colleague registers, accepts, and gets assigned.
  const colleague = await (await browser.newContext()).newPage();
  await register(colleague, colleagueEmail, "Kollega");
  await colleague.goto(inviteUrl);
  await colleague.click("#accept-invitation");
  await colleague.waitForURL("**/orgs/**");

  await owner.goto(taskUrl);
  await owner.locator("#assign-form select[name=assignee_id]").selectOption({ label: "Kollega" });
  await owner.click("#assign-submit");

  await colleague.click("#nav-notifications");
  await expect(colleague.locator("#notification-list")).toContainText("Draft launch copy");

  // Search + saved filter.
  await owner.goto(orgUrl);
  await owner.click("#org-search");
  await owner.fill("#search-form input[name=q]", "launch");
  await owner.click("#search-submit");
  await expect(owner.locator("#search-results")).toContainText("Draft launch copy");
  await owner.locator("#save-filter-form input[name=name]").fill("Launch work");
  await owner.click("#save-filter-submit");
  await expect(owner.locator("#saved-filters")).toContainText("Launch work");

  // Audit-friendly history.
  await owner.goto(orgUrl);
  await owner.click("#org-activity");
  await expect(owner.locator("#activity-list")).toContainText("Moved “Draft launch copy”");
  await expect(owner.locator("#activity-list")).toContainText("Automation");

  // The seam prices what actually happened: 2 active members on the
  // Studio tier, exactly one metered automation run.
  await owner.goto(orgUrl);
  await owner.click("#org-billing");
  await expect(owner.locator("#active-members")).toHaveText("2");
  await expect(owner.locator("#seat-tier")).toHaveText("Studio");
  await expect(owner.locator("#seat-total")).toContainText("98.00 DKK");
  await expect(owner.locator("#automation-runs")).toHaveText("1");
  await expect(owner.locator("#overage-runs")).toHaveText("0");
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

test("role administration protects the last owner", async ({ browser }) => {
  const owner = await (await browser.newContext()).newPage();
  await register(owner, `rolle-${suffix}@example.com`, "Ejer");
  await owner.click("#new-org");
  await owner.fill("input[name=name]", `Roller ${suffix}`);
  await owner.click("#create-org-submit");
  await owner.waitForURL("**/orgs/**");

  await owner.click("#org-members");
  await owner.locator("#members-table select").first().selectOption("member");
  await expect(owner.locator("#flashes")).toContainText("last owner cannot be demoted");
  await expect(owner.locator("#members-table")).toContainText("Ejer");
});
