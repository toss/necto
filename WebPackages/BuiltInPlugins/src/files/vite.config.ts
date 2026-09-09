//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { defineConfig } from "vite";

// The build output lands inside NectoDefaultPlugins, which carries it to the Mac
// as the plugin's panel when an app registers the plugin.
// manifest.json lives in public/ so it is copied alongside the build.
export default defineConfig({
  base: "./",
  build: {
    outDir: "../../../../Sources/NectoDefaultPlugins/Panels/files",
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
