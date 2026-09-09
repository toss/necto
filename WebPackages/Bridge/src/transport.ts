//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import type { NectoBridgeError, NectoBridgeErrorCode, NectoJSONObject } from "./types";

/**
 * The WebKit message handler the host registers.
 *
 * Registered with `addScriptMessageHandler(_:contentWorld:name:)`, so `postMessage`
 * resolves with the host's reply instead of returning `undefined`.
 */
interface WebKitMessageHandler {
  postMessage(message: unknown): Promise<HostReply>;
}

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: Record<string, WebKitMessageHandler | undefined>;
    };
    /** Defined below so the host can push stream events into this page. */
    __nectoBridgeDeliver?: (subscriptionID: string, event: NectoJSONObject) => void;
    __nectoBridgeStreamError?: (
      subscriptionID: string,
      error: { code: NectoBridgeErrorCode; message: string; operationID?: string },
    ) => void;
    __nectoBridgeStreamEnd?: (subscriptionID: string) => void;
  }
}

/** Every reply carries success or a structured error, so error codes survive the boundary. */
type HostReply =
  | { ok: true; value: unknown }
  | {
      ok: false;
      error: {
        code: NectoBridgeErrorCode;
        message: string;
        operationID?: string;
        details?: NectoJSONObject;
      };
    };

export const HOST_HANDLER_NAME = "necto";

export class NectoBridgeUnavailableError extends Error {
  constructor() {
    super("The Necto host was not found. This page must run inside Necto.");
    this.name = "NectoBridgeUnavailableError";
  }
}

function createError(payload: {
  code: NectoBridgeErrorCode;
  message: string;
  operationID?: string;
  details?: NectoJSONObject;
}): NectoBridgeError {
  const error = new Error(payload.message) as NectoBridgeError;
  error.name = "NectoBridgeError";
  error.code = payload.code;
  error.operationID = payload.operationID;
  error.details = payload.details;
  return error;
}

export function isHostAvailable(): boolean {
  return Boolean(globalThis.window?.webkit?.messageHandlers?.[HOST_HANDLER_NAME]);
}

/** Sends one request to the host and unwraps its reply. */
export async function callHost<Result>(
  type: string,
  payload: NectoJSONObject = {},
): Promise<Result> {
  const handler = globalThis.window?.webkit?.messageHandlers?.[HOST_HANDLER_NAME];
  if (!handler) throw new NectoBridgeUnavailableError();

  const reply = await handler.postMessage({ type, ...payload });
  if (!reply.ok) throw createError(reply.error);
  return reply.value as Result;
}

type StreamHandlers = {
  onEvent: (event: NectoJSONObject) => void;
  onError?: (error: NectoBridgeError) => void;
};

const streams = new Map<string, StreamHandlers>();

export function registerStream(subscriptionID: string, handlers: StreamHandlers): void {
  streams.set(subscriptionID, handlers);
}

export function unregisterStream(subscriptionID: string): void {
  streams.delete(subscriptionID);
}

/**
 * Installs the entry points the host calls to push stream events.
 *
 * Request and response travel over `postMessage`, but a stream is pushed by the
 * host, and WebKit has no reverse channel other than evaluating a function that
 * already exists on the page. These three functions are that surface.
 */
export function installStreamReceivers(): void {
  if (!globalThis.window || globalThis.window.__nectoBridgeDeliver) return;

  globalThis.window.__nectoBridgeDeliver = (subscriptionID, event) => {
    streams.get(subscriptionID)?.onEvent(event);
  };

  globalThis.window.__nectoBridgeStreamError = (subscriptionID, error) => {
    const handlers = streams.get(subscriptionID);
    streams.delete(subscriptionID);
    handlers?.onError?.(createError(error));
  };

  globalThis.window.__nectoBridgeStreamEnd = (subscriptionID) => {
    streams.delete(subscriptionID);
  };
}
