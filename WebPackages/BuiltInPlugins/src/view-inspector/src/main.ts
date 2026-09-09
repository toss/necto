//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import "./style.css";

import { createDetailPane, necto, isNectoBridgeError, type NectoJSONObject } from "@necto/bridge";
import { t } from "./localization";

if (import.meta.env.DEV) {
  const { installMockBridge } = await import("./mock");
  installMockBridge();
}

interface ViewNode {
  id: string;
  className: string;
  frame: [number, number, number, number];
  text?: string;
  isHidden?: boolean;
  alpha?: number;
  children: ViewNode[];
}

// -- state -------------------------------------------------------------------

let windows: ViewNode[] = [];
/// Rows are addressed by their path through the tree — "0/2/1" — because a snapshot
/// has no ids and two siblings can be the same class.
const collapsed = new Set<string>();
let selectedPath: string | null = null;
let query = "";
let message: string | null = null;
const detailPane = createDetailPane("necto.view-inspector.detail");
let baselineSnapshotID: string | null = null;

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

function messageOf(error: unknown): string {
  return isNectoBridgeError(error) ? error.message : String(error);
}

function nodeAt(path: string): ViewNode | null {
  let list = windows;
  let found: ViewNode | null = null;
  for (const part of path.split("/")) {
    found = list[Number(part)] ?? null;
    if (!found) return null;
    list = found.children;
  }
  return found;
}

// -- the shell ---------------------------------------------------------------

const refresh = el("button", { type: "button", class: "necto-button" }, [t("Refresh")]);
const saveBaseline = el("button", { type: "button", class: "necto-button necto-button-quiet" }, [t("Save baseline")]);
const compare = el("button", { type: "button", class: "necto-button necto-button-quiet", disabled: "" }, [t("Compare")]);
const filter = el("input", {
  class: "necto-field",
  type: "search",
  placeholder: t("Filter by class or text"),
  "aria-label": t("Filter by class or text"),
}) as HTMLInputElement;
const count = el("span", { class: "necto-caption" });
const status = el("span", { class: "necto-caption", role: "status" });

const listPane = el("div", { class: "necto-body", tabindex: "0" });
const detailSlot = el("div", { class: "detail-slot" });

document.getElementById("root")?.append(
  el("div", { class: "necto-app" }, [
    el("div", { class: "necto-toolbar" }, [refresh, saveBaseline, compare, filter, count, status]),
    listPane,
    detailSlot,
  ]),
);

// -- rendering ---------------------------------------------------------------

interface Row {
  node: ViewNode;
  path: string;
  depth: number;
}

/// The whole forest flattened, honouring collapse — or, when filtering, just the
/// matches at their own depth, because a match buried twelve levels deep is the
/// whole point of filtering.
function visibleRows(): Row[] {
  const rows: Row[] = [];
  const term = query.trim().toLowerCase();

  const walk = (nodes: ViewNode[], prefix: string, depth: number) => {
    nodes.forEach((node, index) => {
      const path = prefix ? `${prefix}/${index}` : String(index);
      const matches =
        !term ||
        node.className.toLowerCase().includes(term) ||
        (node.text ?? "").toLowerCase().includes(term);
      if (matches) rows.push({ node, path, depth });
      if (term || !collapsed.has(path)) walk(node.children, path, depth + 1);
    });
  };
  walk(windows, "", 0);
  return rows;
}

function renderTree(): void {
  listPane.replaceChildren();
  const rows = visibleRows();
  count.textContent = String(rows.length);

  if (!rows.length) {
    listPane.append(
      el("div", { class: "necto-empty" }, [
        el("p", { class: "necto-empty-title" }, [message ?? t(query ? "Nothing matches" : "No windows")]),
        el("p", { class: "necto-caption" }, [
          t(query ? "No view has that class or text." : "Refresh takes a new snapshot of the connected app."),
        ]),
      ]),
    );
    return;
  }

  const tree = el("div", { class: "necto-tree" });
  for (const { node, path, depth } of rows) {
    const hasChildren = node.children.length > 0;
    const row = el("button", {
      type: "button",
      class: "necto-tree-row",
      "aria-selected": path === selectedPath ? "true" : undefined,
      style: `padding-left: calc(${query ? 0 : depth} * 14px + var(--necto-space-3))`,
    }, [
      el("span", { class: "necto-tree-twist" }, [
        hasChildren && !query ? (collapsed.has(path) ? "▸" : "▾") : "",
      ]),
      (() => {
        const name = el("span", { class: "necto-tree-name" }, [node.className]);
        if (node.text) name.append(el("em", {}, [` “${node.text}”`]));
        return name;
      })(),
      el("span", { class: "necto-tree-meta" }, [
        `${Math.round(node.frame[2])} × ${Math.round(node.frame[3])}`,
      ]),
    ]);

    // The twist folds, the row selects: two intents, two targets.
    row.addEventListener("click", (event) => {
      const twist = (event.target as HTMLElement).closest(".necto-tree-twist");
      if (twist && hasChildren && !query) {
        if (collapsed.has(path)) collapsed.delete(path);
        else collapsed.add(path);
        renderTree();
        return;
      }
      select(path);
    });
    tree.append(row);
  }
  listPane.append(tree);
}

