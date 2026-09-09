//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { defineConfig } from "tsup";

export default defineConfig({
  entry: ["src/index.ts"],
  format: ["esm"],
  dts: true,
  clean: true,
});
