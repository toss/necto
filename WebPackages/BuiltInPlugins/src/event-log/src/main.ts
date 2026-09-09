//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import "./style.css";

import { createDetailPane, necto, isNectoBridgeError, type NectoSubscription } from "@necto/bridge";
import { t } from "./localization";
import {
  availableTags,
  eventDetailContent,
  eventMatches,
  previewMessage,
  upsertBoundedEvent,
  visibleEvents,
  type EventDetail,
  type EventRow,
} from "./model";

/// Which shade a level gets. `warn` is the only one that has to be looked up rather
/// than read off the name, so they are all written down instead of computed.
const tones: Record<EventRow["level"], string> = {
  debug: "idle",
  info: "info",
  warn: "warning",
  error: "danger",
};

/// Fixed rather than localised, for the same reason the network log's is: a locale
/// renders this as "오후 4:41:07", which is wider and read as prose rather than by
/// position.
function formatTime(milliseconds: number): string {
  const date = new Date(milliseconds);
  const pad = (value: number, width = 2) => String(value).padStart(width, "0");
  return `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}.${pad(
    date.getMilliseconds(),
    3,
  )}`;
}

/// Nodes rather than markup: a tag and a message come from whatever the app logged,
/// and neither is ours to trust in an `innerHTML`.
function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attributes: Record<string, string | undefined> = {},
  children: (Node | string)[] = [],
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  for (const [name, value] of Object.entries(attributes)) {
    if (value !== undefined) node.setAttribute(name, value);
  }
  node.append(...children);
  return node;
}

// -- state -------------------------------------------------------------------

const rows = new Map<string, EventRow>();
let level = "";
let tag = "";
let query = "";
let selectedID: string | null = null;
let message: string | null = null;
const detailPane = createDetailPane("necto.event-log.detail");
const maximumRowCount = 500;
const maximumDetailPreviewLength = 2_000;

const body = document.getElementById("body")!;
const count = document.getElementById("count")!;
const search = document.getElementById("search") as HTMLInputElement;
const levelFilter = document.getElementById("level") as HTMLSelectElement;
const tagFilter = document.getElementById("category") as HTMLSelectElement;
let tableBody: HTMLTableSectionElement | null = null;
const eventLines = new Map<string, HTMLTableRowElement>();
search.placeholder = t("Search level, tag, or message");
search.setAttribute("aria-label", t("Search events"));
for (const [value, label] of [
  ["", t("All levels")],
  ["debug", "Debug"],
  ["info", "Info"],
  ["warn", t("Warning")],
  ["error", t("Error")],
] as const) {
  levelFilter.append(el("option", { value }, [label]));
}
levelFilter.setAttribute("aria-label", t("Filter by level"));
tagFilter.setAttribute("aria-label", t("Filter by category"));
tagFilter.append(el("option", { value: "" }, [t("All categories")]));
document.getElementById("clear")!.textContent = t("Clear");

function visible(): EventRow[] {
  return visibleEvents(rows.values(), query, level, tag);
}

// -- rendering ---------------------------------------------------------------

function updateCount(visibleCount: number): void {
  count.textContent = visibleCount === rows.size ? String(visibleCount) : `${visibleCount} / ${rows.size}`;
}

function eventLine(row: EventRow): HTMLTableRowElement {
  const line = el("tr", {
    class: "event-row",
    "aria-selected": row.id === selectedID ? "true" : undefined,
  }, [
    el("td", { class: "necto-numeric" }, [formatTime(row.at)]),
    el("td", {}, [el("span", { class: `necto-status necto-status-${tones[row.level]}` }, [
      row.level.toUpperCase(),
    ])]),
    el("td", {}, [el("span", { class: "necto-badge" }, [row.tag])]),
    el("td", { class: "event-message-cell" }, [
      el("span", { class: "event-message" }, [previewMessage(row.message)]),
    ]),
  ]);
  if (row.hasDetail) {
    line.tabIndex = 0;
    line.addEventListener("click", () => void open(row.id));
    line.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        void open(row.id);
      }
    });
  }
  eventLines.set(row.id, line);
  return line;
}

