import { test, expect } from "@playwright/test";

/**
 * Deploy/restore smoke: health endpoints (SPEC section 22.6).
 *
 * Uses the `request` fixture (no browser) — these are protocol endpoints,
 * not UI. `/health/live` must answer with no dependency checks;
 * `/health/ready` reports per-component checks and is only 200 when the
 * node may safely receive work.
 */
test.describe("health endpoints", () => {
  test("GET /health/live returns 200 with status ok", async ({ request }) => {
    const response = await request.get("/health/live");

    expect(response.status()).toBe(200);
    expect(await response.json()).toEqual({ status: "ok" });
  });

  test("GET /health/ready returns 200 and reports database ok", async ({
    request,
  }) => {
    const response = await request.get("/health/ready");

    expect(response.status()).toBe(200);

    const body = await response.json();
    expect(body.status).toBe("ok");
    expect(body.checks).toBeDefined();
    expect(body.checks.database).toBe("ok");
  });
});
