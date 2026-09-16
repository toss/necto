//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { createDetailPane } from "@necto/bridge";

import "@necto/bridge/theme.css";
import "@necto/bridge/components.css";
import "./styles.css";

import {
  clearRecords,
  loadDetail,
  observeRecords,
  type Body,
  type RecordDetail,
  type RecordSummary,
} from "./necto";
import { t } from "./localization";

// Development only: lets the plugin be opened and checked in a browser without
// building the Mac app and connecting a device. Dropped from the production bundle.
if (import.meta.env.DEV) {
  const { installMockBridge } = await import("./mock");
  installMockBridge();
}

type DetailTab = "summary" | "request" | "response" | "curl";

const tabs: { id: DetailTab; label: string }[] = [
  { id: "summary", label: t("Summary") },
  { id: "request", label: t("Request") },
  { id: "response", label: t("Response") },
  { id: "curl", label: "cURL" },
];

// -- elements ----------------------------------------------------------------

/// Nodes rather than markup, all the way down. A URL, a header and a response body all
/// come from whatever the app under test talked to, and none of them is ours to trust
/// in an `innerHTML`.
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

// -- formatting --------------------------------------------------------------

function isFailure(record: RecordSummary): boolean {
  return record.state === "failed" || (record.statusCode ?? 0) >= 400;
}

function formatBytes(bytes: number | undefined): string {
  if (bytes === undefined) return "";
  if (bytes < 1024) return `${bytes} B`;
  return `${(bytes / 1024).toFixed(1)} kB`;
}

function formatDuration(record: RecordSummary): string {
  if (record.state === "pending") return "…";
  if (record.durationMilliseconds === undefined) return "";

  const ms = record.durationMilliseconds;
  return ms >= 1000 ? `${(ms / 1000).toFixed(1)} s` : `${Math.round(ms)} ms`;
}

/// Fixed rather than localised. A locale renders this as "12시 46분 21초" or
/// "12:46:21 PM", both wider than the column and harder to compare down a list. A log
/// timestamp is read by position, not as prose.
function formatStarted(record: RecordSummary): string {
  const date = new Date(record.startedAtMilliseconds);
  const pad = (value: number, width = 2) => String(value).padStart(width, "0");

  return `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}.${pad(
    date.getMilliseconds(),
    3,
  )}`;
}

/// Pretty printing JSON is the difference between a body you can read and a wall of
/// text. Anything that does not parse is shown exactly as it arrived.
function formatBody(text: string, contentType: string | undefined): string {
  if (!contentType?.includes("json")) return text;
  try {
    return JSON.stringify(JSON.parse(text), null, 2);
  } catch {
    return text;
  }
}

/// `navigator.clipboard` is the right API and is not always reachable: it needs a
/// secure context, user activation, and a permission the WebView may not have. The
/// selection route works wherever the document does.
async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    const field = document.createElement("textarea");
    field.value = text;
    field.setAttribute("readonly", "");
    field.style.cssText = "position:fixed;top:-1000px;opacity:0";
    document.body.append(field);
    field.select();
    const copied = document.execCommand("copy");
    field.remove();
    return copied;
  }
}

// -- pieces ------------------------------------------------------------------

/// A body is read far more often than it is copied, so the button stays out of the
/// way until the pointer or the keyboard reaches the block.
function codeBlock(text: string): HTMLElement {
  const button = el("button", { type: "button", class: "necto-code-copy" }, [t("copy")]);

  button.addEventListener("click", () => {
    void copyText(text).then((copied) => {
      // A button that silently does nothing is worse than one that says it failed.
      button.textContent = copied ? t("copied") : t("failed");
      if (copied) button.dataset.copied = "true";

      setTimeout(() => {
        button.textContent = t("copy");
        delete button.dataset.copied;
      }, 1400);
    });
  });

  return el("div", { class: "necto-code-block" }, [
    el("pre", { class: "necto-code" }, [text]),
    button,
  ]);
}

/// One shape for every state, because three treatments in one column read as three
/// different kinds of thing.
function statusCell(record: RecordSummary): HTMLElement {
  if (record.state === "pending") {
    return el("span", { class: "necto-status necto-status-idle" }, ["—"]);
  }
  if (record.state === "failed") {
    return el("span", { class: "necto-status necto-status-danger" }, [t("fail")]);
  }

  const code = record.statusCode ?? 0;
  const tone =
    code >= 500 ? "danger" : code >= 400 ? "warning" : code >= 300 ? "info" : "ok";

  return el("span", { class: `necto-status necto-status-${tone}` }, [String(code)]);
}

