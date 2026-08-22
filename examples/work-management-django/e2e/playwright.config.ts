import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  testMatch: "**/*.spec.ts",
  timeout: 60_000,
  retries: 0,
  use: {
    baseURL: "http://localhost:8321",
    trace: "retain-on-failure",
  },
  webServer: {
    command:
      "cd .. && .venv/bin/python manage.py migrate --run-syncdb && .venv/bin/python manage.py runserver 8321 --noreload",
    url: "http://localhost:8321/login/",
    reuseExistingServer: true,
    timeout: 60_000,
    env: { DRIFTBORD_E2E: "1" },
  },
});
