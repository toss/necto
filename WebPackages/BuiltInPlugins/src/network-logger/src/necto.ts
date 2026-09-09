//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import {
  necto,
  hasErrorCode,
  isNectoBridgeError,
  type NectoSubscription,
} from "@necto/bridge";

export interface Body {
  byteCount: number;
  isTruncated: boolean;
  contentType?: string;
  text?: string;
}

/// What a row needs. The list operation deliberately carries no bodies.
export interface RecordSummary {
  id: string;
  method: string;
  url: string;
  name: string;
  host: string;
  state: "pending" | "completed" | "failed";
  startedAtMilliseconds: number;
  statusCode?: number;
  durationMilliseconds?: number;
  responseByteCount?: number;
  errorSummary?: string;
}

/// The summary plus what the detail pane shows. Fetched one record at a time.
export interface RecordDetail extends RecordSummary {
  requestHeaders?: Record<string, string>;
  responseHeaders?: Record<string, string>;
  requestBody?: Body;
  responseBody?: Body;
  curl?: string;
}

function describe(error: unknown): string {
  return isNectoBridgeError(error) ? error.message : String(error);
}

export async function observeRecords({
  onRecord,
  onError,
}: {
  onRecord: (record: RecordSummary) => void;
  onError: (message: string) => void;
}): Promise<void> {
  if (!necto.isAvailable()) {
    onError("This plugin only works inside Necto.");
    return;
  }

  const plugin = await necto.context();
  if (!plugin.target) {
    onError("Select a connected app to see its requests.");
  }

  try {
    await necto.device.subscribe<{ record: RecordSummary }>(
      "records.observe",
      {},
      (event) => onRecord(event.record),
      (error) => onError(error.message),
    );

    const page = await necto.device.send<{ records: RecordSummary[] }>("records.list", { limit: 500 });
    for (const record of page.records) onRecord(record);
  } catch (error) {
    onError(
      hasErrorCode(error, "TARGET_DISCONNECTED")
        ? "Select a connected app to see its requests."
        : describe(error),
    );
  }

  // Handlers are registered, so the host may flush anything it buffered.
  await necto.ready();
}

export async function loadDetail(recordID: string): Promise<RecordDetail> {
  const result = await necto.device.send<{ record: RecordDetail }>("records.detail", { recordID });
  return result.record;
}

export async function clearRecords(): Promise<void> {
  await necto.device.send("records.clear");
}