let tagOptionsSignature = "";

function updateTagOptions(): void {
  const tags = availableTags(rows.values());
  const signature = tags.join("\u001f");
  if (signature === tagOptionsSignature) return;
  tagOptionsSignature = signature;

  const selectedTag = tag;
  tagFilter.replaceChildren(
    el("option", { value: "" }, [t("All categories")]),
    ...tags.map((value) => el("option", { value }, [value])),
  );
  tag = tags.includes(selectedTag) ? selectedTag : "";
  tagFilter.value = tag;
}

function render(): void {
  updateTagOptions();
  const shown = visible();
  if (selectedID && !shown.some((row) => row.id === selectedID)) {
    selectedID = null;
    detail = null;
    detailPane.unmount();
    document.querySelector(".necto-detail")?.remove();
  }
  updateCount(shown.length);
  tableBody = null;
  eventLines.clear();
  body.replaceChildren();

  if (!shown.length) {
    body.append(
      el("div", { class: "necto-empty" }, [
        el("p", { class: "necto-empty-title" }, [message ?? t("Nothing logged yet")]),
        el("p", { class: "necto-caption" }, [
          t("Events the connected app records appear here as they happen."),
        ]),
      ]),
    );
    return;
  }

  const head = el("tr", {}, [
    el("th", { class: "col-time necto-numeric" }, [t("Time")]),
    el("th", { class: "col-level" }, [t("Level")]),
    el("th", { class: "col-tag" }, [t("Category")]),
    el("th", {}, [t("Message")]),
  ]);

  tableBody = el("tbody", {}, shown.map(eventLine));
  const table = el("table", { class: "necto-table" }, [
    el("thead", {}, [head]),
    tableBody,
  ]);

  body.append(table);
  if (selectedID) void showDetail();
}

let detail: EventDetail | null = null;

async function open(id: string): Promise<void> {
  const previousID = selectedID;
  selectedID = selectedID === id ? null : id;
  detail = null;
  if (previousID) eventLines.get(previousID)?.removeAttribute("aria-selected");
  if (selectedID) eventLines.get(selectedID)?.setAttribute("aria-selected", "true");
  showDetail();
  if (!selectedID) return;

  const requestedID = selectedID;

  try {
    // Behind its own call, so scrolling a long log does not drag every detail along.
    const output = await necto.device.send<{ event: EventDetail }>(
      "events.detail",
      { eventID: requestedID },
    );
    if (selectedID !== requestedID) return;
    detail = output.event;
  } catch (error) {
    if (selectedID !== requestedID) return;
    message = messageOf(error);
  }
  showDetail();
}

function showDetail(): void {
  detailPane.unmount();
  document.querySelector(".necto-detail")?.remove();
  if (!selectedID) return;

  const pane = el("aside", { class: "necto-detail" });
  const close = el("button", {
    type: "button",
    class: "necto-button necto-button-quiet",
    "aria-label": t("Close event detail"),
  }, ["✕"]);
  close.addEventListener("click", () => void open(selectedID!));

  const content = detail === null ? null : eventDetailContent(detail);
  const summary = rows.get(selectedID);
  pane.append(
    el("div", { class: "necto-detail-title" }, [
      ...(summary ? [
        el("span", { class: `necto-status necto-status-${tones[summary.level]}` }, [summary.level.toUpperCase()]),
        el("span", { class: "necto-badge" }, [summary.tag]),
        el("span", { class: "necto-numeric" }, [formatTime(summary.at)]),
      ] : []),
      el("span", { class: "necto-detail-title-url" }, [
        previewMessage(summary?.message ?? "", 200),
      ]),
      close,
    ]),
    el(
      "div",
      { class: "necto-detail-body event-detail-content" },
      content === null
        ? [el("p", { class: "necto-caption" }, [t("Loading…")])]
        : [
            el("section", { class: "event-detail-section" }, [
              el("h3", { class: "necto-section-title" }, [t("Message")]),
              detailMessage(content.message),
            ]),
            el("section", { class: "event-detail-section" }, [
              el("h3", { class: "necto-section-title" }, [t("Metadata")]),
              el(
                "dl",
                { class: "necto-pairs" },
                content.fields.map(([key, value]) =>
                  el("div", {}, [el("dt", {}, [detailLabel(key)]), detailValue(value)]),
                ),
              ),
            ]),
          ],
    ),
  );

  document.querySelector(".necto-app")?.append(pane);
  detailPane.mount(pane);
}

