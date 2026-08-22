import { expect, Page } from "@playwright/test";

/**
 * Passkey-first registration helpers shared by the feature suites. A CDP
 * virtual authenticator stands in for platform biometrics.
 */

/**
 * Waits until the page's main LiveView is websocket-connected. Filling a
 * form during the dead render loses the input when the connected render
 * replaces the DOM — always call this after `goto` and before `fill` on a
 * LiveView page.
 */
export async function waitForLiveView(page: Page): Promise<void> {
  await page.waitForSelector("[data-phx-main].phx-connected", {
    state: "attached",
    timeout: 20_000,
  });
}

export async function enableVirtualAuthenticator(page: Page): Promise<void> {
  const client = await page.context().newCDPSession(page);
  await client.send("WebAuthn.enable");
  await client.send("WebAuthn.addVirtualAuthenticator", {
    options: {
      protocol: "ctap2",
      transport: "internal",
      hasResidentKey: true,
      hasUserVerification: true,
      isUserVerified: true,
      automaticPresenceSimulation: true,
    },
  });
}

export async function registerAndSignIn(page: Page, email?: string): Promise<string> {
  await enableVirtualAuthenticator(page);

  const address =
    email ??
    `e2e-${Date.now()}-${Math.floor(Math.random() * 1e6)}@demo.example`;

  await page.goto("/register");
  await page.getByLabel("Email").fill(address);
  await page.getByRole("button", { name: /create account with a passkey/i }).click();
  await page.waitForURL(/\/$/, { timeout: 20_000 });
  return address;
}

/** Creates a real (non-demo) workspace through the first-run form. */
export async function createWorkspace(
  page: Page,
  organizationName: string,
  teamName: string,
): Promise<string> {
  await page.goto("/start");
  await waitForLiveView(page);
  await page.locator("#create-workspace-form input[name='workspace[name]']").fill(organizationName);
  await page
    .locator("#create-workspace-form input[name='workspace[team_name]']")
    .fill(teamName);
  await page.locator("#create-workspace").click();
  await page.waitForURL(/\/teams\/[0-9a-f-]+$/, { timeout: 20_000 });
  const teamId = page.url().split("/teams/")[1];
  await expect(page.locator("#team-nav")).toBeVisible();
  return teamId;
}
