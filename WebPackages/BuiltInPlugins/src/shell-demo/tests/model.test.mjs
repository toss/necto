//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import assert from "node:assert/strict";
import test from "node:test";

import { defaultCommand, executionRows, unapprovedCommand } from "../src/model.ts";

test("the unapproved probe is an exact different command", () => {
  assert.notEqual(unapprovedCommand, defaultCommand);
});

test("execution results expose stdout stderr and exit code", () => {
  assert.deepEqual(
    executionRows({ stdout: "hello\n", stderr: "", exitCode: 0 }),
    [
      ["stdout", "hello\n"],
      ["stderr", "—"],
      ["exitCode", 0],
    ],
  );
});
