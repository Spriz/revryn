import { defineConfig, devices } from "@playwright/test";

/**
 * Playwright configuration for Billing Core E2E suites (SPEC section 23.6).
 *
 * Policy highlights enforced here:
 * - `retries: 0` — required suites must not retry. A separate diagnostic
 *   retry job may exist in CI but cannot affect merge status.
 * - Evidence retention on failure: traces, screenshots, and video are kept
 *   for failed tests. The webServer's stdout/stderr (Phoenix logs) are piped
 *   so failed runs retain server logs too.
 * - Chromium-only for now; more projects can be added when policy requires.
 *
 * Suites live in `smoke/` (deploy/restore smoke tests) and `features/`
 * (complete product workflows). Shared data/helpers live in `fixtures/`.
 */
/**
 * Target selection: by default the suites run against the local dev server
 * (booted below). Set PW_BASE_URL to point at an already-running server —
 * the CI release job boots the compiled production release and sets this —
 * which also disables the dev webServer (SPEC 23.6: required browser
 * certification runs against the production release build).
 */
const baseURL = process.env.PW_BASE_URL || "http://localhost:4000";
const useExternalServer = !!process.env.PW_BASE_URL;

export default defineConfig({
  testDir: ".",
  testMatch: ["features/**/*.spec.ts", "smoke/**/*.spec.ts"],

  // SPEC 23.6: required suites use `retries: 0`.
  retries: 0,

  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  workers: process.env.CI ? 1 : undefined,

  reporter: [
    ["list"],
    ["html", { open: "never", outputFolder: "playwright-report" }],
  ],
  outputDir: "test-results",

  use: {
    baseURL,
    // SPEC 23.6: failed runs retain traces, screenshots, and video.
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "retain-on-failure",
  },

  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],

  webServer: useExternalServer
    ? undefined
    : {
        // Runs from e2e/; mise provides Erlang/Elixir, then boot Phoenix at repo root.
        command: "bash -lc 'eval \"$(mise env -s bash)\" && cd .. && mix phx.server'",
        port: 4000,
        reuseExistingServer: true,
        // First boot compiles the whole app; be generous.
        timeout: 180_000,
        // Retain Phoenix logs as evidence (SPEC 23.6).
        stdout: "pipe",
        stderr: "pipe",
      },
});
