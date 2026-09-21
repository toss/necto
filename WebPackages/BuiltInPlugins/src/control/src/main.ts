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

interface ActionTarget {
  id: string;
  role: string;
  label?: string;
  identifier?: string;
  frame: [number, number, number, number];
  actions: string[];
  tapGestures?: { touchCount: number; tapCount: number }[];
  value?: string;
  isSecure?: boolean;
}

interface AccessibilityItem {
  role: string;
  label?: string;
  identifier?: string;
  value?: string;
  isSecure?: boolean;
}

let elements: ActionTarget[] = [];
let accessibilityItems: AccessibilityItem[] = [];
let mode: "actions" | "reading" = "actions";
let selectedID: string | null = null;
let query = "";
let message: string | null = null;
let acting = false;
let loading = false;
const gestureSettings = new Map<string, { touchCount: number; tapCount: number; distanceRatio: number; durationMs: number; customPosition: boolean; x: number; y: number }>();
const detailPane = createDetailPane("necto.control.detail");

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
  return isNectoBridgeError(error) ? t(error.message) : String(error);
}

const refresh = el("button", { type: "button", class: "necto-button" }, [t("Refresh")]);
const filter = el("input", {
  class: "necto-field", type: "search",
  placeholder: t("Filter elements"), "aria-label": t("Filter elements"),
});
const count = el("span", { class: "necto-caption" });
const statusText = el("span");
const spinner = el("span", { class: "control-spinner", "aria-hidden": "true", hidden: "" });
const status = el("span", { class: "necto-caption control-status", role: "status" }, [spinner, statusText]);
const listPane = el("div", { class: "necto-body", tabindex: "0" });
const detailSlot = el("div", { class: "detail-slot" });
const tabs = el("div", { class: "necto-tabs", role: "tablist", "aria-label": t("Control") });
const actionTab = el("button", { type: "button", class: "necto-tab", role: "tab", id: "actions-tab",
  "aria-selected": "true", "aria-controls": "control-content" }, [t("Actions")]);
const readingTab = el("button", { type: "button", class: "necto-tab", role: "tab", id: "reading-tab",
  "aria-selected": "false", "aria-controls": "control-content", tabindex: "-1" }, [t("Read accessibility")]);
tabs.append(actionTab, readingTab);
listPane.id = "control-content";
listPane.setAttribute("role", "tabpanel");
listPane.setAttribute("aria-labelledby", actionTab.id);

function changeMode(next: typeof mode): void {
  if (acting || loading || mode === next) return;
  mode = next;
  query = "";
  filter.value = "";
  filter.placeholder = t(mode === "actions" ? "Filter elements" : "Filter accessibility content");
  filter.setAttribute("aria-label", filter.placeholder);
  actionTab.setAttribute("aria-selected", String(mode === "actions"));
  readingTab.setAttribute("aria-selected", String(mode === "reading"));
  actionTab.tabIndex = mode === "actions" ? 0 : -1;
  readingTab.tabIndex = mode === "reading" ? 0 : -1;
  listPane.setAttribute("aria-labelledby", mode === "actions" ? actionTab.id : readingTab.id);
  refresh.textContent = t(mode === "actions" ? "Refresh" : "Read");
  renderDetail();
  void load();
}

