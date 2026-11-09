//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { necto } from "@necto/bridge";
import type {
  NectoDiagnosticLevel,
  NectoEvent,
  NectoExporterOptions,
  NectoExporterShutdownContext,
  NectoJSONObject,
} from "@necto/bridge";

export interface HTTPExporterOptions {
  url: string;
  headers?: Record<string, string>;
  /** Waiting-event count that triggers a send of the whole queue. Defaults to 100. */
  maxEvents?: number;
  /** Maximum healthy queue wait, in milliseconds. Defaults to 60,000. */
  maxInterval?: number;
  /** Maximum waiting events, excluding the active request. Defaults to 10,000. */
  maxQueuedEvents?: number;
}

interface HTTPResponse {
  status: number;
  headers: Record<string, string>;
  bodyBase64: string;
}

const storageKey = "http-exporter.pending";

/** A reusable exporter; install its manifest bindings before registering it. */
export class HTTPExporter implements NectoExporterOptions {
  private readonly url: string;
  private readonly headers: Record<string, string>;
  private readonly maxEvents: number;
  private readonly maxInterval: number;
  private readonly maxQueuedEvents: number;
  private queue: NectoEvent[] = [];
  private active: NectoEvent[] = [];
  private firstQueuedAt = 0;
  private ready = false;
  private readonly initialization: Promise<void>;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private flight: Promise<void> | undefined;
  private checkpoint = false;
  private saveChain: Promise<void> = Promise.resolve();
  private saveScheduled = false;
  private failures = 0;
  private retryAt = 0;
  private overflowReported = false;
  private closing = false;

  constructor(options: HTTPExporterOptions) {
    let url: URL;
    try { url = new URL(options.url); }
    catch { throw new Error("HTTPExporter requires an absolute HTTPS URL."); }
    if (url.protocol !== "https:") throw new Error("HTTPExporter requires an HTTPS URL.");
    this.url = url.href;
    this.headers = { ...options.headers };
    if (!Object.keys(this.headers).some(key => key.toLowerCase() === "content-type")) {
      this.headers["Content-Type"] = "application/json";
    }
    this.maxEvents = positiveInteger(options.maxEvents ?? 100, "maxEvents");
    this.maxInterval = positiveInteger(options.maxInterval ?? 60_000, "maxInterval");
    this.maxQueuedEvents = positiveInteger(options.maxQueuedEvents ?? 10_000, "maxQueuedEvents");
    this.initialization = this.restore().catch(() => {
      this.report("failure", "HTTP exporter could not restore pending events.");
    }).then(() => {
      this.ready = true;
      this.schedule();
    });
  }

  onEvent = (event: NectoEvent): void => {
    if (this.closing) return;
    if (this.queue.length === 0) this.firstQueuedAt = Date.now();
    this.queue.push(event);
    const dropped = this.trimQueue();
    if (dropped && this.checkpoint) void this.persist();
    this.schedule();
  };

  onShutdown = (context: NectoExporterShutdownContext): Promise<void> => {
    this.closing = true;
    this.clearTimer();
    return this.shutdown(context.deadlineAt);
  };

  private async restore(): Promise<void> {
    const result = await necto.desktop.send<{ found: boolean; value?: unknown }>("exporter.storage.get", {
      key: storageKey, scope: "plugin",
    });
    this.checkpoint = result.found;
    if (!result.found) return;
    const value = result.value as { version?: unknown; events?: unknown } | null;
    if (!value || value.version !== 1 || !Array.isArray(value.events)
        || !value.events.every(event => event !== null && typeof event === "object" && typeof event.eventId === "string")) {
      this.report("warning", "HTTP exporter ignored an incompatible pending-event checkpoint.");
      return;
    }
    if (value.events.length === 0) return;
    this.queue = [...value.events as NectoEvent[], ...this.queue];
    this.firstQueuedAt = Date.now() - this.maxInterval;
    if (this.trimQueue()) await this.persist();
  }

  private trimQueue(): boolean {
    const excess = this.queue.length - this.maxQueuedEvents;
    if (excess <= 0) return false;
    this.queue.splice(0, excess);
    if (!this.overflowReported) {
      this.report("warning", "HTTP exporter queue is full; oldest waiting events were discarded.");
      this.overflowReported = true;
    }
    return true;
  }

  private clearTimer(): void {
    if (this.timer !== undefined) clearTimeout(this.timer);
    this.timer = undefined;
  }

