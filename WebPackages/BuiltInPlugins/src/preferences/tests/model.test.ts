//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { assert, test } from "vitest";

import { arrayItems, dictionaryFields, display, element, numberValue } from "../src/model";

test("an untouched row is saved as the value it showed", () => {
  const stored = ["dark", "1", "1.0", "true", "null", "", " 7", '"quoted"', '{"a":1}', 1, true, { a: [1] }, [2]];
  for (const value of stored) {
    assert.deepEqual(element(display(value)), value);
  }
});

test("a plain string shows without quotes and structured values show as JSON", () => {
  assert.strictEqual(display("dark"), "dark");
  assert.strictEqual(display("1"), '"1"');
  assert.strictEqual(display(1), "1");
  assert.strictEqual(display({ a: 1 }), '{"a":1}');
});

test("StringSet rows keep JSON-looking strings exactly as stored", () => {
  const stored = ["1.0", '"x"', "1", "true", "null", '{"a":1}', "", " 7", "한글"];
  assert.deepEqual(stored.map(value => display(value, true)), stored);
});

test("typed text is saved as the JSON it reads as, or as a string", () => {
  assert.strictEqual(element("47"), 47);
  assert.strictEqual(element("true"), true);
  assert.deepEqual(element('{"a":1}'), { a: 1 });
  assert.strictEqual(element("not json"), "not json");
});

test("a container that is not JSON is not an empty one", () => {
  const described = '["createdAt": 1970-01-01 00:00:00 +0000]';
  assert.strictEqual(arrayItems(described), null);
  assert.strictEqual(dictionaryFields(described), null);
  assert.strictEqual(arrayItems('{"a":1}'), null);
  assert.strictEqual(dictionaryFields("[1]"), null);
  assert.strictEqual(dictionaryFields("null"), null);

  assert.deepEqual(arrayItems("[]"), []);
  assert.deepEqual(arrayItems('[1,"two"]'), [1, "two"]);
  assert.deepEqual(dictionaryFields('{"a":1,"b":"two"}'), [
    ["a", 1],
    ["b", "two"],
  ]);
});

test("an emptied or oversized number field holds no number", () => {
  assert.strictEqual(numberValue(" 47 ", "Int"), 47);
  assert.strictEqual(numberValue("1.5", "Double"), 1.5);
  assert.strictEqual(numberValue("", "Int"), null);
  assert.strictEqual(numberValue("   ", "Double"), null);
  assert.strictEqual(numberValue("1.5", "Int"), null);
  assert.strictEqual(numberValue("1e30", "Int"), null);
  assert.strictEqual(numberValue("abc", "Double"), null);
});
