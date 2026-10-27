import { defineConfig } from "vite";

export default defineConfig({
  // GitHub Pages deploy base, e.g. VITE_APP_BASE=/firebrat/community/
  base: process.env.VITE_APP_BASE || "./",
  build: { outDir: "dist" },
});
