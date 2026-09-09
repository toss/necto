//
//  Copyright (c) 2026 Viva Republica, Inc.
//

/// A stand-in for the Necto host, used only by `yarn dev`.
///
/// Without it a plugin can only be looked at by building the Mac app, connecting a
/// device and making a request, which is far too slow a loop to catch a broken
/// layout. With it the plugin opens in a browser with representative data: long URLs,
/// failures, pending rows, a large body, and enough rows to scroll.
///
/// Never imported by the production bundle. `main.tsx` guards on `import.meta.env.DEV`,
/// so this file is dropped from the build entirely.

interface MockRecord {
  id: string;
  method: string;
  url: string;
  name: string;
  host: string;
  state: "pending" | "completed" | "failed";
  startedAtMilliseconds: number;
  statusCode?: number;
  durationMilliseconds?: number;
  responseByteCount?: number;
  errorSummary?: string;
}

const headers = {
  "Content-Type": "application/json; charset=utf-8",
  "Cache-Control": "max-age=0, no-cache",
  "Set-Cookie": "session=abc123; path=/; domain=.example.com; HttpOnly; Secure",
};

/// Deliberately awkward: a long URL, a long header value, a failure, something still
/// in flight. A layout that survives these survives real traffic.
const records: MockRecord[] = [
  {
    id: "1",
    method: "GET",
    url: "https://www.example.com/library/test/success.html",
    name: "success.html",
    host: "www.example.com",
    state: "completed",
    startedAtMilliseconds: Date.now() - 5000,
    statusCode: 200,
    durationMilliseconds: 103,
    responseByteCount: 68,
  },
  {
    id: "2",
    method: "POST",
    url: "https://api.example.com/v2/accounts/9f8e7d6c/transactions?include=merchant,category&limit=50",
    name: "transactions?include=merchant,category&limit=50",
    host: "api.example.com",
    state: "completed",
    startedAtMilliseconds: Date.now() - 4000,
    statusCode: 201,
    durationMilliseconds: 1840,
    responseByteCount: 24_576,
  },
  {
    id: "3",
    method: "GET",
    url: "https://api.example.com/v2/profile/unknown",
    name: "unknown",
    host: "api.example.com",
    state: "completed",
    startedAtMilliseconds: Date.now() - 3000,
    statusCode: 404,
    durationMilliseconds: 227,
    responseByteCount: 955,
  },
  {
    id: "4",
    method: "DELETE",
    url: "https://api.example.com/v2/sessions/current",
    name: "current",
    host: "api.example.com",
    state: "failed",
    startedAtMilliseconds: Date.now() - 2000,
    durationMilliseconds: 5000,
    errorSummary: "The request timed out.",
  },
  {
    id: "5",
    method: "PATCH",
    url: "https://api.example.com/v2/settings",
    name: "settings",
    host: "api.example.com",
    state: "pending",
    startedAtMilliseconds: Date.now() - 500,
  },
];

function detail(id: string) {
  const record = records.find((candidate) => candidate.id === id) ?? records[0];
  return {
    ...record,
    requestHeaders: { Accept: "application/json", "User-Agent": "ExampleApp/1.0 (iOS 18.6)" },
    responseHeaders: headers,
    requestBody:
      record.method === "GET"
        ? undefined
        : {
            byteCount: 84,
            isTruncated: false,
            contentType: "application/json",
            text: JSON.stringify({ amount: 1200, currency: "KRW", memo: "coffee" }),
          },
    responseBody: {
      byteCount: 24_576,
      isTruncated: true,
      contentType: "application/json",
      text: JSON.stringify(
        { items: Array.from({ length: 12 }, (_, index) => ({ id: index, label: `row ${index}` })) },
        null,
        2,
      ),
    },
    curl: `curl -X ${record.method} '${record.url}' \\\n  -H 'Accept: application/json'`,
  };
}

/// Answers on the same channel the Mac app uses, a `WKScriptMessageHandlerWithReply`
/// named "necto", so the plugin exercises the real bridge rather than a stub of it. A
/// mock that bypassed the transport would not catch a message the host cannot answer.
function reply(message: { type: string; operationID?: string; input?: Record<string, unknown> }) {
  switch (message.type) {
    case "context":
      return {
        ok: true as const,
        value: {
          protocolVersion: 1,
          pluginID: "network-logger",
          pluginVersion: "1.0.0",
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

    case "subscribe":
      return { ok: true as const, value: "mock-subscription" };

    case "invoke":
      if (message.operationID === "records.list") {
        return { ok: true as const, value: { records } };
      }
      if (message.operationID === "records.detail") {
        return { ok: true as const, value: { record: detail(String(message.input?.recordID)) } };
      }
      if (message.operationID === "records.clear") {
        return { ok: true as const, value: { cleared: true } };
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
          reply(message as { type: string; operationID?: string; input?: Record<string, unknown> }),
      },
    },
  };
}
