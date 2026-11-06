//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { beforeEach, describe, expect, it, vi } from "vitest";

type Reply = { ok: true; value: unknown } | { ok: false; error: unknown };

function installHost(reply: (message: any) => Reply | Promise<Reply>) {
  const postMessage = vi.fn(async (message: unknown) => reply(message));
  (globalThis as any).window = {
    webkit: { messageHandlers: { necto: { postMessage } } },
  };
  return postMessage;
}

async function loadBridge() {
  vi.resetModules();
  return import("./index");
}

const event = {
  eventId: "event-1",
  occurredAt: 1_793_750_400_000,
  installationId: "installation-1",
  nectoVersion: "0.1.0",
  origin: "desktop" as const,
  pluginId: "com.example.notes",
  pluginVersion: "1.0.0",
  channel: "web" as const,
  eventName: "note.opened",
  params: { source: "sidebar" },
};
const shutdownContext = { deadlineAt: 1_793_750_405_000 };

beforeEach(() => {
  delete (globalThis as any).window;
});

describe("registerExporter", () => {
  it("receives events while registration is still pending", async () => {
    const onEvent = vi.fn();
    let complete!: (reply: Reply) => void;
    let shutdownAtRegistration: Window["__nectoExporterShutdown"];
    const postMessage = installHost(() => {
      window.__nectoExporterReceive!(event);
      shutdownAtRegistration = window.__nectoExporterShutdown;
      return new Promise<Reply>((resolve) => { complete = resolve; });
    });
    const { necto } = await loadBridge();

    const registration = necto.registerExporter({ onEvent });
    expect(onEvent).toHaveBeenCalledWith(event);
    expect(postMessage).toHaveBeenCalledWith({ type: "registerExporter" });
    complete({ ok: true, value: null });
    await expect(registration).resolves.toBeUndefined();
    expect(shutdownAtRegistration).toBeTypeOf("function");
    window.__nectoExporterReceive!(event);
    expect(onEvent).toHaveBeenCalledTimes(2);
  });

  it("removes a failed receiver and allows registration to be retried", async () => {
    let allowed = false;
    installHost(() => allowed
      ? { ok: true, value: null }
      : { ok: false, error: { code: "PERMISSION_DENIED", message: "Not an exporter" } });
    const { necto } = await loadBridge();
    const rejectedHandler = vi.fn();
    await expect(necto.registerExporter({ onEvent: rejectedHandler })).rejects.toMatchObject({
      code: "PERMISSION_DENIED",
    });
    expect(window.__nectoExporterReceive).toBeUndefined();
    expect(window.__nectoExporterShutdown).toBeUndefined();

    allowed = true;
    const onEvent = vi.fn();
    await necto.registerExporter({ onEvent });
    window.__nectoExporterReceive!(event);
    expect(onEvent).toHaveBeenCalledWith(event);
    await expect(window.__nectoExporterShutdown!(shutdownContext)).resolves.toBeUndefined();
    expect(rejectedHandler).not.toHaveBeenCalled();
  });

  it("rejects a duplicate without replacing the active callback", async () => {
    const postMessage = installHost(() => ({ ok: true, value: null }));
    const { necto } = await loadBridge();
    const onEvent = vi.fn();
    const duplicate = vi.fn();
    await necto.registerExporter({ onEvent });

    await expect(necto.registerExporter({ onEvent: duplicate })).rejects.toThrow(/already registered/i);
    window.__nectoExporterReceive!(event);
    expect(onEvent).toHaveBeenCalledWith(event);
    expect(duplicate).not.toHaveBeenCalled();
    expect(postMessage).toHaveBeenCalledTimes(1);
  });

  it("rejects a duplicate while the first registration is pending", async () => {
    let complete!: (reply: Reply) => void;
    const postMessage = installHost(() => new Promise<Reply>((resolve) => { complete = resolve; }));
    const { necto } = await loadBridge();
    const registration = necto.registerExporter({ onEvent: vi.fn() });

    await expect(necto.registerExporter({ onEvent: vi.fn() })).rejects.toThrow(/already registered/i);
    expect(postMessage).toHaveBeenCalledTimes(1);
    complete({ ok: true, value: null });
    await registration;
  });

  it("cleans up when the host transport rejects", async () => {
    installHost(() => Promise.reject(new Error("Host stopped")));
    const { necto } = await loadBridge();
    await expect(necto.registerExporter({ onEvent: vi.fn() })).rejects.toThrow("Host stopped");
    expect(window.__nectoExporterReceive).toBeUndefined();
    expect(window.__nectoExporterShutdown).toBeUndefined();
  });

  it("rejects outside Necto", async () => {
    const bridge = await loadBridge();
    await expect(bridge.necto.registerExporter({ onEvent: vi.fn() })).rejects.toBeInstanceOf(
      bridge.NectoBridgeUnavailableError,
    );
  });

  it.each(["throw", "reject"])("reports callback %s failures as diagnostics and keeps receiving", async (mode) => {
    const postMessage = installHost(() => ({ ok: true, value: null }));
    const { necto } = await loadBridge();
    const onEvent = vi.fn(() => {
      if (mode === "throw") throw new Error("Failed to queue");
      return Promise.reject(new Error("Failed to queue"));
    });
    await necto.registerExporter({ onEvent });

    expect(() => window.__nectoExporterReceive!(event)).not.toThrow();
    await vi.waitFor(() => expect(postMessage).toHaveBeenCalledWith({
      type: "diagnostic",
      level: "failure",
      message: "Event exporter callback failed.",
    }));
    window.__nectoExporterReceive!(event);
    expect(onEvent).toHaveBeenCalledTimes(2);
  });

  it("does not recurse when reporting a callback failure also fails", async () => {
    const postMessage = installHost((message) => message.type === "diagnostic"
      ? { ok: false, error: { code: "PROVIDER_FAILED", message: "Log unavailable" } }
      : { ok: true, value: null });
    const { necto } = await loadBridge();
    await necto.registerExporter({ onEvent: () => { throw new Error("Failed"); } });

    expect(() => window.__nectoExporterReceive!(event)).not.toThrow();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(postMessage).toHaveBeenCalledTimes(2);
  });
});

