import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  testMatch: "**/*.spec.ts",
  timeout: 90_000,
  use: {
    baseURL: process.env.DRIFTBORD_URL || "http://localhost:8322",
    trace: "retain-on-failure",
  },
});
