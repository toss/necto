//
// Copyright (c) 2026 Viva Republica, Inc.
//

import { defineConfig } from "vite";

export default defineConfig({
  root: "panel",
  base: "./",
  build: {
    outDir: "../Sources/__PLUGIN_MODULE__/Panel",
    emptyOutDir: true,
    rollupOptions: {
      output: {
        entryFileNames: "assets/[name].js",
        chunkFileNames: "assets/[name].js",
        assetFileNames: "assets/[name].[ext]",
      },
    },
  },
});