function detailLabel(key: string): string {
  switch (key) {
  case "level": return t("Level");
  case "category": return t("Category");
  case "source": return t("Source");
  default: return key;
  }
}

function detailMessage(value: string): HTMLElement {
  const section = el("div");
  const isTruncated = value.length > maximumDetailPreviewLength;
  const rendered = isTruncated
    ? `${value.slice(0, maximumDetailPreviewLength - 1)}…`
    : value;
  const output = el("pre", { class: "necto-code event-detail-message" }, [rendered]);
  section.append(output);
  if (isTruncated) {
    const expand = el("button", {
      type: "button",
      class: "necto-button necto-button-quiet event-detail-expand",
    }, [t("Show full value")]);
    expand.addEventListener("click", () => {
      output.textContent = value;
      expand.remove();
    });
    section.append(expand);
  }
  return section;
}

function detailValue(value: string): HTMLElement {
  const content = el("dd", {}, [previewMessage(value, maximumDetailPreviewLength)]);
  if (value.length <= maximumDetailPreviewLength) return content;

  const expand = el("button", {
    type: "button",
    class: "necto-button necto-button-quiet",
  }, [t("Show full value")]);
  expand.addEventListener("click", () => content.replaceChildren(value));
  content.append(" ", expand);
  return content;
}

function receiveLiveEvent(event: EventRow): void {
  const removedIDs = upsertBoundedEvent(rows, event, maximumRowCount);
  const previousTag = tag;
  updateTagOptions();

  if (tableBody === null || previousTag !== tag) {
    render();
    return;
  }

  eventLines.get(event.id)?.remove();
  eventLines.delete(event.id);
  if (eventMatches(event, query, level, tag)) tableBody.prepend(eventLine(event));

  for (const id of removedIDs) {
    eventLines.get(id)?.remove();
    eventLines.delete(id);
    if (selectedID === id) {
      selectedID = null;
      detail = null;
      showDetail();
    }
  }
  updateCount(eventLines.size);
}

// -- actions -----------------------------------------------------------------

function messageOf(error: unknown): string {
  return isNectoBridgeError(error) ? error.message : String(error);
}

search.addEventListener("input", () => {
  query = search.value;
  render();
});
levelFilter.addEventListener("change", () => {
  level = levelFilter.value;
  render();
});
tagFilter.addEventListener("change", () => {
  tag = tagFilter.value;
  render();
});

document.getElementById("clear")?.addEventListener("click", () => {
  // Destructive, so Necto asks before this reaches the app.
  void necto.device
    .send("events.clear")
    .then(() => {
      rows.clear();
      selectedID = null;
      render();
    })
    .catch((error: unknown) => {
      message = messageOf(error);
      render();
    });
});

// -- start -------------------------------------------------------------------

async function main(): Promise<void> {
  if (!necto.isAvailable()) {
    message = t("This plugin only works inside Necto");
    render();
    return;
  }

  render();

  try {
    // The backlog first, then the live ones: the app has been collecting since it
    // started, and none of that should be invisible because the panel opened late.
    const page = await necto.device.send<{ events: EventRow[] }>("events.list", { limit: 500 });
    for (const row of page.events) upsertBoundedEvent(rows, row, maximumRowCount);
    render();

    const subscription: NectoSubscription = await necto.device.subscribe<{ event: EventRow }>(
      "events.observe",
      {},
      ({ event }) => {
        receiveLiveEvent(event);
      },
      (error) => {
        message = error.message;
        render();
      },
    );
    void subscription;
  } catch (error) {
    message = messageOf(error);
    render();
  }

  await necto.ready();
}

void main();
