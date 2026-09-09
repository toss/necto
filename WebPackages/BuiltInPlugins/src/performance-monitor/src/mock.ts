//
//  Copyright (c) 2026 Viva Republica, Inc.
//

const metrics = [
  { id: "cpu", title: "CPU", unit: "%", budget: 80, budgetKind: "atMost" },
  { id: "memory", title: "Memory", unit: "MB" },
  { id: "fps", title: "Frame rate", unit: "fps", budget: 55, budgetKind: "atLeast" },
  { id: "threads", title: "Threads", unit: "" },
  { id: "resident-memory", title: "Resident memory", unit: "MB" },
  { id: "compressed-memory", title: "Compressed memory", unit: "MB" },
];

const bases: Record<string, number> = {
  cpu: 34,
  memory: 148,
  fps: 59,
  threads: 28,
  "resident-memory": 121,
  "compressed-memory": 19,
};

function samples(metricID: string) {
  const base = bases[metricID] ?? 0;
  return Array.from({ length: 60 }, (_, index) => ({
    at: Date.now() - (59 - index) * 5000,
    value: base + Math.sin(index / 5) * Math.max(base * 0.08, 1),
  }));
}

function reply(message: { type: string; operationID?: string }) {
  switch (message.type) {
    case "context":
      return {
        ok: true as const,
        value: {
          protocolVersion: 1,
          pluginID: "performance-monitor",
          pluginVersion: "0.2.0",
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
    case "unsubscribe":
      return { ok: true as const, value: null };
    case "subscribe":
      return { ok: true as const, value: "mock-performance" };
    case "invoke":
      if (message.operationID === "performance.metrics") {
        return { ok: true as const, value: { metrics } };
      }
      if (message.operationID === "performance.snapshot") {
        return {
          ok: true as const,
          value: {
            snapshot: {
              cpu: 34,
              memoryMB: 148,
              fps: 59,
              threads: 28,
              residentMemoryMB: 121,
              compressedMemoryMB: 19,
              thermalState: "nominal",
              timestamp: Date.now(),
            },
          },
        };
      }
      if (message.operationID === "performance.series") {
        return {
          ok: true as const,
          value: {
            series: metrics.map((metric) => {
              const readings = samples(metric.id);
              return {
                metricID: metric.id,
                samples: readings,
                latest: readings[readings.length - 1]!.value,
                isOverBudget: false,
              };
            }),
          },
        };
      }
      if (message.operationID === "performance.memory") {
        return {
          ok: true as const,
          value: {
            memory: {
              available: true,
              physicalFootprintMB: 148,
              residentSizeMB: 121,
              virtualSizeMB: 2048,
              compressedMB: 19,
            },
          },
        };
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
