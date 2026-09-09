//
//  Copyright (c) 2026 Viva Republica, Inc.
//

export type NectoTranslationValues = Record<string, string | number>;
export type NectoTranslations = Record<string, Record<string, string>>;

/** The language selected by the host, reduced to the language subtag. */
export function locale(): string {
  const declared = globalThis.document?.documentElement.lang;
  const preferred = declared || globalThis.navigator?.language || "en";
  return preferred.trim().toLowerCase().split(/[-_]/, 1)[0] || "en";
}

/**
 * Builds a small plugin-owned translator. English source text remains the fallback,
 * so a missing entry is readable and adding another language needs no host change.
 */
export function createTranslator(translations: NectoTranslations) {
  return (source: string, values: NectoTranslationValues = {}): string => {
    const template = translations[locale()]?.[source] ?? source;
    return template.replace(/\{([A-Za-z0-9_]+)\}/g, (match, key: string) =>
      values[key] === undefined ? match : String(values[key]),
    );
  };
}
