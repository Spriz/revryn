import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  testMatch: "**/*.spec.ts",
  timeout: 60_000,
  use: {
    baseURL: "http://localhost:8331",
    trace: "retain-on-failure",
  },
  webServer: {
    command:
      "cd .. && mise exec ruby@3.3 -- bin/rails db:prepare && mise exec ruby@3.3 -- bin/rails server -p 8331",
    url: "http://localhost:8331/login",
    reuseExistingServer: true,
    timeout: 90_000,
  },
});
