//
// Copyright (c) 2026 Viva Republica, Inc.
//

import { isNectoBridgeError, necto } from "@necto/bridge";
import { t } from "./localization";

interface HostInfo {
  nectoVersion: string;
  protocolVersion: number;
}

for (const element of document.querySelectorAll<HTMLElement>("[data-i18n]")) {
  element.textContent = t(element.dataset.i18n ?? "");
}

document.getElementById("refresh")?.addEventListener("click", () => void refresh());

async function refresh(): Promise<void> {
  const result = document.getElementById("result");
  if (!result) return;

  try {
    const info = await necto.desktop.send<HostInfo & Record<string, never>>("host.info");
    result.innerHTML = `
      <div><dt>${t("Necto version")}</dt><dd>${info.nectoVersion}</dd></div>
      <div><dt>${t("Protocol version")}</dt><dd>${info.protocolVersion}</dd></div>
    `;
  } catch (error) {
    const message = isNectoBridgeError(error) ? `${error.code}: ${error.message}` : String(error);
    result.innerHTML = `<div><dt>${t("Unavailable")}</dt><dd>${message}</dd></div>`;
  }
}

async function main(): Promise<void> {
  if (!necto.isAvailable()) return;
  await refresh();
  await necto.ready();
}

void main();
