# Setting up Necto in an app

Necto's SDK is a debug tool that compiles into your app. This page covers integrating
the SDK and excluding its calls from production builds. Install the Mac app separately
using [install.md](install.md).

## Wiring it up

Add `https://github.com/toss/necto.git` in Xcode's Package Dependencies.
Select the `NectoSDK` product for your app target. It includes the SDK and built-in
plugin modules; keep the imports for the modules you use, as shown below.
Register the plugins once during app startup, then start the SDK:

```swift
import NectoDefaultPlugins
import NectoProcessMetrics
import NectoSDK
import NectoURLSessionCapture

#if DEBUG
let events = NectoEventsPlugin()
NectoSDK.register(URLSessionNetworkPlugin())   // network, captured for you
NectoSDK.register(events)
NectoSDK.register(ProcessPerformancePlugin())  // six process metrics while observed
NectoSDK.register(NectoUIControlPlugin())
NectoSDK.start()
events.report(NectoEvent(level: .info, tag: "App", message: "App started"))
#endif
```

Register only the plugins you need. Adding the package does not register plugins,
start a listener or enable capture. Built-in plugin code and panel resources are
included in the product even if you do not register them.
Your own plugins register the same way; their panels appear
in Necto when the app connects. See [the device plugin tutorial](tutorial-device.md)
for a complete implementation.

### Updating existing dependencies

If your app or plugin package explicitly depends on `NectoDefaultPlugins`,
`NectoProcessMetrics`, `NectoURLSessionCapture`, `NectoModel` or `NectoTransport`
products, replace those product dependencies with `NectoSDK`. In a `Package.swift`:

```swift
.product(name: "NectoSDK", package: "necto")
```

The module names, imports and registration APIs are unchanged. This is a package
configuration change: manifests referencing the old products must be updated before
adopting the new version. Mac host products now live in the local `NectoMac` package and
are not part of the SDK.

## Keeping it away from users

Do not run debugging tools in builds distributed to users.

> Wrap every Necto call in `#if DEBUG`.

Calls inside `#if DEBUG` are excluded when `DEBUG` is not defined. Check that your
Release build settings do not define `DEBUG`.

`NectoSDK.start()` starts the listener. However, `URLSessionNetworkPlugin` starts
capture when registered, so guard plugin creation and registration as well as `start()`.

Excluding calls does not guarantee removal of all package code and resources.
What remains depends on linking and build settings such as dead-code stripping.
If complete exclusion is required, use a separate distribution target without Necto
dependencies and inspect the actual Release output for remaining code and resources.
`EXCLUDED_SOURCE_FILE_NAMES` alone does not exclude Swift package sources.

## What connecting involves

Internal apps can require a provisioned Mac key with `NectoSDK.start(publicKey:)`.
See [optional connection authentication](connection-security.md) for setup, TLS,
compatibility, and security boundaries.

- **Simulator**: the Mac reaches the app over loopback.
- **Device**: over the USB cable, through `usbmuxd`.
- The SDK listens on a local TCP port. If another simulator app holds it, the SDK
  looks for a free port within its port range. Necto does not use Bonjour or multicast.
- Two apps, or the same app on two devices, connect side by side and are told
  apart in the sidebar and in `necto-cli` (`--app`, `--device`).

## Where to start

Start with `URLSessionNetworkPlugin` and `NectoEventsPlugin`. Network requests appear
as they happen. Keep the registered `events` instance in your app's debug logging code
and call `events.report(...)` to send log entries, as in the example above. Guard these
calls with `#if DEBUG` too. Add other plugins for the data you need to inspect.
