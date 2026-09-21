//
//  Copyright (c) 2026 Viva Republica, Inc.
//

const counter = { id: "counter", role: "button", label: "Count: 0", frame: [16, 146, 370, 34], actions: ["tap"] };
const elements = [
  { id: "screen", role: "screen", label: "Screen", frame: [0, 0, 402, 874], actions: ["tap", "swipe", "back"] },
  { id: "scroll", role: "scrollArea", label: "Example scroll area", frame: [16, 146, 370, 694], actions: ["swipe"] },
  counter,
  { id: "query", role: "textInput", label: "Query", frame: [16, 190, 370, 40], actions: ["tap", "input"],
    ...{ tapGestures: [{ touchCount: 2, tapCount: 1 }, { touchCount: 1, tapCount: 1 }] } },
  { id: "nav", role: "button", label: "Open a detail screen with a deliberately long title", frame: [275, 76, 107, 36], actions: ["tap"] },
];
elements.push({ id: "multi-tap", role: "button", label: "Two-finger double tap", frame: [16, 250, 370, 40],
  actions: ["tap"], ...{ tapGestures: [{ touchCount: 2, tapCount: 2 }] } });
let taps = 0;
function reply(message: { type: string; operationID?: string; input?: Record<string, unknown> }) {
  const ok = (value: unknown) => ({ ok: true as const, value });
  if (message.type === "context") return ok({ protocolVersion: 1, pluginID: "control", pluginVersion: "0.1.0",
    sourceIdentity: "mock", operations: [], target: { targetHandle: "mock", appBundleID: "com.example.app", appName: "ExampleApp" } });
  if (message.type === "ready") return ok(null);
  if (message.type === "invoke") {
    if (message.operationID === "control.actionTargets") return ok({ targets: elements });
    if (message.operationID === "control.readAccessibility") return ok({ items: [
      { role: "heading", label: "Control Example" },
      { role: "text", label: "Read-only label (not a button)" },
      { role: "text", label: "This is a long accessibility label that wraps without hiding the screen content the user needs to read." },
      ...elements.filter((element) => element.role !== "screen").map((element) => ({
        role: element.role, label: element.label,
        identifier: "identifier" in element ? element.identifier : undefined,
        value: "value" in element ? element.value : undefined,
        isSecure: "isSecure" in element ? element.isSecure : undefined,
      })),
    ] });
    const target = elements.find((element) => element.id === message.input?.targetID);
    const action = message.operationID?.split(".")[1];
    if (target && action && target.actions.includes(action)) {
      if (action === "tap" && target.id === counter.id) counter.label = `Count: ${++taps}`;
      return ok({ dispatched: true, method: "touch", contentChanged: target.id === counter.id });
    }
  }
  return { ok: false as const, error: { code: "OPERATION_NOT_FOUND", message: "No matching mock operation" } };
}

export function installMockBridge(): void {
  const target = window as unknown as {
    webkit?: { messageHandlers?: Record<string, { postMessage(message: unknown): Promise<unknown> }> };
  };
  target.webkit = { messageHandlers: { necto: { postMessage: async (message) =>
    reply(message as Parameters<typeof reply>[0]),
  } } };
}
