import { test, expect } from "@playwright/test";

/**
 * Deploy/restore smoke: the root page serves and renders in a real browser.
 *
 * Deliberately does not assert on Phoenix default branding or any copy that
 * will change as the product UI lands — only that the page loads with 200
 * and produces a non-empty rendered document.
 */
test.describe("home page", () => {
  test("GET / responds 200 and renders a non-empty page", async ({ page }) => {
    const response = await page.goto("/");

    expect(response, "navigation should produce a response").not.toBeNull();
    expect(response!.status()).toBe(200);

    // The document rendered something: a non-empty <body> with visible text.
    await expect(page.locator("body")).not.toBeEmpty();
    const bodyText = (await page.locator("body").innerText()).trim();
    expect(bodyText.length).toBeGreaterThan(0);
  });
});
