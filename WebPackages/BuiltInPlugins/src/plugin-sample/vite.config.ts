//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { defineConfig } from "vite";

// Output goes to WebPackages/BuiltInPlugins/Plugins/plugin-sample, which ships inside the app bundle.
// manifest.json lives in public/ so it is copied alongside the build.
export default defineConfig({
  base: "./",
  build: {
    outDir: "../../Plugins/plugin-sample",
    emptyOutDir: true,
    rollupOptions: {
      output: {
        // Stable names. The output is committed, and content hashes would add a
        // new file on every build while leaving the previous one behind.
        entryFileNames: "assets/[name].js",
        chunkFileNames: "assets/[name].js",
        assetFileNames: "assets/[name].[ext]",
      },
    },
  },
});