function pairs(rows: [string, string][]): HTMLElement {
  if (!rows.length) return el("p", { class: "necto-caption" }, [t("Nothing recorded.")]);

  return el(
    "dl",
    { class: "necto-pairs" },
    rows.map(([label, value]) =>
      el("div", {}, [el("dt", {}, [label]), el("dd", {}, [value])]),
    ),
  );
}

function bodyView(body: Body | undefined, label: string): Node[] {
  if (!body) return [el("p", { class: "necto-caption" }, [t("No {side} body.", { side: t(label) })])];

  const meta = [formatBytes(body.byteCount), body.contentType].filter(Boolean).join(" · ");
  if (body.text === undefined) {
    return [
      el("p", { class: "necto-caption" }, [meta]),
      el("p", { class: "necto-caption" }, [t("Binary body.")]),
    ];
  }

  return [
    el("p", { class: "necto-caption" }, [meta + (body.isTruncated ? ` · ${t("truncated")}` : "")]),
    codeBlock(formatBody(body.text, body.contentType)),
  ];
}

function summary(record: RecordDetail): HTMLElement {
  const rows: [string, string][] = [
    [t("Method"), record.method],
    [t("State"), record.state],
  ];
  if (record.statusCode !== undefined) rows.push([t("Status"), String(record.statusCode)]);
  if (record.durationMilliseconds !== undefined) {
    rows.push([t("Duration"), `${Math.round(record.durationMilliseconds)} ms`]);
  }
  if (record.responseByteCount !== undefined) {
    rows.push([t("Size"), formatBytes(record.responseByteCount)]);
  }
  rows.push([t("Started"), new Date(record.startedAtMilliseconds).toLocaleString()]);
  if (record.errorSummary) rows.push([t("Error"), record.errorSummary]);

  return pairs(rows);
}

function exchange(record: RecordDetail, side: "request" | "response"): Node[] {
  const headers = side === "request" ? record.requestHeaders : record.responseHeaders;
  const body = side === "request" ? record.requestBody : record.responseBody;
  const rows = Object.entries(headers ?? {}).sort(([a], [b]) => a.localeCompare(b));

  return [
    el("h3", { class: "necto-section-title" }, [t("Headers")]),
    pairs(rows),
    el("h3", { class: "necto-section-title" }, [t("Body")]),
    ...bodyView(body, side),
  ];
}

// -- state -------------------------------------------------------------------

const records = new Map<string, RecordSummary>();
let query = "";
let selectedID: string | null = null;
let detail: RecordDetail | null = null;
let tab: DetailTab = "summary";
let message: string | null = null;
const detailPane = createDetailPane("necto.network-logger.detail");

function visibleRecords(): RecordSummary[] {
  const term = query.trim().toLowerCase();
  return [...records.values()]
    .filter((record) => !term || `${record.method} ${record.url}`.toLowerCase().includes(term))
    .sort((first, second) => second.startedAtMilliseconds - first.startedAtMilliseconds);
}

// -- the shell ---------------------------------------------------------------

const filter = el("input", {
  class: "necto-field",
  type: "search",
  placeholder: t("Filter by method, host or path"),
  "aria-label": t("Filter requests"),
}) as HTMLInputElement;

const count = el("span", { class: "count" });
const clearButton = el(
  "button",
  { type: "button", class: "necto-button necto-button-quiet necto-button-danger" },
  [t("Clear")],
);

/// `tabindex` so the arrow keys below have somewhere to land: a list a developer scans
/// should not need the pointer.
const listPane = el("div", { class: "necto-body", tabindex: "0" });
const detailSlot = el("div", { class: "detail-slot" });

document.getElementById("root")?.append(
  el("div", { class: "necto-app" }, [
    el("div", { class: "necto-toolbar" }, [filter, count, clearButton]),
    listPane,
    detailSlot,
  ]),
);

// -- rendering ---------------------------------------------------------------