actionTab.addEventListener("click", () => changeMode("actions"));
readingTab.addEventListener("click", () => changeMode("reading"));
tabs.addEventListener("keydown", (event) => {
  if (acting || loading) return;
  if (["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) {
    event.preventDefault();
    const next = event.key === "Home" ? "actions" : event.key === "End" ? "reading"
      : mode === "actions" ? "reading" : "actions";
    changeMode(next);
    (next === "actions" ? actionTab : readingTab).focus();
  }
});

document.getElementById("root")?.append(
  el("div", { class: "necto-app" }, [
    tabs,
    el("div", { class: "necto-app control-workspace" }, [
      el("div", { class: "necto-toolbar" }, [refresh, filter, count, status]),
      listPane, detailSlot,
    ]),
  ]),
);

function title(element: ActionTarget): string {
  return element.label || element.identifier || roleLabel(element.role);
}

function roleLabel(role: string): string {
  return t(({ button: "Button", textInput: "Text input", scrollArea: "Scroll area", screen: "Screen",
    heading: "Heading", text: "Text", link: "Link", image: "Image", adjustable: "Adjustable", element: "Element",
  } as Record<string, string>)[role] ?? role);
}

function renderList(): void {
  listPane.replaceChildren();
  if (mode === "reading") { renderReading(); return; }
  const term = query.trim().toLowerCase();
  const matches = elements.filter((element) => !term ||
    [element.label, element.identifier, element.role, roleLabel(element.role)].some((value) => value?.toLowerCase().includes(term)));
  count.textContent = String(matches.length);
  if (!matches.length) {
    listPane.append(el("div", { class: "necto-empty" }, [
      el("p", { class: "necto-empty-title" }, [message ?? t(query ? "Nothing matches" : "No actionable elements")]),
      el("p", { class: "necto-caption" }, [t("Refresh to find controls on the current screen.")]),
    ]));
    return;
  }
  const list = el("div", { class: "necto-tree", "aria-label": t("Elements") });
  for (const element of matches) {
    const row = el("button", {
      type: "button", class: "necto-tree-row", "aria-pressed": String(element.id === selectedID),
      "aria-selected": element.id === selectedID ? "true" : undefined,
      disabled: acting || loading ? "" : undefined,
    }, [
      el("span", { class: "necto-tree-name", title: title(element) }, [title(element)]),
      el("span", { class: "necto-tree-meta" }, [roleLabel(element.role)]),
    ]);
    row.addEventListener("click", () => select(element.id));
    list.append(row);
  }
  listPane.append(list);
}

function renderReading(): void {
  const term = query.trim().toLowerCase();
  const matches = accessibilityItems.filter((item) => !term ||
    [item.label, item.identifier, item.role, roleLabel(item.role), item.isSecure ? undefined : item.value]
      .some((value) => value?.toLowerCase().includes(term)));
  count.textContent = String(matches.length);
  if (!matches.length) {
    listPane.append(el("div", { class: "necto-empty" }, [
      el("p", { class: "necto-empty-title" }, [message ?? t(query ? "Nothing matches" : "No accessibility content")]),
      el("p", { class: "necto-caption" }, [t("Read the current screen to check text and values.")]),
    ]));
    return;
  }
  const rows = matches.map((item) => el("tr", {}, [
    el("td", {}, [roleLabel(item.role)]),
    el("td", {}, [el("div", {}, [item.label ?? "—"]),
      ...(item.identifier ? [el("div", { class: "necto-caption" }, [item.identifier])] : [])]),
    el("td", {}, [item.isSecure ? t("Secure value is hidden") : item.value ?? "—"]),
  ]));
  listPane.append(el("table", { class: "necto-table control-reading", "aria-label": t("Read accessibility") }, [
    el("thead", {}, [el("tr", {}, ["Role", "Label", "Value"].map((name) => el("th", { scope: "col" }, [t(name)])))]),
    el("tbody", {}, rows),
  ]));
}

function renderDetail(): void {
  detailPane.unmount();
  detailSlot.replaceChildren();
  if (mode !== "actions") return;
  const element = elements.find((element) => element.id === selectedID);
  if (!element) return;
  const close = el("button", {
    type: "button", class: "necto-button necto-button-quiet", "aria-label": t("Close details"),
  }, ["✕"]);
  close.addEventListener("click", () => select(element.id));
  const aside = el("aside", { class: "necto-detail" }, [
    el("div", { class: "necto-detail-title" }, [
      el("span", { class: "necto-detail-title-url" }, [title(element)]), close,
    ]),
    el("div", { class: "necto-detail-body control-detail-body" }, [
      accessibilityControls(element),
    ]),
  ]);
  detailSlot.append(aside);
  detailPane.mount(aside);
}

function accessibilityControls(node: ActionTarget): HTMLElement {
  const section = el("section", { class: "control-accessibility-actions", "aria-label": t("Gestures") }, [
    el("h3", { class: "necto-section-title" }, [t("Gestures")]),
  ]);
  const buttons = el("div", { class: "control-action-buttons" });
  const defaultTap = node.tapGestures?.find(({ touchCount, tapCount }) => touchCount === 1 && tapCount === 1)
    ?? node.tapGestures?.[0];
  const settings = gestureSettings.get(node.id) ?? {
    touchCount: defaultTap?.touchCount ?? 1,
    tapCount: defaultTap?.tapCount ?? 1,
    distanceRatio: 0.6, durationMs: 400, customPosition: false, x: 0.5, y: 0.5,
  };
  gestureSettings.set(node.id, settings);
  const positionMode = el("select", { class: "necto-field" }, [
    el("option", { value: "default" }, [t("Default position")]),
    el("option", { value: "custom" }, [t("Custom position")]),
  ]);
  positionMode.value = settings.customPosition ? "custom" : "default";
  const x = el("input", { type: "number", class: "necto-field", min: "0", max: "1", step: "any", value: String(settings.x) });
  const y = el("input", { type: "number", class: "necto-field", min: "0", max: "1", step: "any", value: String(settings.y) });
  const coordinates = el("div", {}, [el("div", { class: "control-accessibility-actions" }, [
    el("label", { class: "control-accessibility-actions" }, [t("X (left to right)"), x]),
    el("label", { class: "control-accessibility-actions" }, [t("Y (top to bottom)"), y]),
    el("p", { class: "necto-caption" }, [t("Use 0–1 within the visible target. Swipe starts here and stops at its edge.")]),
  ])]);
  coordinates.hidden = !settings.customPosition;
  positionMode.addEventListener("change", () => {
    settings.customPosition = positionMode.value === "custom";
    coordinates.hidden = !settings.customPosition;
  });
  x.addEventListener("input", () => { if (x.value && x.validity.valid) settings.x = x.valueAsNumber; });
  y.addEventListener("input", () => { if (y.value && y.validity.valid) settings.y = y.valueAsNumber; });
  const validPosition = () => !settings.customPosition ||
    (x.reportValidity() && y.reportValidity() && !!x.value && !!y.value);
  const positionInput = (): NectoJSONObject => settings.customPosition ? { position: { x: settings.x, y: settings.y } } : {};
  if (node.actions.includes("tap") || node.actions.includes("swipe")) {
    section.append(el("label", { class: "control-accessibility-actions" }, [t("Position"), positionMode]), coordinates);
  }
  if (node.actions.includes("tap")) {
    const fingers = el("select", { class: "necto-field" });
    const taps = el("select", { class: "necto-field" });
    for (let value = 1; value <= 5; value++) fingers.append(el("option", { value: String(value) }, [String(value)]));
    for (let value = 1; value <= 3; value++) taps.append(el("option", { value: String(value) }, [String(value)]));
    fingers.value = String(settings.touchCount);
    taps.value = String(settings.tapCount);
    fingers.addEventListener("change", () => { settings.touchCount = Number(fingers.value); });
    taps.addEventListener("change", () => { settings.tapCount = Number(taps.value); });
    const tap = el("button", { type: "button", class: "necto-button" }, [t("Tap")]);
    tap.addEventListener("click", () => {
      if (!validPosition()) return;
      void runAction("control.tap", {
        targetID: node.id, touchCount: settings.touchCount, tapCount: settings.tapCount, ...positionInput(),
      });
    });
    section.append(
      el("label", { class: "control-accessibility-actions" }, [t("Fingers"), fingers]),
      el("label", { class: "control-accessibility-actions" }, [t("Tap count"), taps]),
    );
    buttons.append(tap);
  }
  if (node.actions.includes("back")) buttons.append(actionButton(t("Swipe back"), "control.back", { targetID: node.id }));
  section.append(buttons);
  if (node.actions.includes("input")) {
    const text = el("input", { type: node.isSecure ? "password" : "text", class: "necto-field",
      "aria-label": t("Text to enter"), placeholder: t("Text to enter"), maxlength: "10000", autocomplete: "off" });
    const mode = el("select", { class: "necto-field", "aria-label": t("Input mode") }, [
      el("option", { value: "replace" }, [t("Replace text")]), el("option", { value: "append" }, [t("Append text")]),
    ]);
    const submit = el("button", { type: "submit", class: "necto-button" }, [t("Enter text")]);
    const form = el("form", { class: "control-accessibility-actions" }, [text, mode, submit]);
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      if (acting || loading) return;
      const value = text.value;
      text.value = "";
      void runAction("control.input", { targetID: node.id, text: value, mode: mode.value });
    });
    section.append(form);
  }
  if (node.actions.includes("swipe")) {
    const distance = el("input", { type: "number", class: "necto-field", min: "0.1", max: "0.9", step: "0.1", value: String(settings.distanceRatio) });
    const duration = el("input", { type: "number", class: "necto-field", min: "100", max: "2000", step: "any", value: String(settings.durationMs) });
    distance.addEventListener("input", () => { if (distance.value && distance.validity.valid) settings.distanceRatio = distance.valueAsNumber; });
    duration.addEventListener("input", () => { if (duration.value && duration.validity.valid) settings.durationMs = duration.valueAsNumber; });
    const swipeButtons = el("div", { class: "control-action-buttons control-scroll-buttons" });
    for (const [direction, label] of [["up", "↑ Swipe up"], ["down", "↓ Swipe down"],
      ["left", "← Swipe left"], ["right", "→ Swipe right"]]) {
      const button = el("button", { type: "button", class: "necto-button" }, [t(label)]);
      button.addEventListener("click", () => {
        if (!validPosition() || !distance.reportValidity() || !duration.reportValidity() || !distance.value || !duration.value) return;
        void runAction("control.swipe", { targetID: node.id, direction,
          distanceRatio: distance.valueAsNumber, durationMs: duration.valueAsNumber, ...positionInput() });
      });
      swipeButtons.append(button);
    }
    section.append(el("p", { class: "necto-caption" }, [t("Arrows show finger movement. Swipe up to reveal content below.")]),
      el("label", { class: "control-accessibility-actions" }, [t("Distance ratio"), distance]),
      el("label", { class: "control-accessibility-actions" }, [t("Duration (ms)"), duration]), swipeButtons);
  }
  return section;
}

