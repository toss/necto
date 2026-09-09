//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { defineConfig } from "vite";

// A ready-to-install desktop plugin. The output folder can be selected directly from
// Necto Settings without an app or an SDK registration.
export default defineConfig({
  base: "./",
  build: {
    outDir: "../../Plugins/shell-demo",
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