  private schedule(): void {
    this.clearTimer();
    if (!this.ready || this.closing || this.flight || this.queue.length === 0) return;
    const now = Date.now();
    const due = this.failures > 0 ? this.retryAt
      : this.queue.length >= this.maxEvents ? now : this.firstQueuedAt + this.maxInterval;
    // Very long Retry-After values must not overflow the browser timer into an immediate retry.
    const delay = Math.min(Math.max(due - now, 0), 2_147_483_647);
    this.timer = setTimeout(() => {
      this.timer = undefined;
      if (Date.now() < due) { this.schedule(); return; }
      void this.flush();
    }, delay);
  }

  private flush(): Promise<void> {
    if (this.flight) return this.flight;
    this.clearTimer();
    this.flight = this.sendBatch().finally(() => {
      this.flight = undefined;
      this.schedule();
    });
    return this.flight;
  }

  private async sendBatch(): Promise<void> {
    if (this.queue.length === 0) return;
    const batchQueuedAt = this.firstQueuedAt;
    this.active = this.queue;
    this.queue = [];
    this.firstQueuedAt = 0;
    this.overflowReported = false;
    let retry = true;
    let serverRetryAt = 0;
    try {
      const response = await necto.desktop.send<HTTPResponse>("exporter.http.request", {
        url: this.url,
        method: "POST",
        headers: this.headers,
        bodyBase64: encodeBody(this.active),
      });
      if (response.status >= 200 && response.status < 300) {
        retry = false;
      } else if (response.status >= 400 && response.status < 500 && response.status !== 408 && response.status !== 429) {
        retry = false;
        this.report("warning", "HTTP exporter discarded a batch after a non-retryable response.", {
          status: response.status, count: this.active.length,
        });
      } else {
        const header = Object.entries(response.headers).find(([key]) => key.toLowerCase() === "retry-after")?.[1];
        serverRetryAt = retryAfter(header);
        this.report("warning", "HTTP exporter will retry a failed batch.", { status: response.status });
      }
    } catch {
      this.report("warning", "HTTP exporter will retry a failed request.");
    }

    if (retry) {
      this.firstQueuedAt = this.queue.length > 0 ? Math.min(batchQueuedAt, this.firstQueuedAt) : batchQueuedAt;
      this.queue = [...this.active, ...this.queue];
      this.trimQueue();
      const delay = Math.min(5_000 * 2 ** Math.min(this.failures, 4), 60_000);
      this.failures += 1;
      this.retryAt = Math.max(Date.now() + delay, serverRetryAt);
    } else {
      this.failures = 0;
      this.retryAt = 0;
    }
    this.active = [];
    if (retry || this.checkpoint || this.closing) await this.persist();
  }

  private persist(): Promise<void> {
    if (this.saveScheduled) return this.saveChain;
    this.saveScheduled = true;
    this.saveChain = this.saveChain.then(async () => {
      this.saveScheduled = false;
      // Snapshot when this write starts, not when it was queued behind another write.
      // Calls before then share this write; calls during it queue at most one successor.
      const events = [...this.active, ...this.queue];
      if (events.length > 0) {
        this.checkpoint = true;
        await necto.desktop.send("exporter.storage.set", {
          key: storageKey, scope: "plugin",
          value: { version: 1, events: events as unknown as NectoJSONObject[] },
        });
      } else if (this.checkpoint) {
        await necto.desktop.send("exporter.storage.remove", { key: storageKey, scope: "plugin" });
        this.checkpoint = false;
      }
    }).catch(() => {
      this.report("failure", "HTTP exporter could not save pending events.");
    });
    return this.saveChain;
  }

  private async shutdown(deadlineAt: number): Promise<void> {
    await this.initialization;
    // Include any active request before waiting for the network: the host may close
    // this document at its deadline without another chance to write the queue.
    await this.persist();
    if (this.flight) await this.flight;
    while (Date.now() < deadlineAt && this.queue.length > 0 && Date.now() >= this.retryAt) {
      await this.flush();
    }
    await this.persist();
  }

  private report(level: NectoDiagnosticLevel, message: string, metadata?: NectoJSONObject): void {
    void necto.diagnostics.log(level, message, metadata).catch(() => {});
  }
}

function positiveInteger(value: number, name: string): number {
  if (!Number.isSafeInteger(value) || value <= 0) throw new Error(`${name} must be a positive safe integer.`);
  return value;
}

function encodeBody(events: NectoEvent[]): string {
  const bytes = new TextEncoder().encode(JSON.stringify({ events }));
  // Avoid spreading a large body into a function's argument list.
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function retryAfter(value: string | undefined): number {
  if (!value) return 0;
  const trimmed = value.trim();
  const at = /^\d+$/.test(trimmed) ? Date.now() + Number(trimmed) * 1000 : Date.parse(trimmed);
  return Number.isFinite(at) ? Math.max(at, 0) : 0;
}