function select(id: string): void {
  if (acting || loading) return;
  selectedID = selectedID === id ? null : id;
  renderList();
  renderDetail();
}

function updateBusyState(): void {
  const busy = acting || loading;
  spinner.hidden = !busy;
  refresh.disabled = busy;
  actionTab.disabled = busy;
  readingTab.disabled = busy;
  listPane.setAttribute("aria-busy", String(busy));
  detailSlot.setAttribute("aria-busy", String(busy));
  for (const control of detailSlot.querySelectorAll<HTMLButtonElement | HTMLInputElement | HTMLSelectElement>("button, input, select")) {
    control.disabled = busy;
  }
  for (const row of listPane.querySelectorAll<HTMLButtonElement>(".necto-tree-row")) row.disabled = busy;
}

async function runAction(operation: string, input: NectoJSONObject): Promise<void> {
  if (acting || loading) return;
  acting = true;
  updateBusyState();
  renderList();
  statusText.textContent = t("Sending input…");
  try {
    const result = await necto.device.send<NectoJSONObject>(operation, input);
    const refreshed = await load();
    if (refreshed) statusText.textContent = t(result.contentChanged
      ? "Input sent · accessibility content changed" : "Input sent · no accessibility change observed");
  } catch (error) {
    await load();
    statusText.textContent = messageOf(error);
  } finally {
    acting = false;
    renderList();
    renderDetail();
    updateBusyState();
  }
}

