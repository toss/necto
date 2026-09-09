//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { afterEach, describe, expect, it } from "vitest";

import { createTranslator, locale } from "./localization";

afterEach(() => {
  delete (globalThis as { document?: unknown }).document;
});

function setDocumentLanguage(language: string): void {
  Object.defineProperty(globalThis, "document", {
    configurable: true,
    value: { documentElement: { lang: language } },
  });
}

describe("plugin localization", () => {
  it("uses the language injected by the host", () => {
    setDocumentLanguage("ko-KR");
    expect(locale()).toBe("ko");
  });

  it("translates and substitutes values", () => {
    setDocumentLanguage("ko");
    const text = createTranslator({
      ko: { "{count} events": "이벤트 {count}개" },
    });

    expect(text("{count} events", { count: 3 })).toBe("이벤트 3개");
  });

  it("keeps source text when the plugin has no translation", () => {
    setDocumentLanguage("ja");
    const text = createTranslator({ ko: { Clear: "비우기" } });
    expect(text("Clear")).toBe("Clear");
  });
});
