//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import "./style.css";

import { createDetailPane, necto, isNectoBridgeError } from "@necto/bridge";
import { t } from "./localization";

interface Root {
  id: string;
  name: string;
  path?: string;
}

interface Entry {
  name: string;
  isDirectory: boolean;
  size?: number;
  itemCount?: number;
  modifiedAt?: number;
  createdAt?: number;
}

interface Preview {
  name: string;
  kind: "text" | "image" | "binary";
  size: number;
  modifiedAt?: number;
  text?: string;
  isTruncated?: boolean;
  mediaType?: string;
  base64?: string;
}

// -- state -------------------------------------------------------------------

let roots: Root[] = [];
let rootID = "";
/// Directory path → its entries, loaded on first expand. The tree draws from this.
const loaded = new Map<string, Entry[]>();
const expanded = new Set<string>();
let selectedPath: string | null = null;
let preview: Preview | null = null;
let info: Entry | null = null;
let editing = false;
let draft = "";
let detailMessage = "";
let message: string | null = null;
const detailPane = createDetailPane("necto.files.detail");

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

function formatSize(bytes: number): string {
  if (bytes >= 1_048_576) return `${(bytes / 1_048_576).toFixed(1)} MB`;
  if (bytes >= 1024) return `${(bytes / 1024).toFixed(1)} kB`;
  return `${bytes} B`;
}

