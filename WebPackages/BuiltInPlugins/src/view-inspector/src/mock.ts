//
//  Copyright (c) 2026 Viva Republica, Inc.
//

const windows = [
  {
    id: "window-1",
    className: "UIWindow",
    frame: [0, 0, 393, 852],
    children: [
      {
        id: "navigation-controller",
        className: "UINavigationControllerView",
        frame: [0, 0, 393, 852],
        children: [
          {
            id: "content-view",
            className: "ExampleAccountTransactionHistoryContentView",
            frame: [0, 96, 393, 756],
            children: [
              {
                id: "title-label",
                className: "UILabel",
                frame: [20, 112, 353, 28],
                text: "Recent transactions with a deliberately long title",
                children: [],
              },
              {
                id: "search-field",
                className: "UISearchTextField",
                frame: [20, 156, 353, 44],
                text: "Search transactions",
                children: [],
              },
              {
                id: "table-view",
                className: "UITableView",
                frame: [0, 216, 393, 636],
                children: [],
              },
            ],
          },
        ],
      },
    ],
  },
];

function reply(message: { type: string; operationID?: string }) {
  switch (message.type) {
    case "context":
      return {
        ok: true as const,
        value: {
          protocolVersion: 1,
          pluginID: "view-inspector",
          pluginVersion: "0.1.0",
          sourceIdentity: "mock",
          operations: [],
          target: {
            targetHandle: "mock",
            deviceID: "mock",
            appBundleID: "com.example.app",
            appName: "ExampleApp",
          },
        },
      };
    case "ready":
      return { ok: true as const, value: null };
    case "invoke":
      if (message.operationID === "views.tree") {
        return { ok: true as const, value: { windows } };
      }
      if (message.operationID === "views.snapshot") {
        return { ok: true as const, value: { snapshotID: "mock-baseline", windows } };
      }
      if (message.operationID === "views.compare") {
        return { ok: true as const, value: { changes: [] } };
      }
      if (message.operationID?.startsWith("views.")) {
        return { ok: true as const, value: { method: "mock" } };
      }
      break;
    default:
      break;
  }

  return {
    ok: false as const,
    error: { code: "OPERATION_NOT_FOUND", message: `No mock for '${message.type}'` },
  };
}

export function installMockBridge(): void {
  const target = window as unknown as {
    webkit?: { messageHandlers?: Record<string, { postMessage(message: unknown): Promise<unknown> }> };
  };
  target.webkit = {
    messageHandlers: {
      necto: {
        postMessage: async (message) =>
          reply(message as { type: string; operationID?: string }),
      },
    },
  };
}
