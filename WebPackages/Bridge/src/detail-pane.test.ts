//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { describe, expect, it } from "vitest";
import { parseDetailPreferences } from "./detail-pane";

describe("detail pane preferences", () => {
  it.each([null, "", "broken", "null", "{}", '{"position":"left"}'])("uses default sizes for %s", value => {
    expect(parseDetailPreferences(value).width).toBeUndefined();
    expect(parseDetailPreferences(value).height).toBeUndefined();
  });
  it("restores both axis sizes but ignores the old docking choice", () => {
    expect(parseDetailPreferences('{"position":"bottom","width":480,"height":320}'))
      .toEqual({ width: 480, height: 320 });
  });
  it("ignores invalid dimensions", () => {
    expect(parseDetailPreferences('{"width":-2,"height":"400"}'))
      .toEqual({ width: undefined, height: undefined });
  });
});