function renderDetail(): void {
  detailPane.unmount();
  detailSlot.replaceChildren();
  if (!selectedPath) return;
  const node = nodeAt(selectedPath);
  if (!node) return;

  const aside = el("aside", { class: "necto-detail" });
  const close = el("button", {
    type: "button",
    class: "necto-button necto-button-quiet",
    "aria-label": t("Close details"),
  }, ["✕"]);
  close.addEventListener("click", () => select(selectedPath!));

  const [x, y, width, height] = node.frame;

  // The window this view lives in, for the little map: the first path segment is
  // the window index.
  const windowNode = windows[Number(selectedPath.split("/")[0])];
  const [windowX, windowY, windowWidth, windowHeight] = windowNode?.frame ?? [0, 0, 1, 1];

  const map = el("div", {
    class: "view-map",
    role: "button",
    tabindex: "0",
    "aria-label": t("Tap or drag on screen"),
    style: `aspect-ratio:${windowWidth} / ${windowHeight}`,
  }, [
    el("div", {
      class: "view-map-selection",
      style:
        `left:${((x - windowX) / windowWidth) * 100}%; top:${((y - windowY) / windowHeight) * 100}%;` +
        `width:${(width / windowWidth) * 100}%; height:${(height / windowHeight) * 100}%`,
    }),
  ]);
  bindMapInput(map, [windowX, windowY, windowWidth, windowHeight]);

  const text = el("input", {
    class: "necto-field view-text-input",
    type: "text",
    placeholder: t("Text to enter"),
    "aria-label": t("Text to enter"),
  }) as HTMLInputElement;
  const sendText = actionButton(t("Enter"), "views.inputText", () => ({
    viewID: node.id,
    text: text.value,
    replace: true,
  }));
  text.addEventListener("keydown", (event) => {
    if (event.key === "Enter") sendText.click();
  });

  aside.append(
    el("div", { class: "necto-detail-title" }, [
      el("span", { class: "necto-detail-title-url" }, [
        node.className + (node.text ? ` “${node.text}”` : ""),
      ]),
      close,
    ]),
    el("div", { class: "necto-detail-body", style: "display:flex; flex-direction:column; gap:var(--necto-space-4)" }, [
      el("dl", { class: "necto-pairs", style: "flex:1" }, [
        el("div", {}, [el("dt", {}, [t("Frame")]), el("dd", {}, [
          `${Math.round(x)}, ${Math.round(y)} · ${Math.round(width)} × ${Math.round(height)}`,
        ])]),
        el("div", {}, [el("dt", {}, [t("Children")]), el("dd", {}, [String(node.children.length)])]),
        el("div", {}, [el("dt", {}, [t("Alpha")]), el("dd", {}, [String(node.alpha ?? 1)])]),
        el("div", {}, [el("dt", {}, [t("Hidden")]), el("dd", {}, [node.isHidden ? "true" : "false"])]),
        ...(node.text ? [el("div", {}, [el("dt", {}, [t("Text")]), el("dd", {}, [node.text])])] : []),
      ]),
      el("div", { class: "view-actions" }, [
        el("span", { class: "necto-caption" }, [t("Tap or drag on screen")]),
        map,
        el("div", { class: "view-action-buttons" }, [
          actionButton(t("Highlight"), "views.highlight", { viewID: node.id, duration: 1 }),
          actionButton(t("Tap"), "views.tap", { viewID: node.id }),
          actionButton(t("Hold"), "views.longPress", { viewID: node.id }),
          actionButton("↑", "views.swipe", { viewID: node.id, direction: "up" }),
          actionButton("↓", "views.swipe", { viewID: node.id, direction: "down" }),
          actionButton("←", "views.swipe", { viewID: node.id, direction: "left" }),
          actionButton("→", "views.swipe", { viewID: node.id, direction: "right" }),
        ]),
        el("div", { class: "view-text-controls" }, [text, sendText]),
      ]),
    ]),
  );

  detailSlot.append(aside);
  detailPane.mount(aside);
}


