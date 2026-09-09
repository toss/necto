//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import {
  NectoBridgeUnavailableError,
  installStreamReceivers,
  isHostAvailable,
  callHost,
  registerStream,
  unregisterStream,
} from "./transport";
import type {
  NectoBridgeError,
  NectoBridgeErrorCode,
  NectoJSONObject,
  NectoPluginContext,
  NectoSubscription,
} from "./types";
import { createTranslator, locale } from "./localization";

export type * from "./types";
export type * from "./localization";
export { NectoBridgeUnavailableError };
export { createTranslator, locale };

installStreamReceivers();

/** Whether the page is running inside Necto. Use it to render a fallback in a plain browser. */
export function isNectoAvailable(): boolean {
  return isHostAvailable();
}

export function isNectoBridgeError(value: unknown): value is NectoBridgeError {
  return value instanceof Error && "code" in value;
}

export function hasErrorCode(
  value: unknown,
  code: NectoBridgeErrorCode,
): value is NectoBridgeError {
  return isNectoBridgeError(value) && value.code === code;
}

/** Reads identity, available operations and the selected target. */
export function context(): Promise<NectoPluginContext> {
  return callHost<NectoPluginContext>("context");
}

/**
 * Tells the host that every handler is registered.
 *
 * Stream events produced before this resolves are buffered by the host and
 * delivered afterwards, so no event is lost while the page starts up.
 */
export async function ready(): Promise<void> {
  await callHost<null>("ready");
}

/**
 * One side of the bridge: everything answered by the Mac, or everything answered by
 * the connected app.
 *
 * Which one an operation belongs to is decided by its manifest binding, not here.
 * Naming the side at the call site is for whoever reads it — the two fail differently,
 * and only `device` can fail because nothing is connected.
 */
export interface NectoSide {
  /** Runs a `query` or `command` operation once. */
  send<Output extends object = NectoJSONObject>(
    operationID: string,
    input?: NectoJSONObject,
  ): Promise<Output>;

  /** Subscribes to a `stream` operation. Call {@link ready} once handlers are registered. */
  subscribe<Event extends object = NectoJSONObject>(
    operationID: string,
    input: NectoJSONObject,
    onEvent: (event: Event) => void,
    onError?: (error: NectoBridgeError) => void,
  ): Promise<NectoSubscription>;
}

function side(): NectoSide {
  return {
    send<Output extends object = NectoJSONObject>(
      operationID: string,
      input: NectoJSONObject = {},
    ): Promise<Output> {
      // The host validates input and output against the schemas the manifest declares,
      // so `Output` describes what the manifest already guarantees.
      return callHost<Output>("invoke", { operationID, input });
    },

    async subscribe<Event extends object = NectoJSONObject>(
      operationID: string,
      input: NectoJSONObject = {},
      onEvent: (event: Event) => void,
      onError?: (error: NectoBridgeError) => void,
    ): Promise<NectoSubscription> {
      const subscriptionID = await callHost<string>("subscribe", { operationID, input });

      registerStream(subscriptionID, {
        onEvent: onEvent as (event: NectoJSONObject) => void,
        onError,
      });

      return {
        id: subscriptionID,
        async unsubscribe() {
          unregisterStream(subscriptionID);
          await callHost<null>("unsubscribe", { subscriptionID });
        },
      };
    },
  };
}

/** Whether an operation can be called right now, based on a context snapshot. */
export function isOperationAvailable(
  pluginContext: NectoPluginContext,
  operationID: string,
): boolean {
  return (
    pluginContext.operations.find((operation) => operation.id === operationID)
      ?.available ?? false
  );
}

export { createDetailPane } from "./detail-pane";

/**
 * Everything a plugin can reach, in one object.
 *
 * `isAvailable`, `context` and `ready` belong to neither side, so they sit above both
 * rather than being repeated on each.
 */
export const necto = {
  isAvailable: isNectoAvailable,
  context,
  ready,
  locale,
  createTranslator,
  isOperationAvailable,

  /** Answered by the connected app, on a device or a simulator. */
  device: side(),

  /** Answered by the Mac app: storage, targets, and what Necto itself knows. */
  desktop: side(),
};
