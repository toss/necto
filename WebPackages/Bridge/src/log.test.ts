//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { afterEach, beforeEach, describe, expect, expectTypeOf, it, vi } from "vitest";

import type { NectoEvent } from "./types";

type Reply = { ok: true; value: unknown } | { ok: false; error: unknown };

function installHost(reply: (message: any) => Reply | Promise<Reply>) {
  const postMessage = vi.fn(reply);
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

afterEach(() => {
  vi.restoreAllMocks();
});

describe("log", () => {
  it("sends the event name and params in the host input envelope", async () => {
    const postMessage = installHost(() => ({ ok: true, value: null }));
    const { necto } = await loadBridge();

    expect(necto.log("note.opened", { source: "sidebar", pinned: true })).toBeUndefined();
    expect(postMessage).toHaveBeenCalledExactlyOnceWith({
      type: "log",
      input: { eventName: "note.opened", params: { source: "sidebar", pinned: true } },
    });
  });

  it("defaults params to an empty object", async () => {
    const postMessage = installHost(() => ({ ok: true, value: null }));
    const { necto } = await loadBridge();

    necto.log("note.opened");
    expect(postMessage).toHaveBeenCalledExactlyOnceWith({
      type: "log",
      input: { eventName: "note.opened", params: {} },
    });
  });

  it("returns immediately while the host reply is pending", async () => {
    let complete!: (reply: Reply) => void;
    installHost(() => new Promise<Reply>((resolve) => { complete = resolve; }));
    const { necto } = await loadBridge();

    const result = necto.log("note.opened");
    expect(result).toBeUndefined();
    complete({ ok: true, value: null });
  });

  it.each(["reply", "reject", "throw"])("does not propagate a host %s failure or expose its payload", async (mode) => {
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    const postMessage = installHost(() => {
      if (mode === "throw") throw new Error("private host error");
      if (mode === "reject") return Promise.reject(new Error("private host error"));
      return {
        ok: false,
        error: { code: "INVALID_INPUT", message: "private host error", details: { private: "value" } },
      };
    });
    const { necto } = await loadBridge();

    expect(necto.log("private.event", { private: "value" })).toBeUndefined();
    await vi.waitFor(() => expect(warning).toHaveBeenCalledExactlyOnceWith(
      "Necto could not record an event.",
    ));
    expect(postMessage).toHaveBeenCalledTimes(1);
  });

  it.each(["no window", "no host"])("is a quiet no-op outside Necto with %s", async (mode) => {
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    if (mode === "no host") (globalThis as any).window = {};
    const { necto } = await loadBridge();

    expect(necto.log("note.opened")).toBeUndefined();
    expect(warning).not.toHaveBeenCalled();
  });

  it("describes web and CLI event channels without a UI alias", () => {
    expectTypeOf<NectoEvent["channel"]>().toEqualTypeOf<"web" | "cli" | undefined>();
  });
});
