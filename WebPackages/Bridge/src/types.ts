//
//  Copyright (c) 2026 Viva Republica, Inc.
//

/** Any value that can cross the bridge. Inputs, outputs and stream events are JSON. */
export type NectoJSONValue =
  | null
  | boolean
  | number
  | string
  | NectoJSONValue[]
  | { [key: string]: NectoJSONValue };

export type NectoJSONObject = { [key: string]: NectoJSONValue };

/** How an operation answers: `once` through `send`, `stream` through `subscribe`. */
export type NectoOperationKind = "once" | "stream";

/** State of one operation declared in the plugin manifest. */
export interface NectoAvailableOperation {
  id: string;
  kind: NectoOperationKind;
  available: boolean;
  /** Why the operation cannot be used. Safe to show to the user as-is. */
  unavailableReason?: string;
}

/**
 * The connected app the host selected.
 *
 * Plugins never receive a raw device identifier. `targetHandle` is issued by the
 * host per plugin and is the only way to address a target.
 */
export interface NectoTargetInfo {
  targetHandle: string;
  /** @deprecated Use targetHandle. This compatibility alias is not a hardware ID. */
  deviceID: string;
  appBundleID: string;
  name?: string;
  appName?: string;
}

/** Identity, available operations and the selected target for the running plugin. */
export interface NectoPluginContext {
  protocolVersion: 1;
  pluginID: string;
  pluginVersion: string;
  sourceIdentity: string;
  operations: NectoAvailableOperation[];
  /** Absent when the user has not selected a connected app. */
  target?: NectoTargetInfo;
}

export type NectoBridgeErrorCode =
  | "INVALID_INPUT"
  | "OPERATION_NOT_FOUND"
  | "OPERATION_UNAVAILABLE"
  | "PERMISSION_DENIED"
  | "UNAUTHORIZED"
  | "TARGET_DISCONNECTED"
  | "TIMEOUT"
  | "CANCELLED"
  | "PROVIDER_FAILED"
  | "INVALID_OUTPUT";

export interface NectoBridgeError extends Error {
  code: NectoBridgeErrorCode;
  operationID?: string;
  details?: NectoJSONObject;
}

export interface NectoSubscription {
  readonly id: string;
  unsubscribe(): Promise<void>;
}