/// The list and the detail pane are rebuilt on their own. Replacing the whole page
/// would take the filter field's focus and caret with it on every arriving record.
function renderList(): void {
  const visible = visibleRecords();
  count.textContent = visible.length ? String(visible.length) : "";
  listPane.replaceChildren();

  if (!visible.length) {
    listPane.append(
      el("div", { class: "necto-empty" }, [
        el("p", { class: "necto-empty-title" }, [message ?? t("No requests yet")]),
        el("p", { class: "necto-caption" }, [
          t("Make a request in the connected app and it appears here."),
        ]),
      ]),
    );
    return;
  }

  const head = el("tr", {}, [
    el("th", { class: "col-status" }, [t("Status")]),
    el("th", { class: "col-method" }, [t("Method")]),
    el("th", {}, ["URL"]),
    el("th", { class: "col-started necto-numeric" }, [t("Started")]),
    el("th", { class: "col-duration necto-numeric" }, [t("Duration")]),
    el("th", { class: "col-size necto-numeric" }, [t("Size")]),
  ]);

  const rows = visible.map((record) => {
    const row = el("tr", {
      "aria-selected": record.id === selectedID ? "true" : undefined,
      "data-failed": isFailure(record) ? "true" : undefined,
    }, [
      el("td", {}, [statusCell(record)]),
      el("td", { class: "cell-method" }, [record.method]),
      el("td", {}, [
        el("span", { class: "req-name" }, [record.name]),
        el("span", { class: "req-host" }, [record.host]),
      ]),
      el("td", { class: "cell-started cell-numeric necto-numeric" }, [formatStarted(record)]),
      el("td", { class: "cell-duration cell-numeric necto-numeric" }, [formatDuration(record)]),
      el("td", { class: "cell-size cell-numeric necto-numeric" }, [formatBytes(record.responseByteCount)]),
    ]);
    row.addEventListener("click", () => void select(record.id));
    return row;
  });

  listPane.append(
    el("table", { class: "necto-table" }, [
      el("thead", {}, [head]),
      el("tbody", {}, rows),
    ]),
  );
}

function renderDetail(): void {
  detailPane.unmount();
  detailSlot.replaceChildren();
  if (!selectedID) return;

  const selected = records.get(selectedID);
  const aside = el("aside", { class: "necto-detail" });
  const close = el("button", {
    type: "button",
    class: "necto-button necto-button-quiet",
    "aria-label": t("Close details"),
  }, ["✕"]);
  close.addEventListener("click", closeDetail);

  aside.append(
    el("div", { class: "necto-detail-title necto-detail-title-wrap" }, [
      ...(selected ? [statusCell(selected)] : []),
      el("span", { class: "cell-method" }, [selected?.method ?? ""]),
      el("span", { class: "necto-detail-title-url" }, [selected?.url ?? ""]),
      close,
    ]),
    el(
      "div",
      { class: "necto-tabs" },
      tabs.map(({ id, label }) => {
        const button = el("button", {
          type: "button",
          class: "necto-tab",
          "aria-selected": tab === id ? "true" : "false",
        }, [label]);
        button.addEventListener("click", () => {
          tab = id;
          renderDetail();
        });
        return button;
      }),
    ),
    el("div", { class: "necto-detail-body" }, detailBody()),
  );

  detailSlot.append(aside);
  detailPane.mount(aside);
}

function detailBody(): Node[] {
  if (!detail) return [el("p", { class: "necto-caption" }, [t("Loading…")])];
  if (tab === "summary") return [summary(detail)];
  // On its own tab because it is looked up to be copied, not read.
  if (tab === "curl") return [codeBlock(detail.curl ?? t("No command available."))];
  return exchange(detail, tab);
}

// -- actions -----------------------------------------------------------------

async function select(id: string): Promise<void> {
  selectedID = id;
  detail = null;
  renderList();
  renderDetail();

  try {
    // Bodies live behind their own operation, so scrolling a long list does not drag
    // every response body along with it.
    detail = await loadDetail(id);
  } catch (error) {
    message = String(error);
  }
  renderDetail();
}

function closeDetail(): void {
  selectedID = null;
  detail = null;
  renderList();
  renderDetail();
}

/// Dragging is tracked on the window rather than the handle: the pointer routinely
/// leaves a 7px target mid-drag, and a handler bound to the handle would stop
/// following it.

filter.addEventListener("input", () => {
  query = filter.value;
  renderList();
});

clearButton.addEventListener("click", () => {
  void clearRecords()
    .then(() => {
      records.clear();
      closeDetail();
    })
    .catch((error: unknown) => {
      message = String(error);
      renderList();
    });
});

/// Arrow keys walk the log and Escape closes the pane.
listPane.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    closeDetail();
    return;
  }
  if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;

  event.preventDefault();
  const visible = visibleRecords();
  const index = visible.findIndex((record) => record.id === selectedID);
  const next = event.key === "ArrowDown" ? index + 1 : index - 1;
  const target = visible[Math.max(0, Math.min(visible.length - 1, next))];
  if (target) void select(target.id);
});

// -- start -------------------------------------------------------------------

renderList();

void observeRecords({
  // A record arrives twice, pending then finished. Keying by id means the finished one
  // replaces the pending row rather than adding to it.
  onRecord: (record) => {
    records.set(record.id, record);
    renderList();
  },
  onError: (reason) => {
    message = reason;
    renderList();
  },
});
