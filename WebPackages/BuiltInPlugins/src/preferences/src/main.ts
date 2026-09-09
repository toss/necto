//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import "./style.css";

import { createDetailPane, necto, isNectoBridgeError, type NectoJSONValue } from "@necto/bridge";
import { t } from "./localization";

interface Entry {
  key: string;
  type: string;
  preview: string;
  isTruncated: boolean;
}

interface Detail {
  key: string;
  type: string;
  value: string;
}

// -- state -------------------------------------------------------------------

let suites: string[] = ["standard"];
let suite = "standard";
let entries: Entry[] = [];
let total = 0;
let query = "";
let selectedKey: string | null = null;
let detail: Detail | null = null;
let message: string | null = null;
const detailPane = createDetailPane("necto.preferences.detail");

/// Nodes rather than markup: keys and values come from whatever the app stored, and
/// none of it is ours to trust in an `innerHTML`.
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

function visibleEntries(): Entry[] {
  const term = query.trim().toLowerCase();
  return entries.filter((entry) => !term || entry.key.toLowerCase().includes(term));
}

// -- the shell ---------------------------------------------------------------

const suitesBar = el("div", { class: "necto-segmented" });

const filter = el("input", {
  class: "necto-field",
  type: "search",
  placeholder: t("Filter keys"),
  "aria-label": t("Filter keys"),
}) as HTMLInputElement;

const count = el("span", { class: "necto-caption" });

/// `tabindex` so the arrow keys below have somewhere to land: a list a developer scans
/// should not need the pointer.
const listPane = el("div", { class: "necto-body", tabindex: "0" });
const detailSlot = el("div", { class: "detail-slot" });

document.getElementById("root")?.append(
  el("div", { class: "necto-app" }, [
    el("div", { class: "necto-toolbar" }, [suitesBar, filter, count]),
    listPane,
    detailSlot,
  ]),
);

// -- rendering ---------------------------------------------------------------

function renderSuites(): void {
  suitesBar.replaceChildren();
  // One store needs no switcher.
  if (suites.length < 2) return;

  for (const name of suites) {
    const tab = el("button", { type: "button", "aria-selected": String(name === suite) }, [name]);
    tab.addEventListener("click", () => {
      suite = name;
      closeDetail();
      void load();
    });
    suitesBar.append(tab);
  }
}

/// The list and the detail pane are rebuilt on their own. Replacing the whole page
/// would take the filter field's focus and caret with it.
function renderList(): void {
  const shown = visibleEntries();
  count.textContent = query ? t("{shown} of {total}", { shown: shown.length, total }) : String(total);
  listPane.replaceChildren();

  if (!shown.length) {
    listPane.append(
      el("div", { class: "necto-empty" }, [
        el("p", { class: "necto-empty-title" }, [message ?? t(query ? "Nothing matches" : "Nothing stored")]),
        el("p", { class: "necto-caption" }, [
          t(query ? "No key contains that text." : "Keys the app stores appear here."),
        ]),
      ]),
    );
    return;
  }

  const table = el("table", { class: "necto-table" }, [
    el("thead", {}, [
      el("tr", {}, [
        el("th", {}, [t("Key")]),
        el("th", { style: "width:96px" }, [t("Type")]),
        el("th", { style: "width:260px" }, [t("Value")]),
      ]),
    ]),
    el(
      "tbody",
      {},
      shown.map((entry) => {
        const row = el("tr", { "aria-selected": entry.key === selectedKey ? "true" : undefined }, [
          el("td", {}, [entry.key]),
          el("td", {}, [el("span", { class: "necto-badge" }, [entry.type])]),
          el("td", {}, [entry.preview + (entry.isTruncated ? "…" : "")]),
        ]);
        row.addEventListener("click", () => void select(entry.key));
        return row;
      }),
    ),
  ]);

  listPane.append(table);
}

