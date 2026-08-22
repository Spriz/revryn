import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  testMatch: "**/*.spec.ts",
  timeout: 60_000,
  use: {
    baseURL: "http://localhost:8341",
    trace: "retain-on-failure",
  },
  webServer: {
    command:
      "cd .. && mise exec php@8.3 -- php artisan migrate --force && mise exec php@8.3 -- php artisan serve --port 8341",
    url: "http://localhost:8341/login",
    reuseExistingServer: true,
    timeout: 90_000,
  },
});
