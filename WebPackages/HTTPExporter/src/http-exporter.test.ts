//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { necto, type NectoEvent } from "@necto/bridge";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { HTTPExporter } from "./index";

const url = "https://collector.example.com/events";
const authorization = "Bearer fixture-token";
const privatePayload = "fixture-private-payload";
const startedAt = new Date("2026-01-01T00:00:00Z");
const pendingKey = { scope: "plugin", key: "http-exporter.pending" };

type HostMessage =
  | { type: "registerExporter" | "diagnostic" }
  | { type: "invoke"; operationID: string; input: Record<string, unknown> };

type HostReply =
  | { ok: true; value: unknown }
  | { ok: false; error: { code: "PROVIDER_FAILED"; message: string } };

const success = (value: unknown): HostReply => ({ ok: true, value });
const httpReply = (status: number, headers: Record<string, string> = {}): HostReply =>
  success({ status, headers, bodyBase64: "" });
const checkpoint = (...events: NectoEvent[]) => ({ version: 1, events });

function event(id: number): NectoEvent {
  return {
    eventId: `event-${id}`,
    occurredAt: startedAt.getTime() + id,
    installationId: "installation-1",
    nectoVersion: "0.1.0",
    origin: "desktop",
    pluginId: "com.example.notes",
    pluginVersion: "1.0.0",
    channel: "web",
    eventName: "note.opened",
    params: { label: "노트 📘", privatePayload },
  };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((finish) => { resolve = finish; });
  return { promise, resolve };
}

function installHost({
  storage = { value: undefined as unknown },
  readStorage = () => success({ found: storage.value !== undefined, value: storage.value ?? null }),
  writeStorage = () => success({ success: true }),
  request = () => httpReply(204),
}: {
  storage?: { value: unknown };
  readStorage?: () => HostReply | Promise<HostReply>;
  writeStorage?: () => HostReply | Promise<HostReply>;
  request?: () => HostReply | Promise<HostReply>;
} = {}) {
  const requests: Record<string, unknown>[] = [];
  const diagnostics: HostMessage[] = [];
  const operations: string[] = [];
  const postMessage = vi.fn(async (message: HostMessage): Promise<HostReply> => {
    if (message.type === "diagnostic") diagnostics.push(message);
    if (message.type !== "invoke") return success(null);

    const { operationID, input } = message;
    operations.push(operationID);
    switch (operationID) {
      case "exporter.http.request":
        requests.push(input);
        return request();
      case "exporter.storage.get":
        expect(input).toMatchObject(pendingKey);
        return readStorage();
      case "exporter.storage.set": {
        expect(input).toMatchObject(pendingKey);
        const value = structuredClone(input.value);
        const reply = await writeStorage();
        if (reply.ok) storage.value = value;
        return reply;
      }
      case "exporter.storage.remove":
        expect(input).toMatchObject(pendingKey);
        storage.value = undefined;
        return success({ success: true });
      default:
        throw new Error(`Unexpected operation: ${operationID}`);
    }
  });
  vi.stubGlobal("window", { webkit: { messageHandlers: { necto: { postMessage } } } });

  return {
    requests,
    diagnostics,
    operations,
    storage,
    bodies: () => requests.map(({ bodyBase64 }) => {
      expect(bodyBase64).toBeTypeOf("string");
      const bytes = Uint8Array.from(atob(bodyBase64 as string), (byte) => byte.charCodeAt(0));
      return JSON.parse(new TextDecoder().decode(bytes)) as { events: NectoEvent[] };
    }),
  };
}

function receive(...events: NectoEvent[]) {
  for (const item of events) window.__nectoExporterReceive!(item);
}

