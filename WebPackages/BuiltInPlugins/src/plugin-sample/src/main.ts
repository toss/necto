//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import {
  necto,
  isNectoBridgeError,
  type NectoSubscription,
} from "@necto/bridge";
import { t } from "./localization";

for (const element of document.querySelectorAll<HTMLElement>("[data-i18n]")) {
  element.textContent = t(element.dataset.i18n ?? "");
}

interface HostInfo {
  nectoVersion: string;
  protocolVersion: number;
}

interface Tick {
  sequence: number;
  timestamp: number;
}

interface ShellApprovalResult {
  approved: boolean;
  approvedCommands: string[];
}

interface ShellExecutionResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

const shellCommand = "/usr/bin/printf 'Hello from Plugin Sample\\n'";
const unapprovedShellCommand = "/usr/bin/printf 'This command was not approved\\n'";

// -- rendering ---------------------------------------------------------------

function pairs(id: string, rows: [string, string | number][]): void {
  const element = document.getElementById(id);
  if (!element) return;
  element.replaceChildren(...rows.map(([key, value]) => {
    const row = document.createElement("div");
    const term = document.createElement("dt");
    const detail = document.createElement("dd");
    term.textContent = key;
    detail.textContent = String(value);
    row.append(term, detail);
    return row;
  }));
}

