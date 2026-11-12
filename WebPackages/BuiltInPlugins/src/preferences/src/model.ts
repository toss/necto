//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import type { NectoJSONValue } from "@necto/bridge";

/// What a row's text is saved as: `47` is a number, `true` a Bool, `{"a":1}` an
/// object, and anything that is not JSON is the string it looks like.
export function element(text: string): NectoJSONValue {
  try {
    return JSON.parse(text) as NectoJSONValue;
  } catch {
    return text;
  }
}

/// A string shows as itself, unless that text would be saved as something else: a
/// stored `"1"` has to stay a string. That one, like anything structured, shows as one
/// line of JSON, so every row is saved as what it was unless someone changes it.
/// StringSet rows skip JSON parsing on save, so their strings stay unquoted.
export function display(value: NectoJSONValue, stringsOnly = false): string {
  if (typeof value === "string" && (stringsOnly || element(value) === value)) return value;
  return JSON.stringify(value);
}

/// The elements of a stored Array, or null when its text is not one. A property list
/// can hold a Date or Data that JSON cannot, and the app then describes the value in
/// its own words: that is something to show, never an empty list to save over it.
export function arrayItems(text: string): NectoJSONValue[] | null {
  const value = parse(text);
  return Array.isArray(value) ? value : null;
}

/// The pairs of a stored Dictionary, or null when its text is not one.
export function dictionaryFields(text: string): [string, NectoJSONValue][] | null {
  const value = parse(text);
  if (value === null || typeof value !== "object" || Array.isArray(value)) return null;
  return Object.entries(value);
}

/// The number a field holds, or null when it holds none. `Number("")` is 0, and an
/// emptied field must not be saved as one.
export function numberValue(text: string, type: string): number | null {
  const trimmed = text.trim();
  if (!trimmed) return null;
  const number = Number(trimmed);
  if (!Number.isFinite(number)) return null;
  if (type === "Int" && !Number.isSafeInteger(number)) return null;
  return number;
}

function parse(text: string): NectoJSONValue | undefined {
  try {
    return JSON.parse(text) as NectoJSONValue;
  } catch {
    return undefined;
  }
}
