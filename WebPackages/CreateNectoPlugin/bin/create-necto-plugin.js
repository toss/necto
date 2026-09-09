#!/usr/bin/env node
//
// Copyright (c) 2026 Viva Republica, Inc.
//

import { run } from "../src/cli.js";

run(process.argv.slice(2)).catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
