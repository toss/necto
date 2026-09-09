//
//  Copyright (c) 2026 Viva Republica, Inc.
//

export interface EventRow {
  id: string;
  at: number;
  level: "debug" | "info" | "warn" | "error";
  tag: string;
  message: string;
  hasDetail: boolean;
}

export interface EventDetail extends EventRow {
  detail: Record<string, string>;
}

export function eventDetailContent(event: EventDetail): {
  message: string;
  fields: [string, string][];
} {
  const additional = Object.entries(event.detail)
    .filter(([key]) => key !== "level" && key !== "category" && key !== "message")
    .sort(([left], [right]) => left.localeCompare(right));
  return {
    message: event.message,
    fields: [
      ["level", event.level],
      ["category", event.tag],
      ...additional,
    ],
  };
}

export function previewMessage(message: string, maximumLength = 500): string {
  const singleLine = message.replace(/\s+/g, " ").trim();
  const limit = Math.max(1, Math.floor(maximumLength));
  if (singleLine.length <= limit) return singleLine;
  return `${singleLine.slice(0, limit - 1)}…`;
}

export function availableTags(rows: Iterable<EventRow>): string[] {
  return [...new Set([...rows].map((row) => row.tag).filter(Boolean))]
    .sort((left, right) => left.localeCompare(right));
}

export function upsertBoundedEvent(
  rows: Map<string, EventRow>,
  event: EventRow,
  maximumCount: number,
): string[] {
  rows.set(event.id, event);
  const removed: string[] = [];
  const limit = Math.max(0, Math.floor(maximumCount));

  while (rows.size > limit) {
    let oldest: EventRow | null = null;
    for (const row of rows.values()) {
      if (oldest === null || row.at < oldest.at) oldest = row;
    }
    if (oldest === null) break;
    rows.delete(oldest.id);
    removed.push(oldest.id);
  }
  return removed;
}

export function eventMatches(row: EventRow, query: string, level: string, tag = ""): boolean {
  const term = query.trim().toLowerCase();
  return (!level || row.level === level)
    && (!tag || row.tag === tag)
    && (!term || `${row.level} ${row.tag} ${row.message}`.toLowerCase().includes(term));
}

export function visibleEvents(rows: Iterable<EventRow>, query: string, level: string, tag = ""): EventRow[] {
  return [...rows]
    .filter((row) => eventMatches(row, query, level, tag))
    .sort((first, second) => second.at - first.at);
}
