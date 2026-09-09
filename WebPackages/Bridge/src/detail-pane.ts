//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { createTranslator } from "./localization";

type Position = "right" | "bottom";
type Preferences = { width?: number; height?: number };

const t = createTranslator({ ko: {
  "Resize details": "상세 패널 크기 조절",
} });

export function parseDetailPreferences(value: string | null): Preferences {
  try {
    const parsed = JSON.parse(value ?? "null");
    const size = (value: unknown) => typeof value === "number" && Number.isFinite(value) && value > 0 ? value : undefined;
    return { width: size(parsed?.width), height: size(parsed?.height) };
  } catch {
    return {};
  }
}

/** One controller per plugin view. Mount again when the selected detail changes. */
export function createDetailPane(storageKey: string) {
  let preferences: Preferences;
  try { preferences = parseDetailPreferences(localStorage.getItem(storageKey)); }
  catch { preferences = {}; }
  let cleanup = () => {};

  return {
    mount(pane: HTMLElement) {
      cleanup();
      const layout = pane.closest<HTMLElement>(".necto-app");
      const title = pane.querySelector<HTMLElement>(".necto-detail-title");
      if (!layout || !title) return;
      layout.classList.add("necto-dock-layout");
      const handle = document.createElement("div");
      handle.className = "necto-resize";
      handle.tabIndex = 0;
      handle.setAttribute("role", "separator");
      handle.setAttribute("aria-label", t("Resize details"));
      pane.prepend(handle);
      let position: Position = "right";
      let current = 0;
      let minimum = 0;
      let maximum = 0;
      const save = () => {
        try { localStorage.setItem(storageKey, JSON.stringify(preferences)); }
        catch { /* Storage can be unavailable in an embedded preview. */ }
      };
      const update = () => {
        const { width, height } = layout.getBoundingClientRect();
        position = width <= 640 ? "bottom" : "right";
        minimum = position === "right" ? 280 : Math.min(180, height / 2);
        maximum = Math.max(minimum, position === "right" ? width - 240 : height - 160);
        current = Math.max(minimum, Math.min(maximum, position === "right" ? preferences.width ?? width * 0.45 : preferences.height ?? 280));
        layout.dataset.detailPosition = position;
        layout.style.setProperty("--necto-detail-size", `${current}px`);
        handle.setAttribute("aria-orientation", position === "right" ? "vertical" : "horizontal");
        handle.setAttribute("aria-valuemin", String(minimum));
        handle.setAttribute("aria-valuemax", String(maximum));
        handle.setAttribute("aria-valuenow", String(Math.round(current)));
      };
      const resize = (size: number) => {
        preferences[position === "right" ? "width" : "height"] = Math.max(minimum, Math.min(maximum, size));
        update();
      };
      handle.addEventListener("keydown", (event) => {
        const keys = position === "right" ? ["ArrowLeft", "ArrowRight"] : ["ArrowUp", "ArrowDown"];
        if (!keys.includes(event.key)) return;
        event.preventDefault();
        resize(current + (event.key === keys[0] ? 24 : -24));
        save();
      });
      let drag: { coordinate: number; size: number } | undefined;
      handle.addEventListener("pointerdown", (event) => {
        if (event.button !== 0) return;
        event.preventDefault();
        handle.setPointerCapture(event.pointerId);
        drag = { coordinate: position === "right" ? event.clientX : event.clientY, size: current };
        handle.dataset.dragging = "true";
      });
      handle.addEventListener("pointermove", (event) => {
        if (drag) resize(drag.size + drag.coordinate - (position === "right" ? event.clientX : event.clientY));
      });
      const end = () => { drag = undefined; delete handle.dataset.dragging; save(); };
      handle.addEventListener("pointerup", end);
      handle.addEventListener("lostpointercapture", end);
      const observer = new ResizeObserver(update);
      observer.observe(layout);
      update();
      cleanup = () => observer.disconnect();
    },
    unmount() { cleanup(); },
  };
}
