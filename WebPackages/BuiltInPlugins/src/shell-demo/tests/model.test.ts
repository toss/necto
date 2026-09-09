//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { assert, test } from "vitest";

import { executionRows } from "../src/model";

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
