//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { beforeEach, describe, expect, it, vi } from "vitest";

import type { NectoPluginContext } from "./types";

type Reply = { ok: true; value: unknown } | { ok: false; error: unknown };

/** Stands in for the host so the tests exercise the real transport code. */
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

beforeEach(() => {
  delete (globalThis as any).window;
});

describe("availability", () => {
  it("reports the host as missing outside Necto", async () => {
    (globalThis as any).window = {};
    const bridge = await loadBridge();
    expect(bridge.necto.isAvailable()).toBe(false);
  });

  it("rejects calls made outside Necto", async () => {
    (globalThis as any).window = {};
    const bridge = await loadBridge();
    await expect(bridge.necto.context()).rejects.toBeInstanceOf(
      bridge.NectoBridgeUnavailableError,
    );
  });
});

describe("names", () => {
  /// The plugin-facing call is `send`, and it still travels as the wire's `invoke`.
  /// Renaming what an author writes must not rename what the host is listening for.
  it("keeps the wire message name after the rename", async () => {
    const postMessage = installHost(() => ({ ok: true, value: {} }));
    const bridge = await loadBridge();

    await bridge.necto.device.send("records.list");
    expect(postMessage).toHaveBeenCalledWith({
      type: "invoke",
      operationID: "records.list",
      input: {},
    });
  });

  it("no longer answers to the old name", async () => {
    const bridge = await loadBridge();
    expect((bridge.necto.device as unknown as Record<string, unknown>).invoke).toBeUndefined();
  });
});

describe("send", () => {
  it("unwraps a successful reply", async () => {
    const postMessage = installHost(() => ({ ok: true, value: { count: 3 } }));
    const bridge = await loadBridge();

    await expect(bridge.necto.device.send("records.list", { limit: 50 })).resolves.toEqual({
      count: 3,
    });
    expect(postMessage).toHaveBeenCalledWith({
      type: "invoke",
      operationID: "records.list",
      input: { limit: 50 },
    });
  });

  it("turns a failed reply into an error carrying the code", async () => {
    installHost(() => ({
      ok: false,
      error: { code: "PERMISSION_DENIED", message: "not granted" },
    }));
    const bridge = await loadBridge();

    const error = await bridge.necto.device.send("records.list").catch((value) => value);
    expect(bridge.isNectoBridgeError(error)).toBe(true);
    expect(bridge.hasErrorCode(error, "PERMISSION_DENIED")).toBe(true);
    expect(error.message).toBe("not granted");
  });
});

describe("subscribe", () => {
  it("delivers events the host pushes", async () => {
    installHost(() => ({ ok: true, value: "s1" }));
    const bridge = await loadBridge();
    const events: unknown[] = [];

    await bridge.necto.device.subscribe("host.ticks", {}, (event) => events.push(event));
    (globalThis as any).window.__nectoBridgeDeliver("s1", { sequence: 1 });

    expect(events).toEqual([{ sequence: 1 }]);
  });

  it("stops delivering after unsubscribe", async () => {
    installHost(() => ({ ok: true, value: "s1" }));
    const bridge = await loadBridge();
    const events: unknown[] = [];

    const subscription = await bridge.necto.device.subscribe("host.ticks", {}, (event) =>
      events.push(event),
    );
    await subscription.unsubscribe();
    (globalThis as any).window.__nectoBridgeDeliver("s1", { sequence: 1 });

    expect(events).toEqual([]);
  });

  it("reports stream failures to the error handler", async () => {
    installHost(() => ({ ok: true, value: "s1" }));
    const bridge = await loadBridge();
    let received: any;

    await bridge.necto.device.subscribe(
      "host.ticks",
      {},
      () => {},
      (error) => {
        received = error;
      },
    );
    (globalThis as any).window.__nectoBridgeStreamError("s1", {
      code: "TARGET_DISCONNECTED",
      message: "app went away",
    });

    expect(bridge.hasErrorCode(received, "TARGET_DISCONNECTED")).toBe(true);
  });

  it("ignores events for a subscription that already ended", async () => {
    installHost(() => ({ ok: true, value: "s1" }));
    const bridge = await loadBridge();
    const events: unknown[] = [];

    await bridge.necto.device.subscribe("host.ticks", {}, (event) => events.push(event));
    (globalThis as any).window.__nectoBridgeStreamEnd("s1");
    (globalThis as any).window.__nectoBridgeDeliver("s1", { sequence: 1 });

    expect(events).toEqual([]);
  });
});

describe("isOperationAvailable", () => {
  it("reads availability from a context snapshot", async () => {
    const bridge = await loadBridge();
    const context: NectoPluginContext = {
      protocolVersion: 1,
      pluginID: "hello",
      pluginVersion: "1.0.0",
      sourceIdentity: "builtin",
      operations: [
        { id: "host.info", kind: "once", available: true },
        { id: "host.ticks", kind: "stream", available: false },
      ],
    };

    expect(bridge.isOperationAvailable(context, "host.info")).toBe(true);
    expect(bridge.isOperationAvailable(context, "host.ticks")).toBe(false);
    expect(bridge.isOperationAvailable(context, "missing")).toBe(false);
  });
});
