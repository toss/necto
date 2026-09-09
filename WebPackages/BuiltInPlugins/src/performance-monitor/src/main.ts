//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import "./style.css";

import { necto, isNectoBridgeError } from "@necto/bridge";
import { t } from "./localization";

if (import.meta.env.DEV) {
  const { installMockBridge } = await import("./mock");
  installMockBridge();
}

interface Metric {
  id: string;
  title: string;
  unit: string;
  budget?: number;
  /// Which side of the budget is the wrong side. A frame budget is a ceiling; a frame
  /// rate is a floor, and 41 fps under a 55 fps floor is the same kind of bad news.
  budgetKind?: "atMost" | "atLeast";
}

interface Sample {
  at: number;
  value: number;
}

interface Series {
  metricID: string;
  samples: Sample[];
  latest: number | null;
  isOverBudget: boolean;
}

// -- state -------------------------------------------------------------------

let metrics: Metric[] = [];
const series = new Map<string, Sample[]>();
const overBudget = new Set<string>();
/// How far back the cards look, in seconds. Changing it re-reads rather than
/// re-requests: the app already sent everything, and the window is a way of reading it.
let windowSeconds = 300;
let message: string | null = null;
let processNote = t("Live while this panel is open");

const graphColors = [
  "var(--necto-info)",
  "var(--necto-brand)",
  "var(--necto-success)",
  "var(--necto-warning)",
  "color-mix(in srgb, var(--necto-info) 55%, var(--necto-success))",
  "color-mix(in srgb, var(--necto-brand) 55%, var(--necto-info))",
];

const body = document.getElementById("body")!;
const processControls = document.getElementById("process-controls")!;

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

function within(metricID: string): Sample[] {
  const since = Date.now() - windowSeconds * 1000;
  return (series.get(metricID) ?? []).filter((sample) => sample.at >= since);
}

/// Trimmed to what a card can show. A number with more digits than the column is a
/// number nobody reads.
function formatValue(value: number): string {
  if (Math.abs(value) >= 100) return String(Math.round(value));
  if (Math.abs(value) >= 10) return value.toFixed(1);
  return value.toFixed(2);
}

/// Says which way it went and by how much, because a single reading says neither.
function formatTrend(samples: Sample[], unit: string): string {
  if (samples.length < 2) return t("not enough readings yet");

  const change = samples[samples.length - 1]!.value - samples[0]!.value;
  const minutes = Math.round(windowSeconds / 60);
  if (Math.abs(change) < 0.05) return t("steady");

  return t("{direction} {value} {unit} in {minutes} m", {
    direction: change > 0 ? "▲" : "▼",
    value: formatValue(Math.abs(change)),
    unit,
    minutes,
  });
}

/// Shape only, and deliberately: the line says which way, the number beside it says
/// how far. Scaled to its own range so a flat series does not look like noise.
function spark(samples: Sample[], isOver: boolean, color: string): SVGElement {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("class", "necto-spark");
  svg.setAttribute("viewBox", "0 0 100 26");
  svg.setAttribute("preserveAspectRatio", "none");
  svg.setAttribute("aria-hidden", "true");
  if (samples.length < 2) return svg;

  const values = samples.map((sample) => sample.value);
  const low = Math.min(...values);
  const high = Math.max(...values);
  const span = high - low || 1;

  const points = samples
    .map((sample, index) => {
      const x = (index / (samples.length - 1)) * 100;
      const y = 24 - ((sample.value - low) / span) * 22;
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    })
    .join(" ");

  const line = document.createElementNS("http://www.w3.org/2000/svg", "polyline");
  line.setAttribute("points", points);
  line.setAttribute("fill", "none");
  line.setAttribute("stroke", isOver ? "var(--necto-danger)" : color);
  line.setAttribute("stroke-width", "1.5");
  line.setAttribute("vector-effect", "non-scaling-stroke");
  svg.append(line);
  return svg;
}

// -- rendering ---------------------------------------------------------------