function actionButton(label: string, operation: string, input: NectoJSONObject): HTMLButtonElement {
  const button = el("button", { type: "button", class: "necto-button" }, [label]);
  button.addEventListener("click", () => void runAction(operation, input));
  return button;
}

async function load(): Promise<boolean> {
  if (loading) return false;
  loading = true;
  statusText.textContent = t("Loading…");
  updateBusyState();
  let success = false;
  try {
    if (mode === "actions") {
      elements = (await necto.device.send<{ targets: ActionTarget[] }>("control.actionTargets")).targets;
      if (!elements.some((element) => element.id === selectedID)) selectedID = null;
      const ids = new Set(elements.map((element) => element.id));
      for (const id of gestureSettings.keys()) if (!ids.has(id)) gestureSettings.delete(id);
    } else {
      accessibilityItems = (await necto.device.send<{ items: AccessibilityItem[] }>("control.readAccessibility")).items;
    }
    message = null;
    statusText.textContent = "";
    success = true;
  } catch (error) {
    elements = [];
    accessibilityItems = [];
    selectedID = null;
    message = messageOf(error);
    statusText.textContent = message;
  } finally {
    loading = false;
    updateBusyState();
  }
  renderList();
  renderDetail();
  updateBusyState();
  return success;
}

refresh.addEventListener("click", () => { if (!acting) void load(); });
filter.addEventListener("input", () => { query = filter.value; renderList(); });
listPane.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && selectedID) select(selectedID);
  if (event.key === "ArrowDown" || event.key === "ArrowUp") {
    const rows = [...listPane.querySelectorAll<HTMLButtonElement>(".necto-tree-row")];
    const index = rows.indexOf(document.activeElement as HTMLButtonElement);
    const next = index + (event.key === "ArrowDown" ? 1 : -1);
    if (rows[next]) { event.preventDefault(); rows[next].focus(); }
  }
});

async function main(): Promise<void> {
  if (!necto.isAvailable()) {
    message = t("This plugin only works inside Necto");
    renderList();
    return;
  }
  await load();
  await necto.ready();
}
void main();