// -- actions -----------------------------------------------------------------

function select(path: string): void {
  selectedPath = selectedPath === path ? null : path;
  renderTree();
  renderDetail();
}

function bindMapInput(map: HTMLDivElement, frame: [number, number, number, number]): void {
  let start: { pointerID: number; point: { x: number; y: number } } | null = null;
  const point = (event: PointerEvent) => {
    const bounds = map.getBoundingClientRect();
    return {
      x: frame[0] + ((event.clientX - bounds.left) / bounds.width) * frame[2],
      y: frame[1] + ((event.clientY - bounds.top) / bounds.height) * frame[3],
    };
  };
  map.addEventListener("pointerdown", (event) => {
    start = { pointerID: event.pointerId, point: point(event) };
    map.setPointerCapture(event.pointerId);
  });
  map.addEventListener("pointerup", (event) => {
    if (!start || start.pointerID !== event.pointerId) return;
    const end = point(event);
    const distance = Math.hypot(end.x - start.point.x, end.y - start.point.y);
    const origin = start.point;
    start = null;
    if (distance < 4) {
      void runAction("views.tapAt", { x: end.x, y: end.y });
    } else {
      void runAction("views.drag", { fromX: origin.x, fromY: origin.y, toX: end.x, toY: end.y });
    }
  });
  map.addEventListener("pointercancel", () => { start = null; });
  map.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" && event.key !== " ") return;
    event.preventDefault();
    void runAction("views.tapAt", {
      x: frame[0] + frame[2] / 2,
      y: frame[1] + frame[3] / 2,
    });
  });
}

async function runAction(operation: string, input: NectoJSONObject): Promise<void> {
  try {
    const result = await necto.device.send<NectoJSONObject>(operation, input);
    message = null;
    status.textContent = typeof result.method === "string" ? result.method : t("Done");
  } catch (error) {
    message = messageOf(error);
    status.textContent = message;
  }
}

function actionButton(
  label: string,
  operation: string,
  input: NectoJSONObject | (() => NectoJSONObject),
): HTMLButtonElement {
  const button = el("button", { type: "button", class: "necto-button necto-button-quiet" }, [label]);
  button.addEventListener("click", async () => {
    await runAction(operation, typeof input === "function" ? input() : input);
  });
  return button;
}

async function load(): Promise<void> {
  try {
    windows = (await necto.device.send<{ windows: ViewNode[] }>("views.tree")).windows;
    message = null;
    status.textContent = "";
  } catch (error) {
    windows = [];
    message = messageOf(error);
  }
  // A new snapshot is a new tree; selection and folds belonged to the old one.
  collapsed.clear();
  selectedPath = null;
  renderTree();
  renderDetail();
}

// -- input -------------------------------------------------------------------

refresh.addEventListener("click", () => void load());

saveBaseline.addEventListener("click", async () => {
  try {
    const result = await necto.device.send<{ snapshotID: string; windows: ViewNode[] }>("views.snapshot");
    baselineSnapshotID = result.snapshotID;
    windows = result.windows;
    compare.removeAttribute("disabled");
    count.textContent = t("Baseline saved");
    renderTree();
  } catch (error) {
    message = messageOf(error);
    renderTree();
  }
});

compare.addEventListener("click", async () => {
  if (!baselineSnapshotID) return;
  try {
    const result = await necto.device.send<{ changes: unknown[] }>("views.compare", {
      baselineSnapshotID,
    });
    await load();
    count.textContent = t("{count} changes", { count: result.changes.length });
  } catch (error) {
    message = messageOf(error);
    renderTree();
  }
});

filter.addEventListener("input", () => {
  query = filter.value;
  renderTree();
});

listPane.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && selectedPath) select(selectedPath);
});

// -- start -------------------------------------------------------------------

async function main(): Promise<void> {
  if (!necto.isAvailable()) {
    message = t("This plugin only works inside Necto");
    renderTree();
    return;
  }

  await load();
  await necto.ready();
}

void main();
