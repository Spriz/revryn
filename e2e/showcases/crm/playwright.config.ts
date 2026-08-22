import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  testMatch: "**/*.spec.ts",
  timeout: 90_000,
  use: {
    baseURL: process.env.KYSTVEJ_URL || "http://localhost:8332",
    trace: "retain-on-failure",
  },
});