function render(): void {
  renderProcessControls();
  body.replaceChildren();

  if (!metrics.length) {
    body.append(
      el("div", { class: "necto-empty" }, [
        el("p", { class: "necto-empty-title" }, [message ?? t("Nothing measured yet")]),
        el("p", { class: "necto-caption" }, [
          t("The connected app decides which metrics and sampler to provide."),
        ]),
      ]),
    );
    return;
  }

  body.append(
    el(
      "div",
      { class: "necto-metrics" },
      metrics.map((metric, index) => {
        const samples = within(metric.id);
        const latest = samples[samples.length - 1]?.value;
        const isOver = overBudget.has(metric.id);

        return el("div", { class: "necto-metric", "data-over": isOver ? "true" : undefined }, [
          el("div", { class: "necto-metric-title" }, [t(metric.title)]),
          el("div", { class: "necto-metric-value" }, [
            latest === undefined ? "—" : formatValue(latest),
            el("span", { class: "necto-metric-unit" }, [` ${metric.unit}`]),
          ]),
          el("div", { class: "necto-metric-note" }, [
            isOver && metric.budget !== undefined
              ? metric.budgetKind === "atLeast"
                ? t("▼ under {budget} {unit}", { budget: formatValue(metric.budget), unit: metric.unit })
                : t("▲ over {budget} {unit}", { budget: formatValue(metric.budget), unit: metric.unit })
              : formatTrend(samples, metric.unit),
          ]),
          spark(samples, isOver, graphColors[index % graphColors.length]!),
        ]);
      }),
    ),
  );
}

function renderProcessControls(): void {
  processControls.replaceChildren();
  const supportsProcessMetrics = metrics.some((metric) => metric.id === "cpu") &&
    metrics.some((metric) => metric.id === "memory") &&
    metrics.some((metric) => metric.id === "fps");
  if (!supportsProcessMetrics) return;

  const memory = el("button", { type: "button", class: "necto-button necto-button-quiet" }, [t("Memory")]);
  memory.addEventListener("click", () => void readMemory());
  processControls.append(el("span", { class: "necto-caption" }, [processNote]), memory);
}

// -- start -------------------------------------------------------------------

function messageOf(error: unknown): string {
  return isNectoBridgeError(error) ? error.message : String(error);
}

async function readMemory(): Promise<void> {
  try {
    const output = await necto.device.send<{
      memory: { available: boolean; physicalFootprintMB?: number; residentSizeMB?: number };
    }>("performance.memory");
    processNote = output.memory.available
      ? t("{footprint} MB footprint · {resident} MB resident", {
          footprint: formatValue(output.memory.physicalFootprintMB ?? 0),
          resident: formatValue(output.memory.residentSizeMB ?? 0),
        })
      : t("Memory detail unavailable");
  } catch (error) {
    processNote = messageOf(error);
  }
  renderProcessControls();
}

for (const tab of document.querySelectorAll<HTMLButtonElement>("[data-window]")) {
  tab.textContent = t(tab.textContent?.trim() ?? "");
  tab.addEventListener("click", () => {
    windowSeconds = Number(tab.dataset.window ?? 300);
    for (const other of document.querySelectorAll<HTMLButtonElement>("[data-window]")) {
      other.setAttribute("aria-selected", String(other === tab));
    }
    render();
  });
}

async function main(): Promise<void> {
  if (!necto.isAvailable()) {
    message = t("This plugin only works inside Necto");
    render();
    return;
  }

  render();

  try {
    metrics = (await necto.device.send<{ metrics: Metric[] }>("performance.metrics")).metrics;

    if (metrics.some((metric) => metric.id === "cpu")) {
      await necto.device.send("performance.snapshot");
    }

    const loaded = await necto.device.send<{ series: Series[] }>("performance.series", { limit: 600 });
    for (const one of loaded.series) {
      series.set(one.metricID, one.samples);
      if (one.isOverBudget) overBudget.add(one.metricID);
    }
    render();

    await necto.device.subscribe<{ metricID: string; sample: Sample; isOverBudget: boolean }>(
      "performance.observe",
      {},
      ({ metricID, sample, isOverBudget }) => {
        series.set(metricID, [...(series.get(metricID) ?? []), sample]);
        if (isOverBudget) overBudget.add(metricID);
        else overBudget.delete(metricID);
        render();
      },
      (error) => {
        message = error.message;
        render();
      },
    );
  } catch (error) {
    message = messageOf(error);
    render();
  }

  await necto.ready();
}

void main();
