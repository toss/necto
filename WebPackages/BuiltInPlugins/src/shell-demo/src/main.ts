//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { isNectoBridgeError, necto } from "@necto/bridge";
import { t } from "./localization";
import { defaultCommand, executionRows, unapprovedCommand, type ShellExecutionResult } from "./model";

for (const element of document.querySelectorAll<HTMLElement>("[data-i18n]")) {
  element.textContent = t(element.dataset.i18n ?? "");
}

interface ApprovalResult {
  approved: boolean;
  approvedCommands: string[];
}

function commandField(): HTMLInputElement | null {
  return document.getElementById("shell-command") as HTMLInputElement | null;
}

function renderRows(rows: [string, string | number][]): void {
  const root = document.getElementById("result");
  if (!root) return;
  root.replaceChildren(...rows.map(([key, value]) => {
    const row = document.createElement("div");
    const term = document.createElement("dt");
    const detail = document.createElement("dd");
    term.textContent = key;
    detail.textContent = String(value);
    row.append(term, detail);
    return row;
  }));
}

function renderFailure(error: unknown): void {
  const root = document.getElementById("failure");
  if (!root) return;
  const code = isNectoBridgeError(error) ? error.code : "UNKNOWN";
  const message = isNectoBridgeError(error) ? error.message : String(error);
  root.replaceChildren();

  const notice = document.createElement("div");
  notice.className = "necto-notice necto-notice-danger";
  const body = document.createElement("div");
  const title = document.createElement("span");
  const copy = document.createElement("p");
  title.className = "necto-notice-title";
  title.textContent = code;
  copy.textContent = message;
  body.append(title, copy);
  notice.append(body);
  root.append(notice);
}

function clearFailure(): void {
  document.getElementById("failure")?.replaceChildren();
}

async function requestApproval(): Promise<void> {
  const command = commandField()?.value ?? defaultCommand;
  clearFailure();
  try {
    const result = await necto.desktop.send<ApprovalResult>("shell.request", {
      commands: [command],
      title: t("Allow the Shell Demo greeting?"),
      message: t("The demo uses printf to prove an approved command reaches Bash and returns stdout."),
    });
    renderRows([
      ["approved", String(result.approved)],
      ["commands", result.approvedCommands.join("\n") || "—"],
    ]);
  } catch (error) {
    renderFailure(error);
  }
}

async function requestFullAccess(): Promise<void> {
  clearFailure();
  try {
    const result = await necto.desktop.send<ApprovalResult>("shell.request", {
      access: "fullAccess",
      title: t("Allow every Shell Demo command?"),
      message: t("Full Access lets this plugin run any shell command without asking again. Use it only to verify the broad permission flow."),
    });
    renderRows([
      ["fullAccess", String(result.approved)],
      ["commands", t("All commands")],
    ]);
  } catch (error) {
    renderFailure(error);
  }
}

async function run(command: string): Promise<void> {
  clearFailure();
  try {
    const result = await necto.desktop.send<ShellExecutionResult>("shell.execute", { command });
    renderRows(executionRows(result));
  } catch (error) {
    renderFailure(error);
  }
}

async function main(): Promise<void> {
  const field = commandField();
  if (field) field.value = defaultCommand;

  if (!necto.isAvailable()) {
    renderRows([[t("Notice"), t("This plugin only works inside Necto")]]);
    return;
  }

  const bridgeStatus = document.getElementById("bridge-status");
  if (bridgeStatus) {
    bridgeStatus.className = "necto-status necto-status-ok";
    bridgeStatus.textContent = t("Connected");
  }

  document.getElementById("request-access")?.addEventListener("click", () => void requestApproval());
  document.getElementById("request-full-access")?.addEventListener("click", () => void requestFullAccess());
  document.getElementById("run-command")?.addEventListener("click", () => {
    void run(commandField()?.value ?? defaultCommand);
  });
  document.getElementById("run-unapproved")?.addEventListener("click", () => void run(unapprovedCommand));

  await necto.ready();
}

void main();
