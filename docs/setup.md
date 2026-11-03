# Setting up Necto in an app

Necto's SDK is a debug tool that compiles into your app. This page covers integrating
the SDK and excluding its calls from production builds. Install the Mac app separately
using [install.md](install.md).

Use Necto only with trusted apps and runtime environments, including development
devices and networks. The SDK connection has no peer
authentication or TLS: USB and loopback do not prevent other apps on the device or
programs on the Mac from connecting. Do not expose or forward its ports to untrusted
networks.

## Wiring it up

Add `https://github.com/toss/necto.git` in Xcode's Package Dependencies.
Select `NectoSDK` and only the plugin products you need. The example below also
uses `NectoEventsPlugin`, `NectoProcessMetricPlugin`, `NectoURLSessionCapturePlugin`
and `NectoUIControlPlugin`. Automatic capture and UI Control use private APIs;
omit those two products in apps that prohibit private APIs.

```swift
import NectoEventsPlugin
import NectoUIControlPlugin
import NectoProcessMetricPlugin
import NectoSDK
import NectoURLSessionCapturePlugin

let events = NectoEventsPlugin()
NectoSDK.register(URLSessionNetworkPlugin())   // network, captured for you
NectoSDK.register(events)
NectoSDK.register(ProcessPerformancePlugin())  // six process metrics while observed
NectoSDK.register(NectoUIControlPlugin())
NectoSDK.start()
events.report(NectoEvent(level: .info, tag: "App", message: "App started"))
```

Register only the plugins you need. Adding the package does not register plugins,
start a listener or enable capture. Each selected plugin carries only its own code
and panel resources, plus its declared dependencies.
Your own plugins register the same way; their panels appear
in Necto when the app connects. See [the device plugin tutorial](tutorial-device.md)
for a complete implementation.

### Choosing products

| Product / import | Purpose | Private APIs |
| --- | --- | --- |
| `NectoSDK` | Connection and plugin registration | No |
| `NectoNetworkPlugin` | Report requests from your own networking hooks | No |
| `NectoEventsPlugin` | Application events | No |
| `NectoFilesPlugin` | Files | No |
| `NectoPreferencesPlugin` | Preferences | No |
| `NectoPerformancePlugin` | Report performance readings | No |
| `NectoProcessMetricPlugin` | Automatic process metrics | No |
| `NectoUIControlPlugin` | UI inspection and interaction | Yes |
| `NectoURLSessionCapturePlugin` | Automatic URLSession recording | Yes |

Apps previously using only `NectoSDK` must explicitly add the products they use.
Replace `import NectoDefaultPlugins` with imports for the individual plugins above.
Rename `NectoProcessMetrics` and `NectoURLSessionCapture` imports to
`NectoProcessMetricPlugin` and `NectoURLSessionCapturePlugin`.
Registration methods and plugin type names are unchanged.

```swift
.product(name: "NectoSDK", package: "necto"),
.product(name: "NectoNetworkPlugin", package: "necto"),
.product(name: "NectoEventsPlugin", package: "necto")
```

## Keeping it away from users

Do not run debugging tools in builds distributed to users.

The SDK does not restrict capture to a build configuration. The app decides where
to include the products and when to register plugins and start the SDK, including
internal Release builds.

The built-in UI Control provider synthesizes touches using private UIKit and
IOHID entry points. Its Swift implementation lives in `NectoUIControlPlugin` and
resolves selectors and C functions at runtime instead of linking Objective-C
private method declarations. It supports positioned taps, 1–5 simultaneous fingers,
1–3 successive taps, swipes, and edge-back gestures. Native controls and text inputs
are discovered through public UIKit properties. SwiftUI support additionally enables
application accessibility through `_AXSApplicationAccessibilitySetEnabled` and
routes each touch through `_UIHitTestContext`, `_hitTestWithContext:` and
`_setResponder:`. These use the same runtime symbol resolver; there is no separate
`libAccessibility.dylib` load or `_accessibilityInit` call. If these runtime entry
points are missing, SwiftUI target discovery or touch delivery may be unavailable.
Runtime lookup does not make these APIs public.
Missing required touch entry points return `OPERATION_UNAVAILABLE`. OS changes can still
break the implementation, and Swift cannot catch Objective-C exceptions.

Runtime lookup is not a guarantee of App Store Connect or TestFlight acceptance.
Inspect the final app and embedded frameworks, and keep the debugging tool out of
builds distributed to users.

Registering `URLSessionNetworkPlugin` starts network capture.
Calling `NectoSDK.start()` lets you view the captured requests in the Necto app on your Mac.

Excluding calls does not guarantee removal of all package code and resources.
What remains depends on linking and build settings such as dead-code stripping.
If complete exclusion is required, use a separate distribution target without Necto
dependencies and inspect the actual Release output for remaining code and resources.
`EXCLUDED_SOURCE_FILE_NAMES` alone does not exclude Swift package sources.

## What connecting involves

- **Simulator**: the Mac reaches the app over loopback.
- **Device**: over the USB cable, through `usbmuxd`.
- The SDK listens on a local TCP port. If another simulator app holds it, the SDK
  looks for a free port within its port range. Necto does not use Bonjour or multicast.
- Two apps, or the same app on two devices, connect side by side and are told
  apart in the sidebar and in `necto-cli` (`--app`, `--device`).

## Where to start

Start with `URLSessionNetworkPlugin` and `NectoEventsPlugin`. Network requests appear
as they happen. Keep the registered `events` instance in your app's debug logging code
and call `events.report(...)` to send log entries, as in the example above. Add other
plugins for the data you need to inspect.

### Which requests are captured

Add `NectoURLSessionCapturePlugin` and register `URLSessionNetworkPlugin()`
to automatically record HTTP(S) requests from `URLSession.shared` and sessions the
app creates. Keep normal `URLSession` construction and request calls. No factory,
wrapper or session protocol is required. Remove any old `protocolClass` registration;
the compatibility protocol remains available but never intercepts a request.

Like PulseProxy, capture observes the original session through runtime hooks. It
never reissues a request or replaces the application's configuration or delegates.
Foundation and the app continue to handle credentials, cookies, authentication
challenges and redirects. Use the public-API-only `NectoNetworkPlugin` for manual logging.

- Capture works in both Debug and Release when installed. To exclude its private
  APIs, omit `NectoURLSessionCapturePlugin` from the app target dependencies.
- Private Foundation classes and methods are involved. OS changes and other
  SDK hooks can affect capture. Presence and signature checks do not guarantee future compatibility.
- Data, upload, download and streaming requests are recorded with bounded body previews.
  Application body streams are never consumed; streamed uploads may have no request preview.
- WebSocket messages and background transfers running in another process are unsupported.
- `uninstall()` stops recording. Hooks remain as pass-throughs instead of restoring
  old implementations over hooks installed by another SDK.

Reference implementations: [PulseProxy](https://github.com/kean/Pulse/blob/main/Sources/PulseProxy/URLSessionSwizzler.swift)
and [Atlantis Network.framework loader support](https://github.com/ProxymanApp/atlantis/blob/main/Sources/NetworkInjector%2BNWURLSession.swift).