describe("exporter shutdown", () => {
  it("resolves without a hook or waiting for an accepted event", async () => {
    installHost(() => ({ ok: true, value: null }));
    const { necto } = await loadBridge();
    let finishEvent!: () => void;
    const onEvent = vi.fn(() => new Promise<void>((resolve) => { finishEvent = resolve; }));
    await necto.registerExporter({ onEvent });
    window.__nectoExporterReceive!(event);

    const shutdown = window.__nectoExporterShutdown!(shutdownContext);
    window.__nectoExporterReceive!(event);
    await expect(shutdown).resolves.toBeUndefined();
    expect(onEvent).toHaveBeenCalledTimes(1);
    finishEvent();
  });

  it("waits for one hook invocation with the original deadline and stops accepting events immediately", async () => {
    installHost(() => ({ ok: true, value: null }));
    const { necto } = await loadBridge();
    const onEvent = vi.fn();
    let finishShutdown!: () => void;
    const onShutdown = vi.fn(() => new Promise<void>((resolve) => { finishShutdown = resolve; }));
    await necto.registerExporter({ onEvent, onShutdown });

    const shutdown = window.__nectoExporterShutdown!(shutdownContext);
    const settled = vi.fn();
    void shutdown.then(settled, settled);
    window.__nectoExporterReceive!(event);
    expect(window.__nectoExporterShutdown!({ deadlineAt: shutdownContext.deadlineAt + 1 })).toBe(shutdown);
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(onEvent).not.toHaveBeenCalled();
    expect(onShutdown).toHaveBeenCalledExactlyOnceWith(shutdownContext);
    expect(settled).not.toHaveBeenCalled();
    finishShutdown();
    await expect(shutdown).resolves.toBeUndefined();
    expect(settled).toHaveBeenCalledOnce();
  });

  it.each(["throw", "reject"])("propagates a hook %s on every shutdown call", async (mode) => {
    installHost(() => ({ ok: true, value: null }));
    const { necto } = await loadBridge();
    const error = new Error("Failed to flush");
    const onShutdown = vi.fn(() => {
      if (mode === "throw") throw error;
      return Promise.reject(error);
    });
    await necto.registerExporter({ onEvent: vi.fn(), onShutdown });

    const shutdown = window.__nectoExporterShutdown!(shutdownContext);
    await expect(shutdown).rejects.toBe(error);
    expect(window.__nectoExporterShutdown!(shutdownContext)).toBe(shutdown);
    expect(onShutdown).toHaveBeenCalledOnce();
  });

  it("keeps desktop operations and diagnostics usable during the hook", async () => {
    const postMessage = installHost(() => ({ ok: true, value: {} }));
    const { necto } = await loadBridge();
    const request = { url: "https://collector.example.com/events", method: "POST" };
    const storedBatch = { key: "pending-events", value: [event] };
    await necto.registerExporter({
      onEvent: vi.fn(),
      async onShutdown() {
        await necto.desktop.send("events.send", request);
        await necto.desktop.send("events.store", storedBatch);
        await necto.diagnostics.log("info", "Shutdown complete");
      },
    });

    await window.__nectoExporterShutdown!(shutdownContext);
    expect(postMessage.mock.calls.map(([message]) => message)).toEqual([
      { type: "registerExporter" },
      { type: "invoke", operationID: "events.send", input: request },
      { type: "invoke", operationID: "events.store", input: storedBatch },
      { type: "diagnostic", level: "info", message: "Shutdown complete" },
    ]);
  });
});

describe("diagnostics", () => {
  it("writes severity, message and optional metadata without delivering an event", async () => {
    const postMessage = installHost(() => ({ ok: true, value: null }));
    const { necto } = await loadBridge();
    const onEvent = vi.fn();
    await necto.registerExporter({ onEvent });

    await necto.diagnostics.log("warning", "Delivery pending", { count: 2 });
    expect(postMessage).toHaveBeenLastCalledWith({
      type: "diagnostic",
      level: "warning",
      message: "Delivery pending",
      metadata: { count: 2 },
    });
    await necto.diagnostics.log("info", "Delivery complete");
    expect(postMessage).toHaveBeenLastCalledWith({
      type: "diagnostic",
      level: "info",
      message: "Delivery complete",
    });
    expect(onEvent).not.toHaveBeenCalled();
  });

  it("propagates host failures to the caller", async () => {
    installHost(() => ({ ok: false, error: { code: "INVALID_INPUT", message: "Invalid diagnostic" } }));
    const { necto } = await loadBridge();
    await expect(necto.diagnostics.log("failure", "Delivery failed")).rejects.toMatchObject({
      code: "INVALID_INPUT",
    });
  });
});
