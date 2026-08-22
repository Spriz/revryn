import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  testMatch: "**/*.spec.ts",
  timeout: 90_000,
  use: {
    baseURL: process.env.PERSONALE_URL || "http://localhost:8342",
    trace: "retain-on-failure",
  },
});