function renderDetail(): void {
  detailPane.unmount();
  detailSlot.replaceChildren();
  if (!selectedKey) return;

  const aside = el("aside", { class: "necto-detail" });
  const close = el("button", {
    type: "button",
    class: "necto-button necto-button-quiet",
    "aria-label": t("Close details"),
  }, ["✕"]);
  close.addEventListener("click", closeDetail);

  aside.append(
    el("div", { class: "necto-detail-title" }, [
      ...(detail ? [el("span", { class: "necto-badge" }, [detail.type])] : []),
      el("span", { class: "necto-detail-title-url" }, [selectedKey]),
      close,
    ]),
    el("div", { class: "necto-detail-body" }, detailBody()),
  );

  detailSlot.append(aside);
  detailPane.mount(aside);
}

function detailBody(): Node[] {
  if (!detail) return [el("p", { class: "necto-caption" }, [t("Loading…")])];

  const note = el("span", { class: "necto-caption" }, [""]);
  const failed = (error: unknown) => {
    note.textContent = messageOf(error);
  };

  // Removal cannot be undone, so the button asks in its own words: the first click
  // arms it, the second one does it.
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

  const copy = el("button", { type: "button", class: "necto-button" }, [t("Copy")]);
  copy.addEventListener("click", () => {
    const restore = () => setTimeout(() => (copy.textContent = t("Copy")), 1400);
    void navigator.clipboard?.writeText(detail?.value ?? "").then(
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

  const actions = (leading: Node[]) =>
    el("div", { style: "display:flex; gap:8px; margin-top:var(--necto-space-2); align-items:center" }, [
      ...leading,
      copy,
      note,
      remove,
    ]);

  // A value is edited in its own shape: a Bool is a switch, a number is a number
  // field, JSON is JSON. One string box for everything makes every edit a retype.
  switch (detail.type) {
    case "Bool": {
      // A switch is its own save; a switch with a Save button is two switches.
      const toggle = el("button", {
        type: "button",
        class: "necto-switch",
        role: "switch",
        "aria-checked": detail.value === "true" ? "true" : "false",
        "aria-label": t("Value"),
      });
      toggle.addEventListener("click", () => {
        void write(detail?.value === "true" ? false : true).catch(failed);
      });
      return [pairs(), valueTitle(), toggle, actions([])];
    }

    case "Int":
    case "Double": {
      const field = numberField(detail.value);
      const save = saveButton(() => {
        const number = Number(field.value.trim());
        if (!Number.isFinite(number) || (detail?.type === "Int" && !Number.isInteger(number))) {
          note.textContent = t("Not a valid {type}", { type: detail?.type ?? "number" });
          return;
        }
        void write(number, detail?.type).catch(failed);
      });
      saveOnReturn(field, save);
      return [pairs(), valueTitle(), field, actions([save])];
    }

    case "String":
    case "Date": {
      const field = el("input", {
        class: "necto-field",
        style: "width:100%; font-family:var(--necto-font-mono)",
        "aria-label": t("Value"),
      }) as HTMLInputElement;
      field.value = detail.value;
      const save = saveButton(() => {
        void write(field.value, detail?.type === "Date" ? "Date" : undefined).catch(failed);
      });
      saveOnReturn(field, save);
      return [pairs(), valueTitle(), field, actions([save])];
    }

    case "Array": {
      // Rows rather than a JSON blob: one element per field, and an element that is
      // itself structured is one line of JSON in its row.
      let items: string[];
      try {
        items = (JSON.parse(detail.value) as NectoJSONValue[]).map(display);
      } catch {
        items = [];
      }

      const rows = el("div", { style: "display:flex; flex-direction:column; gap:6px; max-width:560px" });
      const renderRows = () => {
        rows.replaceChildren(
          ...items.map((item, index) => {
            const field = el("input", {
              class: "necto-field",
              style: "flex:1; font-family:var(--necto-font-mono)",
              "aria-label": t("Item {index}", { index: index + 1 }),
            }) as HTMLInputElement;
            field.value = item;
            field.addEventListener("input", () => {
              items[index] = field.value;
            });
            const drop = el(
              "button",
              { type: "button", class: "necto-button necto-button-quiet", "aria-label": t("Remove item") },
              ["✕"],
            );
            drop.addEventListener("click", () => {
              items.splice(index, 1);
              renderRows();
            });
            return el("div", { style: "display:flex; gap:6px" }, [field, drop]);
          }),
          (() => {
            const add = el(
              "button",
              { type: "button", class: "necto-button necto-button-quiet", style: "align-self:flex-start" },
              [t("+ Add item")],
            );
            add.addEventListener("click", () => {
              items.push("");
              renderRows();
            });
            return add;
          })(),
        );
      };
      renderRows();

      const save = saveButton(() => {
        void write(items.map(element)).catch(failed);
      });
      return [pairs(), valueTitle(), rows, actions([save])];
    }

    case "Dictionary": {
      let fields: [string, string][];
      try {
        fields = Object.entries(JSON.parse(detail.value) as Record<string, NectoJSONValue>).map(
          ([key, value]) => [key, display(value)],
        );
      } catch {
        fields = [];
      }

      const rows = el("div", { style: "display:flex; flex-direction:column; gap:6px; max-width:560px" });
      const renderRows = () => {
        rows.replaceChildren(
          ...fields.map((pair, index) => {
            const key = el("input", {
              class: "necto-field",
              style: "flex:none; width:180px; font-family:var(--necto-font-mono)",
              "aria-label": t("Key"),
            }) as HTMLInputElement;
            key.value = pair[0];
            key.addEventListener("input", () => {
              pair[0] = key.value;
            });
            const value = el("input", {
              class: "necto-field",
              style: "flex:1; font-family:var(--necto-font-mono)",
              "aria-label": t("Value"),
            }) as HTMLInputElement;
            value.value = pair[1];
            value.addEventListener("input", () => {
              pair[1] = value.value;
            });
            const drop = el(
              "button",
              { type: "button", class: "necto-button necto-button-quiet", "aria-label": t("Remove pair") },
              ["✕"],
            );
            drop.addEventListener("click", () => {
              fields.splice(index, 1);
              renderRows();
            });
            return el("div", { style: "display:flex; gap:6px" }, [key, value, drop]);
          }),
          (() => {
            const add = el(
              "button",
              { type: "button", class: "necto-button necto-button-quiet", style: "align-self:flex-start" },
              [t("+ Add pair")],
            );
            add.addEventListener("click", () => {
              fields.push(["", ""]);
              renderRows();
            });
            return add;
          })(),
        );
      };
      renderRows();

      const save = saveButton(() => {
        const seen = new Set<string>();
        for (const [key] of fields) {
          if (!key.trim()) {
            note.textContent = t("A pair is missing its key");
            return;
          }
          if (!seen.add(key)) {
            note.textContent = t("Duplicate key '{key}'", { key });
            return;
          }
        }
        void write(Object.fromEntries(fields.map(([key, value]) => [key, element(value)]))).catch(failed);
      });
      return [pairs(), valueTitle(), rows, actions([save])];
    }

    default:
      // Data and anything unrecognised: shown, never edited. Writing base64 back
      // through a text box is how a token gets corrupted.
      return [
        pairs(),
        valueTitle(),
        el("p", { class: "necto-caption" }, [t("{value} — not editable from here", { value: detail.value })]),
        actions([]),
      ];
  }

  function pairs(): Node {
    return el("dl", { class: "necto-pairs" }, [
      el("div", {}, [el("dt", {}, [t("Suite")]), el("dd", {}, [suite])]),
      el("div", {}, [el("dt", {}, [t("Type")]), el("dd", {}, [detail?.type ?? ""])]),
    ]);
  }

  function valueTitle(): Node {
    return el("p", { class: "necto-section-title" }, [t("Value")]);
  }

  function numberField(value: string): HTMLInputElement {
    const field = el("input", {
      class: "necto-field",
      style: "width:180px; text-align:right; font-family:var(--necto-font-mono)",
      inputmode: "decimal",
      "aria-label": t("Value"),
    }) as HTMLInputElement;
    field.value = value;
    return field;
  }

  function saveButton(onSave: () => void): HTMLButtonElement {
    const save = el("button", { type: "button", class: "necto-button necto-button-primary" }, [t("Save")]);
    save.addEventListener("click", onSave);
    return save;
  }

  /// A string element shows as itself; anything structured shows as one line of JSON.
  function display(value: NectoJSONValue): string {
    return typeof value === "string" ? value : JSON.stringify(value);
  }

  /// The reverse: `47` is a number, `true` a Bool, `{"a":1}` an object, and anything
  /// that is not JSON is the string it looks like.
  function element(text: string): NectoJSONValue {
    try {
      return JSON.parse(text) as NectoJSONValue;
    } catch {
      return text;
    }
  }

  function saveOnReturn(field: HTMLInputElement, save: HTMLButtonElement): void {
    field.addEventListener("keydown", (event) => {
      if (event.key === "Enter") save.click();
    });
  }
}


// -- actions -----------------------------------------------------------------

async function select(key: string): Promise<void> {
  if (selectedKey === key) {
    closeDetail();
    return;
  }
  selectedKey = key;
  detail = null;
  renderList();
  renderDetail();

  try {
    const output = await necto.device.send<{ entry: Detail }>("preferences.detail", { suite, key });
    detail = output.entry;
  } catch (error) {
    message = messageOf(error);
  }
  renderDetail();
}

function closeDetail(): void {
  selectedKey = null;
  detail = null;
  renderList();
  renderDetail();
}

/// Sent as what it parses to, so editing `47` keeps it a number and `true` a Bool.
/// Anything that is not JSON is the string it looks like.
function parsed(text: string): NectoJSONValue {
  try {
    return JSON.parse(text) as NectoJSONValue;
  } catch {
    return text;
  }
}

async function write(value: NectoJSONValue, typeHint?: string): Promise<void> {
  const key = selectedKey;
  if (!key) return;
  const output = await necto.device.send<{ entry: Detail }>("preferences.set", {
    suite,
    key,
    value,
    ...(typeHint ? { type: typeHint } : {}),
  });
  detail = output.entry;
  await load();
  renderDetail();
}

async function erase(): Promise<void> {
  if (!selectedKey) return;
  try {
    await necto.device.send("preferences.remove", { suite, key: selectedKey });
    closeDetail();
    await load();
  } catch (error) {
    message = messageOf(error);
    renderList();
  }
}

async function load(): Promise<void> {
  try {
    const output = await necto.device.send<{ entries: Entry[]; total?: number }>("preferences.list", { suite });
    entries = output.entries;
    total = output.total ?? entries.length;
    message = null;
  } catch (error) {
    entries = [];
    total = 0;
    message = messageOf(error);
  }
  renderSuites();
  renderList();
}

// -- input -------------------------------------------------------------------

filter.addEventListener("input", () => {
  query = filter.value;
  renderList();
});

/// Arrow keys walk the list and Escape closes the pane.
listPane.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    closeDetail();
    return;
  }
  if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;

  event.preventDefault();
  const visible = visibleEntries();
  const index = visible.findIndex((entry) => entry.key === selectedKey);
  const next = event.key === "ArrowDown" ? index + 1 : index - 1;
  const target = visible[Math.max(0, Math.min(visible.length - 1, next))];
  if (target && target.key !== selectedKey) void select(target.key);
});

// -- start -------------------------------------------------------------------

async function main(): Promise<void> {
  if (!necto.isAvailable()) {
    message = t("This plugin only works inside Necto");
    renderList();
    return;
  }

  try {
    suites = (await necto.device.send<{ suites: string[] }>("preferences.suites")).suites;
    suite = suites[0] ?? "standard";
  } catch {
    // The list still works against the standard store.
  }

  await load();
  await necto.ready();
}

void main();
