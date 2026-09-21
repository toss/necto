# UI Control fixture

Register `NectoUIControlPlugin()` to discover actionable elements, read accessibility
content, and send input. UIKit and SwiftUI examples live in the **Control** and
**Accessibility** tabs. No launch flag is required.

## Contract

- `control.actionTargets` returns visible targets with opaque `id`, `role`, `frame`,
  and `actions`. Filter by `query` to match a label, app identifier, or role.
- `control.readAccessibility` returns flat read-only content, including labels that
  cannot be acted on. This is neither a view tree nor a stable screen identity.
- `control.tap` takes `targetID`, optional `touchCount` (1–5 fingers), and
  `tapCount` (1–3 successive taps). Both default to 1. Contacts are spread around
  the visible center and delivered simultaneously. `tapGestures` on a target
  lists observed native recognizer configurations; it is not exhaustive for
  other gesture systems such as SwiftUI.
- `control.input` takes `targetID`, `text`, and optional `mode`: `replace` (default)
  or `append`. It taps to focus, then uses the platform text-input interface.
- `control.swipe` takes `targetID`, `direction` (`up`, `down`, `left`, `right`),
  optional `distanceRatio` (0.1–0.9, default 0.6), and `durationMs` (100–2000,
  default 400). Direction means finger movement; swipe up to reveal content below.
- Tap and swipe accept optional `position: {"x": 0.25, "y": 0.75}` relative to
  the target's visible frame (0–1, left to right and top to bottom). For tap it is
  the contact center; for swipe it is the start. Use the screen target for
  screen-relative coordinates. Exact edges are inset by half a point. A positioned
  swipe travels `distanceRatio` of the visible target dimension and is clipped at
  its boundary; no available movement is an error. Multiple fingers must fit around
  the specified position. Omit position for the existing centered gesture geometry.
- `control.back` takes a screen `targetID`. On iOS it sends a left-edge swipe to
  the right. It does not force a navigation pop or dismiss a sheet.

Refresh targets after every attempt or UI change. A stale, moved, or covered target
is refused. Identifiers and labels can be duplicated; resolve exactly one current
result and pass its opaque `id`, never the app-assigned `identifier`.

For example, send two simultaneous fingers twice through the same CLI contract:

```bash
necto plugin send control control.tap --device <device-id> --app <bundle-id> \
  --input '{"targetID":"<fresh-id>","touchCount":2,"tapCount":2}'
```

Actions return `dispatched`, `method`, and `contentChanged`. Dispatch only means the
input was delivered. `contentChanged` compares exposed accessibility content before
and shortly after the input; it is not a navigation assertion, an animation-idle
signal, or proof that an expected destination appeared. Read the expected text or
value after acting. Do not automatically retry a dispatched action.

## iOS implementation

Accessibility containers supply semantic targets; UIView traversal bridges missing
containers and locates native scroll areas and editors. Plain labels and disabled
controls are excluded. An accessibility-enabled UIView with an enabled
`UITapGestureRecognizer` is also actionable. View classes and hierarchy metadata
are not exposed by this contract.

The plugin links its private touch implementation, `NectoTouchInjection`, on iOS.
Before discovery, it initializes accessibility data for the current process so
standard controls and SwiftUI elements are available without an accessibility
inspector or assistive technology already running. It does not change device-wide
accessibility settings.
It resolves SwiftUI gesture responders in addition to the hit UIView. Consumers do
not need a separate debug module or feature flag. Text entry uses `UITextInput`
and `UIKeyInput`, not `accessibilityValue` assignment. Secure values are omitted
from both target and content responses before filtering.

Custom editors without this input interface and custom gestures without exposed
semantics may not be discoverable. A screen target provides a general swipe surface.
Edge-back can be ignored at the root or when interactive navigation is disabled.
Private input API availability varies by OS. Unsupported operations return an error.

## Reproducing the checks

Build the Control panel before ExampleApp so its carried manifest is current:

```bash
yarn workspace @necto-plugin/control build
```

Build, install, and freshly launch ExampleApp with a dedicated bundle identifier,
such as `im.toss.necto.example.interaction-poc`. With Necto running, discover the
device using `necto device list --json`, then run:

```bash
node script/tests/control-e2e.mjs <device-id> im.toss.necto.example.interaction-poc
```

The script operates only on a dedicated ExampleApp bundle. It verifies SwiftUI and
UIKit taps, navigation, Unicode replace/append/clear, secure-value omission,
accessible tap gestures (all 15 finger/count combinations), scrolling, edge-back, stale IDs, and covered-background
exclusion. It requires fresh fixture state and leaves the Accessibility sheet open.
`NECTO_CLI` may select a development CLI executable.

The [input comparison](input-comparison.md) records the earlier AX-only experiment
and the open-source implementations that informed the SwiftUI responder correction.

## Latest local verification

On iPhone 17 Simulator, iOS 26.2, the CLI regression scenarios passed against the
normal ExampleApp build, without Loupe injection or diagnostic launch flags.
The 15 combinations of 1–5 fingers and 1–3 taps passed with and without Loupe
injection. Swift package, CLI contract, web typecheck/tests, and panel asset checks
passed. The desktop panel was also exercised in Necto: two-finger double tap
updated the fixture, and tap/swipe settings remained unchanged after dispatch.

The same CLI scenarios passed on iPhone 15 Pro running iOS 27.0, including all
15 multi-tap combinations, target-relative and screen-relative taps, and a swipe
with an explicit start position. The first physical run exposed missing process
accessibility initialization; discovery now initializes it before reading elements.
Other device and OS combinations remain unverified.
