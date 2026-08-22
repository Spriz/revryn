import { defineConfig } from "astro/config";

// GitHub Pages project site: the deploy workflow passes
// SITE_URL=https://<owner>.github.io and BASE_PATH=/<repo>.
// Locally both default to a rootless dev setup.
export default defineConfig({
  site: process.env.SITE_URL || "https://example.github.io",
  base: process.env.BASE_PATH || "/",
  trailingSlash: "ignore",
  build: { format: "directory" },
});
