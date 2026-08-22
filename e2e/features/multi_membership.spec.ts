import { test, expect, Browser, Page } from "@playwright/test";
import { registerAndSignIn, createWorkspace } from "../fixtures/auth";

/**
 * BC-US-143/144: one global identity holding conflicting roles across
 * three teams in two organizations, granted through real invitation links
 * — with server-side re-authorization on every team switch and no role
 * leakage between scopes.
 */

async function newUserPage(browser: Browser): Promise<Page> {
  const context = await browser.newContext();
  return context.newPage();
}

async function inviteFromMembersPage(
  page: Page,
  teamId: string,
  email: string,
  role: string,
): Promise<string> {
  await page.goto(`/teams/${teamId}/members`);
  await page.locator("#invite-form input[name='invite[email]']").fill(email);
  await page
    .locator("#invite-form select[name='invite[roles][]']")
    .selectOption([role]);
  await page.locator("#invite-form button[type=submit], #invite-form button").last().click();
  await expect(page.locator("#invite-link")).toBeVisible({ timeout: 20_000 });
  const linkText = await page.locator("#invite-link code").innerText();
  return linkText.trim();
}

test("conflicting roles across three teams in two organizations", async ({ browser }) => {
  test.setTimeout(240_000);

  // Organization slugs are globally unique and the dev database persists
  // across runs, so fixed names would collide on the second run.
  const suffix = `${Date.now().toString(36)}${Math.floor(Math.random() * 1e4)}`;

  // Organization B's admin builds two teams.
  const adminPage = await newUserPage(browser);
  await registerAndSignIn(adminPage);
  const financeTeamId = await createWorkspace(adminPage, `Borealis ${suffix} ApS`, "Finance");

  await adminPage.goto("/");
  const orgSection = adminPage.locator("details:has(form[id^='new-team-form-'])").first();
  await orgSection.locator("summary").click();
  await orgSection.locator("input[name='name']").fill("Drift");
  await orgSection.locator("button[type=submit]").click();
  await adminPage.waitForURL(/\/teams\/[0-9a-f-]+$/, { timeout: 20_000 });
  const driftTeamId = adminPage.url().split("/teams/")[1];
  expect(driftTeamId).not.toBe(financeTeamId);

  // The multi-membership user owns organization A.
  const userPage = await newUserPage(browser);
  const userEmail = await registerAndSignIn(userPage);
  const auroraTeamId = await createWorkspace(userPage, `Aurora ${suffix} ApS`, "Finance");

  // B invites the same identity into both teams with different roles.
  const auditorLink = await inviteFromMembersPage(
    adminPage,
    financeTeamId,
    userEmail,
    "auditor",
  );
  const billingLink = await inviteFromMembersPage(
    adminPage,
    driftTeamId,
    userEmail,
    "billing_admin",
  );

  await userPage.goto(auditorLink);
  await userPage.waitForURL(`**/teams/${financeTeamId}`, { timeout: 20_000 });
  await userPage.goto(billingLink);
  await userPage.waitForURL(`**/teams/${driftTeamId}`, { timeout: 20_000 });

  // The dashboard shows all three teams grouped under two organizations.
  await userPage.goto("/");
  await expect(userPage.locator(`#team-link-${auroraTeamId}`)).toBeVisible();
  await expect(userPage.locator(`#team-link-${financeTeamId}`)).toBeVisible();
  await expect(userPage.locator(`#team-link-${driftTeamId}`)).toBeVisible();

  // Own team: full admin affordances (roles forms present).
  await userPage.goto(`/teams/${auroraTeamId}/members`);
  await expect(userPage.locator("form[id^='roles-form-']").first()).toBeVisible();

  // Borealis/Finance as auditor: members are visible, mutation affordances
  // are not — the auditor role from another team grants nothing here.
  await userPage.goto(`/teams/${financeTeamId}/members`);
  await expect(userPage.locator("#team-members")).toBeVisible();
  await expect(userPage.locator("form[id^='roles-form-']")).toHaveCount(0);
  await expect(userPage.locator("#invite-form")).toHaveCount(0);

  // Borealis/Drift as billing_admin: still no membership administration
  // (that requires team_admin), but the team itself is accessible.
  await userPage.goto(`/teams/${driftTeamId}/members`);
  await expect(userPage.locator("#team-members")).toBeVisible();
  await expect(userPage.locator("form[id^='roles-form-']")).toHaveCount(0);

  // Server-side re-authorization: a team the user was never granted is
  // rejected outright even with a known URL. Create one more team as B.
  await adminPage.goto("/");
  const orgSection2 = adminPage.locator("details:has(form[id^='new-team-form-'])").first();
  await orgSection2.locator("summary").click();
  await orgSection2.locator("input[name='name']").fill("Skunkworks");
  await orgSection2.locator("button[type=submit]").click();
  await adminPage.waitForURL(/\/teams\/[0-9a-f-]+$/, { timeout: 20_000 });
  const secretTeamId = adminPage.url().split("/teams/")[1];

  await userPage.goto(`/teams/${secretTeamId}/members`);
  await userPage.waitForURL(/\/$/, { timeout: 20_000 });
  await expect(userPage.locator(`#team-link-${secretTeamId}`)).toHaveCount(0);
});