function formatTime(milliseconds: number): string {
  const date = new Date(milliseconds);
  const pad = (value: number) => String(value).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

// -- the shell ---------------------------------------------------------------

const rootsBar = el("div", { class: "necto-segmented" });
const count = el("span", { class: "necto-caption", style: "margin-left:auto" });

const listPane = el("div", { class: "necto-body", tabindex: "0" });
const detailSlot = el("div", { class: "detail-slot" });

document.getElementById("root")?.append(
  el("div", { class: "necto-app" }, [
    el("div", { class: "necto-toolbar" }, [rootsBar, count]),
    listPane,
    detailSlot,
  ]),
);

// -- rendering ---------------------------------------------------------------

function renderRoots(): void {
  rootsBar.replaceChildren();
  for (const root of roots) {
    const tab = el("button", { type: "button", "aria-selected": String(root.id === rootID) }, [root.name]);
    tab.addEventListener("click", () => void switchRoot(root.id));
    rootsBar.append(tab);
  }
}

/// The visible tree, flattened: a row per entry down every expanded branch.
function visibleRows(): { entry: Entry; path: string; depth: number }[] {
  const rows: { entry: Entry; path: string; depth: number }[] = [];
  const walk = (directory: string, depth: number) => {
    for (const entry of loaded.get(directory) ?? []) {
      const path = directory ? `${directory}/${entry.name}` : entry.name;
      rows.push({ entry, path, depth });
      if (entry.isDirectory && expanded.has(path)) walk(path, depth + 1);
    }
  };
  walk("", 0);
  return rows;
}

function renderTree(): void {
  listPane.replaceChildren();
  const rows = visibleRows();
  count.textContent = String(rows.length);

  if (!rows.length) {
    listPane.append(
      el("div", { class: "necto-empty" }, [
        el("p", { class: "necto-empty-title" }, [message ?? t("Nothing here")]),
        el("p", { class: "necto-caption" }, [t("This directory is empty.")]),
      ]),
    );
    return;
  }

  const tree = el("div", { class: "necto-tree" });
  for (const { entry, path, depth } of rows) {
    const row = el("button", {
      type: "button",
      class: "necto-tree-row",
      "aria-selected": path === selectedPath ? "true" : undefined,
      style: `padding-left: calc(${depth} * 16px + var(--necto-space-3))`,
    }, [
      el("span", { class: "necto-tree-twist" }, [entry.isDirectory ? (expanded.has(path) ? "▾" : "▸") : ""]),
      (() => {
        const name = el("span", { class: "necto-tree-name" }, [entry.name]);
        if (entry.isDirectory) name.append(el("em", {}, ["/"]));
        return name;
      })(),
      el("span", { class: "necto-tree-meta" }, [
        entry.isDirectory
          ? t(entry.itemCount === 1 ? "{count} item" : "{count} items", { count: entry.itemCount ?? 0 })
          : formatSize(entry.size ?? 0),
      ]),
    ]);
    row.addEventListener("click", () => {
      if (entry.isDirectory) void toggle(path);
      else void select(path);
    });
    tree.append(row);
  }
  listPane.append(tree);
}

function renderDetail(): void {
  detailPane.unmount();
  detailSlot.replaceChildren();
  if (!selectedPath) return;

  const aside = el("aside", { class: "necto-detail" });
  const close = el("button", {
    type: "button",
    class: "necto-button necto-button-quiet",
    "aria-label": t("Close details"),
  }, ["✕"]);
  close.addEventListener("click", closeDetail);

  aside.append(
    el("div", { class: "necto-detail-title" }, [
      el("span", { class: "necto-detail-title-url" }, [selectedPath]),
      close,
    ]),
    el("div", { class: `necto-detail-body${editing ? " file-edit-body" : ""}` }, detailBody()),
  );

  detailSlot.append(aside);
  detailPane.mount(aside);
}

function detailBody(): Node[] {
  if (!preview) return [el("p", { class: "necto-caption" }, [t("Loading…")])];

  const note = el("span", { class: "necto-caption" }, [detailMessage]);

  const copy = el("button", { type: "button", class: "necto-button" }, [t("Copy path")]);
  copy.addEventListener("click", () => {
    const root = roots.find((candidate) => candidate.id === rootID);
    const absolute = root?.path ? `${root.path}/${selectedPath ?? ""}` : (selectedPath ?? "");
    const restore = () => setTimeout(() => (copy.textContent = t("Copy path")), 1400);
    void navigator.clipboard?.writeText(absolute).then(
      () => {
        copy.textContent = t("Copied");
        restore();
      },
      () => {
        copy.textContent = t("Failed");
        restore();
      },
    );
  });

  // Deleting a file from a running app cannot be undone, so the button asks in its
  // own words: the first click arms it, the second one does it.
  const remove = el(
    "button",
    { type: "button", class: "necto-button necto-button-quiet necto-button-danger", style: "margin-left:auto" },
    [t("Delete")],
  );
  remove.addEventListener("click", () => {
    if (remove.dataset.armed !== "true") {
      remove.dataset.armed = "true";
      remove.textContent = t("Really delete?");
      setTimeout(() => {
        remove.dataset.armed = "false";
        remove.textContent = t("Delete");
      }, 3000);
      return;
    }
    void erase();
  });

  const edit = el("button", { type: "button", class: "necto-button" }, [editing ? t("Cancel") : t("Edit")]);
  edit.addEventListener("click", () => {
    editing = !editing;
    draft = preview?.text ?? "";
    detailMessage = "";
    renderDetail();
  });

  const save = el("button", { type: "button", class: "necto-button necto-button-primary" }, [t("Save")]);
  save.addEventListener("click", () => void saveText());

  const contents: Node[] = [];
  if (preview.kind === "image" && preview.base64) {
    const image = el("img", {
      class: "file-image",
      alt: t("Preview of {name}", { name: preview.name }),
      src: `data:${preview.mediaType ?? "application/octet-stream"};base64,${preview.base64}`,
    });
    contents.push(el("div", { class: "file-image-frame" }, [image]));
  } else if (preview.kind === "text") {
    if (editing) {
      const editor = el("textarea", {
        class: "necto-field necto-json-editor",
        "aria-label": t("File contents"),
        spellcheck: "false",
      });
      editor.value = draft;
      editor.addEventListener("input", () => (draft = editor.value));
      contents.push(editor);
    } else {
      contents.push(el("pre", { class: "necto-code", style: "overflow:auto" }, [preview.text ?? ""]));
    }
  }

  return [
    el("dl", { class: "necto-pairs" }, [
      el("div", {}, [el("dt", {}, [t("Size")]), el("dd", {}, [formatSize(preview.size)])]),
      ...(preview.modifiedAt !== undefined
        ? [el("div", {}, [el("dt", {}, [t("Modified")]), el("dd", {}, [formatTime(preview.modifiedAt)])])]
        : []),
      ...(info?.createdAt !== undefined
        ? [el("div", {}, [el("dt", {}, [t("Created")]), el("dd", {}, [formatTime(info.createdAt)])])]
        : []),
    ]),
    el("p", { class: "necto-section-title" }, [
      preview.kind === "binary"
        ? t("Binary — described rather than rendered")
        : preview.kind === "image"
          ? t("Image")
          : preview.isTruncated
            ? t("Preview · the head of the file")
            : t("Contents"),
    ]),
    ...contents,
    el("div", { class: "file-actions" }, [
      copy,
      ...(preview.kind === "text" && !preview.isTruncated ? [edit] : []),
      ...(editing ? [save] : []),
      note,
      remove,
    ]),
  ];
}


// -- actions -----------------------------------------------------------------

async function loadDirectory(path: string): Promise<void> {
  try {
    const output = await necto.device.send<{ entries: Entry[] }>("files.list", { root: rootID, path });
    loaded.set(path, output.entries);
    message = null;
  } catch (error) {
    loaded.set(path, []);
    message = messageOf(error);
  }
}

async function toggle(path: string): Promise<void> {
  if (expanded.has(path)) {
    expanded.delete(path);
  } else {
    expanded.add(path);
    if (!loaded.has(path)) await loadDirectory(path);
  }
  renderTree();
}

async function select(path: string): Promise<void> {
  if (selectedPath === path) {
    closeDetail();
    return;
  }
  selectedPath = path;
  preview = null;
  info = null;
  editing = false;
  detailMessage = "";
  renderTree();
  renderDetail();

  try {
    const [previewOutput, infoOutput] = await Promise.all([
      necto.device.send<{ file: Preview }>("files.preview", { root: rootID, path }),
      necto.device.send<{ item: Entry }>("files.info", { root: rootID, path }),
    ]);
    preview = previewOutput.file;
    info = infoOutput.item;
  } catch (error) {
    message = messageOf(error);
  }
  renderDetail();
}

function closeDetail(): void {
  selectedPath = null;
  preview = null;
  info = null;
  editing = false;
  draft = "";
  detailMessage = "";
  renderTree();
  renderDetail();
}

async function saveText(): Promise<void> {
  if (!selectedPath || !preview || preview.kind !== "text" || preview.isTruncated) return;
  const path = selectedPath;
  const parent = path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";
  try {
    await necto.device.send("files.write", { root: rootID, path, content: draft });
    const [previewOutput, infoOutput] = await Promise.all([
      necto.device.send<{ file: Preview }>("files.preview", { root: rootID, path }),
      necto.device.send<{ item: Entry }>("files.info", { root: rootID, path }),
    ]);
    preview = previewOutput.file;
    info = infoOutput.item;
    editing = false;
    detailMessage = t("Saved");
    await loadDirectory(parent);
    renderTree();
    renderDetail();
  } catch (error) {
    detailMessage = messageOf(error);
    renderDetail();
  }
}

async function erase(): Promise<void> {
  if (!selectedPath) return;
  const parent = selectedPath.includes("/") ? selectedPath.slice(0, selectedPath.lastIndexOf("/")) : "";
  try {
    await necto.device.send("files.delete", { root: rootID, path: selectedPath });
    closeDetail();
    await loadDirectory(parent);
    renderTree();
  } catch (error) {
    message = messageOf(error);
    renderTree();
  }
}

async function switchRoot(id: string): Promise<void> {
  rootID = id;
  loaded.clear();
  expanded.clear();
  closeDetail();
  await loadDirectory("");
  renderRoots();
  renderTree();
}

// -- start -------------------------------------------------------------------

async function main(): Promise<void> {
  if (!necto.isAvailable()) {
    message = t("This plugin only works inside Necto");
    renderTree();
    return;
  }

  try {
    roots = (await necto.device.send<{ roots: Root[] }>("files.roots")).roots;
  } catch (error) {
    message = messageOf(error);
    renderTree();
    await necto.ready();
    return;
  }

  await switchRoot(roots[0]?.id ?? "");
  await necto.ready();
}

void main();
