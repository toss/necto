//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { callHost, NectoBridgeUnavailableError } from "./transport";
import type { NectoDiagnosticLevel, NectoExporterOptions, NectoJSONObject } from "./types";

/** Local host diagnostics, separate from events delivered to an exporter. */
export const diagnostics = {
  async log(
    level: NectoDiagnosticLevel,
    message: string,
    metadata?: NectoJSONObject,
  ): Promise<void> {
    await callHost<null>("diagnostic", {
      level,
      message,
      ...(metadata === undefined ? {} : { metadata }),
    });
  },
};

/**
 * Registers this page as the approved desktop event exporter.
 *
 * Events may arrive before this promise resolves. The callbacks are installed first.
 * The host unregisters the exporter when the page ends or the plugin is removed.
 */
export async function registerExporter(options: NectoExporterOptions): Promise<void> {
  const page = globalThis.window;
  if (!page) throw new NectoBridgeUnavailableError();
  if (page.__nectoExporterReceive || page.__nectoExporterShutdown) {
    throw new Error("An exporter is already registered in this page.");
  }

  let shutdownPromise: Promise<void> | undefined;
  const reportFailure = () => {
    // A failed diagnostic must not create another event or an unhandled rejection.
    void diagnostics.log("failure", "Event exporter callback failed.").catch(() => {});
  };
  const receive: NonNullable<Window["__nectoExporterReceive"]> = (event) => {
    if (shutdownPromise) return;
    try {
      void Promise.resolve(options.onEvent(event)).catch(reportFailure);
    } catch {
      reportFailure();
    }
  };
  const shutdown: NonNullable<Window["__nectoExporterShutdown"]> = (context) => {
    shutdownPromise ??= Promise.resolve().then(() => options.onShutdown?.(context));
    return shutdownPromise;
  };
  page.__nectoExporterReceive = receive;
  page.__nectoExporterShutdown = shutdown;

  try {
    await callHost<null>("registerExporter");
  } catch (error) {
    if (page.__nectoExporterReceive === receive) delete page.__nectoExporterReceive;
    if (page.__nectoExporterShutdown === shutdown) delete page.__nectoExporterShutdown;
    throw error;
  }
}