const tick = (milliseconds = 0) => vi.advanceTimersByTimeAsync(milliseconds);

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(startedAt);
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("HTTPExporter", () => {
  it("sends UTF-8 JSON using the configured headers when the default threshold of 100 is reached", async () => {
    const host = installHost();
    await necto.registerExporter(new HTTPExporter({ url, headers: { Authorization: authorization } }));
    const events = Array.from({ length: 100 }, (_, index) => event(index + 1));

    receive(...events.slice(0, 99));
    await tick();
    expect(host.requests).toHaveLength(0);

    receive(events[99]);
    await tick();
    expect(host.requests).toHaveLength(1);
    expect(host.requests[0]).toMatchObject({ url, method: "POST" });
    const headers = Object.fromEntries(
      Object.entries(host.requests[0].headers as Record<string, string>)
        .map(([name, value]) => [name.toLowerCase(), value]),
    );
    expect(headers.authorization).toBe(authorization);
    expect(headers["content-type"]).toMatch(/^application\/json(?:;|$)/i);
    expect(host.bodies()).toEqual([{ events }]);
  });

  it("sends all 250 events that arrive while the first request of 100 is active", async () => {
    const first = deferred<HostReply>();
    const request = vi.fn((): HostReply | Promise<HostReply> => httpReply(204))
      .mockImplementationOnce(() => first.promise);
    const host = installHost({ request });
    await necto.registerExporter(new HTTPExporter({ url }));
    const initial = Array.from({ length: 100 }, (_, index) => event(index + 1));
    const waiting = Array.from({ length: 250 }, (_, index) => event(index + 101));

    receive(...initial);
    await tick();
    expect(host.bodies()).toEqual([{ events: initial }]);

    receive(...waiting);
    await tick();
    expect(host.requests).toHaveLength(1);

    first.resolve(httpReply(204));
    await tick();
    expect(host.bodies()).toEqual([{ events: initial }, { events: waiting }]);
    await tick(60_000);
    expect(host.requests).toHaveLength(2);
  });

  it("starts the default 60-second window at the first pending event and sends no empty batches", async () => {
    const host = installHost();
    await necto.registerExporter(new HTTPExporter({ url }));
    await tick(75_000);
    expect(host.requests).toHaveLength(0);

    receive(event(1));
    await tick(45_000);
    receive(event(2));
    await tick(14_999);
    expect(host.requests).toHaveLength(0);

    await tick(1);
    expect(host.bodies()).toEqual([{ events: [event(1), event(2)] }]);
    await tick(60_000);
    expect(host.requests).toHaveLength(1);
  });

  it("keeps a single request in flight and drops the oldest waiting events at capacity", async () => {
    const first = deferred<HostReply>();
    const request = vi.fn((): HostReply | Promise<HostReply> => httpReply(204))
      .mockImplementationOnce(() => first.promise);
    const host = installHost({ request });
    await necto.registerExporter(new HTTPExporter({ url, maxEvents: 2, maxQueuedEvents: 2 }));

    receive(event(1), event(2));
    await tick();
    expect(host.bodies()).toEqual([{ events: [event(1), event(2)] }]);

    receive(event(3), event(4), event(5));
    await tick(60_000);
    expect(host.requests).toHaveLength(1);

    first.resolve(httpReply(204));
    await tick();
    expect(host.bodies()).toEqual([
      { events: [event(1), event(2)] },
      { events: [event(4), event(5)] },
    ]);
  });

  it("backs off retryable failures up to 60 seconds even when arrivals reach the threshold", async () => {
    const request = vi.fn(() => httpReply(204))
      .mockReturnValueOnce({
        ok: false,
        error: { code: "PROVIDER_FAILED", message: `Failed at ${url} with ${authorization}: ${privatePayload}` },
      })
      .mockReturnValueOnce(httpReply(408))
      .mockReturnValueOnce(httpReply(429))
      .mockReturnValueOnce(httpReply(500))
      .mockReturnValueOnce(httpReply(503))
      .mockReturnValueOnce(httpReply(502));
    const host = installHost({ request });
    await necto.registerExporter(new HTTPExporter({ url, maxEvents: 1, headers: { Authorization: authorization } }));
    receive(event(1));
    await tick();
    expect(host.requests).toHaveLength(1);

    receive(event(2));
    for (const [index, delay] of [5_000, 10_000, 20_000, 40_000, 60_000, 60_000].entries()) {
      await tick(delay - 1);
      expect(host.requests).toHaveLength(index + 1);
      await tick(1);
      expect(host.bodies()[index + 1]).toEqual({ events: [event(1), event(2)] });
    }

    await tick(1);
    expect(host.requests).toHaveLength(7);
    expect(host.storage.value).toBeUndefined();
    const diagnostics = JSON.stringify(host.diagnostics);
    expect(diagnostics).not.toContain(url);
    expect(diagnostics).not.toContain(authorization);
    expect(diagnostics).not.toContain(privatePayload);
  });

  it("keeps events below the threshold on their original deadline after a delayed success", async () => {
    const first = deferred<HostReply>();
    const request = vi.fn((): HostReply | Promise<HostReply> => httpReply(204))
      .mockImplementationOnce(() => first.promise);
    const host = installHost({ request });
    await necto.registerExporter(new HTTPExporter({ url, maxEvents: 2 }));
    receive(event(1), event(2));
    await tick();
    await tick(1_000);
    receive(event(3));
    await tick(19_000);
    first.resolve(httpReply(204));
    await tick();
    await tick(40_999);
    expect(host.requests).toHaveLength(1);
    await tick(1);
    expect(host.bodies()).toEqual([
      { events: [event(1), event(2)] },
      { events: [event(3)] },
    ]);
  });

  it("does not postpone a due retry when another event arrives before the timer runs", async () => {
    const request = vi.fn(() => httpReply(204)).mockReturnValueOnce(httpReply(503));
    const host = installHost({ request });
    await necto.registerExporter(new HTTPExporter({ url }));
    receive(event(1));
    await tick(60_000);
    expect(host.requests).toHaveLength(1);
    vi.setSystemTime(startedAt.getTime() + 65_000);
    receive(event(2));
    await tick();
    expect(host.bodies()).toEqual([{ events: [event(1)] }, { events: [event(1), event(2)] }]);
  });

  it.each([
    { retryAfter: "12", wait: 12_000 },
    { retryAfter: new Date(startedAt.getTime() + 90_000).toUTCString(), wait: 90_000 },
    { retryAfter: "2", wait: 5_000 },
    { retryAfter: "invalid", wait: 5_000 },
  ])("respects Retry-After $retryAfter without shortening local backoff", async ({ retryAfter, wait }) => {
    const request = vi.fn(() => httpReply(204))
      .mockReturnValueOnce(httpReply(429, { "rEtRy-AfTeR": retryAfter }));
    const host = installHost({ request });
    await necto.registerExporter(new HTTPExporter({ url, maxEvents: 1 }));

    receive(event(1));
    await tick(wait - 1);
    expect(host.requests).toHaveLength(1);
    await tick(1);
    expect(host.bodies()).toEqual([{ events: [event(1)] }, { events: [event(1)] }]);
  });

  it("discards terminal 4xx batches and emits a diagnostic without request or response data", async () => {
    const responseData = "fixture-response-details";
    const request = vi.fn(() => httpReply(204)).mockReturnValueOnce(
      success({ status: 401, headers: {}, bodyBase64: btoa(responseData) }),
    );
    const host = installHost({ request });
    await necto.registerExporter(new HTTPExporter({ url, maxEvents: 1, headers: { Authorization: authorization } }));

    receive(event(1));
    await tick();
    receive(event(2));
    await tick(60_000);
    expect(host.bodies()).toEqual([{ events: [event(1)] }, { events: [event(2)] }]);
    expect(host.diagnostics.length).toBeGreaterThan(0);
    const diagnostics = JSON.stringify(host.diagnostics);
    expect(diagnostics).not.toContain(url);
    expect(diagnostics).not.toContain(authorization);
    expect(diagnostics).not.toContain(privatePayload);
    expect(diagnostics).not.toContain(responseData);
    expect(diagnostics).not.toContain(btoa(responseData));
  });

  it("sends recovered events promptly ahead of arrivals during restore and keeps their event IDs", async () => {
    const saved = checkpoint(event(1), event(2));
    const read = deferred<HostReply>();
    const host = installHost({ storage: { value: saved }, readStorage: () => read.promise });
    await necto.registerExporter(new HTTPExporter({ url }));

    receive(event(3));
    await tick();
    expect(host.requests).toHaveLength(0);
    read.resolve(success({ found: true, value: saved }));

    await tick();
    expect(host.bodies()[0].events.slice(0, 2)).toEqual(saved.events);
    await tick(60_000);
    expect(host.bodies().flatMap(({ events }) => events)).toEqual([event(1), event(2), event(3)]);
    expect(host.storage.value).toBeUndefined();
  });

  it("ignores an unsupported checkpoint version and continues delivering new events", async () => {
    const host = installHost({ storage: { value: { version: 2, events: [event(1)] } } });
    await necto.registerExporter(new HTTPExporter({ url, maxEvents: 1 }));

    receive(event(2));
    await tick();
    expect(host.bodies()).toEqual([{ events: [event(2)] }]);
    expect(host.diagnostics.length).toBeGreaterThan(0);
  });

  it("retries all failed and waiting events with their original IDs, then saves new waiting events", async () => {
    const first = deferred<HostReply>();
    const retry = deferred<HostReply>();
    const request = vi.fn((): HostReply | Promise<HostReply> => httpReply(204))
      .mockImplementationOnce(() => first.promise)
      .mockImplementationOnce(() => retry.promise);
    const host = installHost({ request });
    await necto.registerExporter(new HTTPExporter({ url, maxEvents: 2 }));

    receive(event(1), event(2));
    await tick();
    receive(event(3));
    first.resolve(httpReply(503));
    await tick();
    expect(host.storage.value).toEqual(checkpoint(event(1), event(2), event(3)));

    await tick(5_000);
    expect(host.bodies()).toEqual([
      { events: [event(1), event(2)] },
      { events: [event(1), event(2), event(3)] },
    ]);

    receive(event(4));
    retry.resolve(httpReply(204));
    await tick();
    expect(host.storage.value).toEqual(checkpoint(event(4)));

    await tick(59_999);
    expect(host.requests).toHaveLength(2);
    await tick(1);
    expect(host.bodies().at(-1)).toEqual({ events: [event(4)] });
    expect(host.storage.value).toBeUndefined();
  });

  it("coalesces checkpoint updates during a stalled write and saves the latest waiting events", async () => {
    const firstRequest = deferred<HostReply>();
    const firstWrite = deferred<HostReply>();
    const writeStorage = vi.fn((): HostReply | Promise<HostReply> => success({ success: true }))
      .mockImplementationOnce(() => firstWrite.promise);
    const request = vi.fn((): HostReply | Promise<HostReply> => httpReply(204))
      .mockImplementationOnce(() => firstRequest.promise);
    const host = installHost({ storage: { value: checkpoint(event(1)) }, request, writeStorage });
    await necto.registerExporter(new HTTPExporter({ url, maxEvents: 2, maxQueuedEvents: 2 }));
    await tick();
    expect(host.bodies()).toEqual([{ events: [event(1)] }]);

    receive(event(2), event(3), event(4));
    await tick();
    expect(writeStorage).toHaveBeenCalledTimes(1);

    receive(...Array.from({ length: 100 }, (_, index) => event(index + 5)));
    await tick();
    expect(writeStorage).toHaveBeenCalledTimes(1);

    firstWrite.resolve(success({ success: true }));
    await tick();
    expect(writeStorage).toHaveBeenCalledTimes(2);
    expect(host.storage.value).toEqual(checkpoint(event(1), event(103), event(104)));

    firstRequest.resolve(httpReply(204));
    await tick();
    expect(host.bodies().at(-1)).toEqual({ events: [event(103), event(104)] });
    expect(host.storage.value).toBeUndefined();
  });

  it("saves an active request and waiting events before the shutdown deadline and recovers both", async () => {
    const blocked = deferred<HostReply>();
    const host = installHost({ request: () => blocked.promise });
    await necto.registerExporter(new HTTPExporter({ url, maxEvents: 1 }));

    receive(event(1));
    await tick();
    receive(event(2));
    void window.__nectoExporterShutdown!({ deadlineAt: Date.now() + 5_000 });
    receive(event(3));
    await tick();
    expect(host.requests).toHaveLength(1);
    expect(host.storage.value).toEqual(checkpoint(event(1), event(2)));

    // The native host closes the page at the deadline even if the request is still pending.
    await tick(5_000);
    const restarted = installHost({ storage: host.storage });
    await necto.registerExporter(new HTTPExporter({ url }));
    await tick();
    expect(restarted.bodies()).toEqual([{ events: [event(1), event(2)] }]);
    expect(restarted.storage.value).toBeUndefined();
  });

  it("checkpoints before flushing a partial batch on shutdown", async () => {
    const host = installHost();
    await necto.registerExporter(new HTTPExporter({ url }));
    receive(event(1));

    await window.__nectoExporterShutdown!({ deadlineAt: Date.now() + 5_000 });

    expect(host.bodies()).toEqual([{ events: [event(1)] }]);
    expect(host.operations.indexOf("exporter.storage.set")).toBeGreaterThanOrEqual(0);
    expect(host.operations.indexOf("exporter.storage.set")).toBeLessThan(
      host.operations.indexOf("exporter.http.request"),
    );
    expect(host.storage.value).toBeUndefined();
  });

  it("retains backed-off work on shutdown when its retry time is beyond the deadline", async () => {
    const host = installHost({ request: () => httpReply(503) });
    await necto.registerExporter(new HTTPExporter({ url, maxEvents: 1 }));
    receive(event(1));
    await tick();

    const shutdown = window.__nectoExporterShutdown!({ deadlineAt: Date.now() + 3_000 });
    await tick(5_000);
    await expect(shutdown).resolves.toBeUndefined();
    expect(host.bodies()).toEqual([{ events: [event(1)] }]);
    expect(host.storage.value).toEqual(checkpoint(event(1)));
  });
});
