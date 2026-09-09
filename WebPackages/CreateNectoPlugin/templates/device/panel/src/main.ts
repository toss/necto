//
// Copyright (c) 2026 Viva Republica, Inc.
//

import { isNectoBridgeError, necto } from "@necto/bridge";
import { t } from "./localization";

interface Message {
  message: string;
}

for (const element of document.querySelectorAll<HTMLElement>("[data-i18n]")) {
  element.textContent = t(element.dataset.i18n ?? "");
}

document.getElementById("refresh")?.addEventListener("click", () => void refresh());

async function refresh(): Promise<void> {
  const message = document.getElementById("message");
  if (!message) return;

  try {
    const result = await necto.device.send<Message & Record<string, never>>("message.get");
    message.textContent = result.message;
  } catch (error) {
    message.textContent = isNectoBridgeError(error) ? `${error.code}: ${error.message}` : String(error);
  }
}

async function main(): Promise<void> {
  if (!necto.isAvailable()) return;
  await refresh();
  await necto.ready();
}

void main();