/// Fixed rather than localised, for the same reason the network log is: a locale
/// renders this as "오후 9:09:27", which is wider and read as prose rather than by
/// position.
function formatTime(milliseconds: number): string {
  const date = new Date(milliseconds);
  const pad = (value: number) => String(value).padStart(2, "0");
  return `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

function status(id: string, tone: "ok" | "danger", label: string): void {
  const element = document.getElementById(id);
  if (!element) return;
  const badge = document.createElement("span");
  badge.className = `necto-status necto-status-${tone}`;
  badge.textContent = label;
  element.replaceChildren(badge);
}

/// A refusal names its code, because that is what a plugin branches on. The sentence
/// under it is what the person reading the screen needs.
function notice(code: string, message: string): void {
  const list = document.getElementById("failures");
  if (!list) return;

  const item = document.createElement("div");
  item.className = "necto-notice necto-notice-danger";
  const content = document.createElement("div");
  const title = document.createElement("span");
  title.className = "necto-notice-title";
  title.textContent = code;
  const description = document.createElement("p");
  description.textContent = message;
  content.append(title, description);
  item.append(content);
  list.prepend(item);

  // Only the last few, or the panel becomes a log nobody reads.
  while (list.children.length > 4) list.lastElementChild?.remove();
}

// -- tabs --------------------------------------------------------------------

for (const tab of document.querySelectorAll<HTMLButtonElement>("[data-tab]")) {
  tab.addEventListener("click", () => {
    for (const other of document.querySelectorAll<HTMLButtonElement>("[data-tab]")) {
      other.setAttribute("aria-selected", String(other === tab));
    }
    for (const panel of document.querySelectorAll<HTMLElement>("[data-panel]")) {
      panel.hidden = panel.dataset.panel !== tab.dataset.tab;
    }
  });
}

// -- bridge ------------------------------------------------------------------

async function runInfo(): Promise<void> {
  const started = performance.now();
  try {
    const info = await necto.desktop.send<HostInfo & Record<string, never>>("host.info");
    status("info-status", "ok", `${Math.round(performance.now() - started)} ms`);
    pairs("info", [
      ["nectoVersion", info.nectoVersion],
      ["protocolVersion", info.protocolVersion],
    ]);
  } catch (error) {
    status("info-status", "danger", t("failed"));
    pairs("info", [[codeOf(error), messageOf(error)]]);
  }
}

let ticks = 0;
let subscription: NectoSubscription | undefined;

async function startTicks(): Promise<void> {
  if (subscription) return;
  ticks = 0;

  try {
    subscription = await necto.desktop.subscribe<Tick & Record<string, never>>(
      "host.ticks",
      { intervalMs: 1000 },
      (tick) => {
        ticks += 1;
        const count = document.getElementById("tick-count");
        if (count) count.textContent = t(ticks === 1 ? "{count} event" : "{count} events", { count: ticks });
        pairs("ticks", [
          ["sequence", tick.sequence],
          ["timestamp", formatTime(tick.timestamp)],
        ]);
      },
      (error) => notice(codeOf(error), messageOf(error)),
    );
  } catch (error) {
    notice(codeOf(error), messageOf(error));
  }
}

async function stopTicks(): Promise<void> {
  await subscription?.unsubscribe();
  subscription = undefined;
}

// -- shell ------------------------------------------------------------------

async function requestShellApproval(fullAccess = false): Promise<void> {
  try {
    const result = await necto.desktop.send<ShellApprovalResult>("shell.request", fullAccess
      ? {
        access: "fullAccess",
        title: t("Allow every Plugin Sample command?"),
        message: t("Full Access lets Plugin Sample run any shell command without asking again."),
      }
      : {
        commands: [commandField()?.value ?? shellCommand],
        title: t("Allow the Plugin Sample greeting?"),
        message: t("The sample uses printf to verify shell execution and stdout."),
      });
    pairs("shell-result", [
      ["approved", String(result.approved)],
      ["commands", fullAccess ? t("All commands") : result.approvedCommands.join("\n") || "—"],
    ]);
  } catch (error) {
    pairs("shell-result", [[codeOf(error), messageOf(error)]]);
  }
}

async function runShell(command: string): Promise<void> {
  try {
    const result = await necto.desktop.send<ShellExecutionResult>("shell.execute", { command });
    pairs("shell-result", [
      ["stdout", result.stdout || "—"],
      ["stderr", result.stderr || "—"],
      ["exitCode", result.exitCode],
    ]);
  } catch (error) {
    pairs("shell-result", [[codeOf(error), messageOf(error)]]);
  }
}

function commandField(): HTMLInputElement | null {
  return document.getElementById("shell-command") as HTMLInputElement | null;
}

// -- deliberate failures -----------------------------------------------------

/// Each button asks for something Necto will refuse, so an author can see the shape of
/// the refusal rather than read about it.
const failures: Record<string, () => Promise<unknown>> = {
  // Not in this plugin's manifest, so it is turned down before reaching a provider.
  missing: () => necto.desktop.send("nothing.declared.this"),
  // `intervalMs` is an integer with a minimum, and a string is neither.
  input: () => necto.desktop.send("host.ticks", { intervalMs: "fast" }),
};

for (const button of document.querySelectorAll<HTMLButtonElement>("[data-fail]")) {
  button.addEventListener("click", () => {
    const run = failures[button.dataset.fail ?? ""];
    if (!run) return;

    void run()
      .then(() => notice("no error", t("Necto allowed it. That is itself worth knowing.")))
      .catch((error: unknown) => notice(codeOf(error), messageOf(error)));
  });
}

// -- errors ------------------------------------------------------------------

function codeOf(error: unknown): string {
  return isNectoBridgeError(error) ? error.code : "UNKNOWN";
}

function messageOf(error: unknown): string {
  return isNectoBridgeError(error) ? error.message : String(error);
}

// -- start -------------------------------------------------------------------

async function main(): Promise<void> {
  const field = commandField();
  if (field) field.value = shellCommand;

  if (!necto.isAvailable()) {
    pairs("context", [[t("Notice"), t("This plugin only works inside Necto")]]);
    return;
  }

  document.getElementById("run-info")?.addEventListener("click", () => void runInfo());
  document.getElementById("start-ticks")?.addEventListener("click", () => void startTicks());
  document.getElementById("stop-ticks")?.addEventListener("click", () => void stopTicks());
  document.getElementById("request-shell-access")?.addEventListener("click", () => void requestShellApproval());
  document.getElementById("request-shell-full-access")?.addEventListener("click", () => void requestShellApproval(true));
  document.getElementById("run-shell-command")?.addEventListener("click", () => {
    void runShell(commandField()?.value ?? shellCommand);
  });
  document.getElementById("run-unapproved-shell-command")?.addEventListener("click", () => {
    void runShell(unapprovedShellCommand);
  });

  try {
    const pluginContext = await necto.context();
    pairs("context", [
      ["pluginID", pluginContext.pluginID],
      ["protocolVersion", pluginContext.protocolVersion],
      ["target", pluginContext.target?.appBundleID ?? t("none selected")],
      ["operations", pluginContext.operations.map((operation) => operation.id).join(", ")],
    ]);
  } catch (error) {
    pairs("context", [[codeOf(error), messageOf(error)]]);
  }

  await runInfo();

  // Signal only after every handler is registered; the host buffers events until then.
  await necto.ready();
}

void main();
