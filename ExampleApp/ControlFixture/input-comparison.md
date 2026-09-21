# Accessibility and synthetic input comparison

## Scope

Local POC on iPhone 17 Simulator, iOS 26.2, using ExampleApp's ordinary SwiftUI
Accessibility fixture. No Loupe runtime was injected during the input checks.
No physical-device, additional OS, text-entry, or edge-back verification is claimed.

At the time of this comparison, the normal Control runtime was the accessibility-only
POC. A temporary build linked `NectoTouchInjection` and explicitly selected AX or
synthetic execution. The diagnostic switch, passive observer, and file logging were
removed afterwards. The follow-up implementation now links the corrected input
module; see [the current contract](README.md).

## Results

| Case | Public AX handler | Original synthetic touch | Synthetic touch with resolved responder |
| --- | --- | --- | --- |
| Native tab-bar selection | Returned false; stayed on Connection | Opened Accessibility | Opened Accessibility |
| SwiftUI Count tap | Counter incremented | Counter stayed at zero | Counter changed from 0 to 1 |
| SwiftUI Open detail | Opened detail | Not measured in this comparison | Accessibility Detail appeared |
| Ordinary SwiftUI ScrollView | Returned false; visible rows unchanged | Pan recognized and content moved | Pan recognized and content moved |

For the unsuccessful original button tap, the visible accessibility frame was
`x: 16, y: 220.33, width: 75.33, height: 20.33`. The test used its center. The
ordinary hit test resolved to SwiftUI's `PlatformGroupContainer`. A passive window
gesture observer received began/ended events in the stable repeat, but the counter
remained zero. This distinguishes event dispatch from successful button execution.

With the same target frame, the context hit test returned
`SwiftUI.ViewResponderGestureContainer`. Assigning it through `_setResponder:`
made the counter increment and allowed navigation. The fix changes input routing,
not target coordinates or the fixture's button implementation.

For scrolling, the instrumented run received began, 23 moved events, and ended.
The scroll view's pan recognizer transitioned through began/changed/ended. Its
vertical content offset changed from `-168` to approximately `856`; visible rows
advanced from the beginning to around Row 16. This value is an observation after a
one-second wait, not an exact distance guarantee or a guarantee that inertia ended.

The corrected tab, button, and scroll checks were repeated with the passive
observer disabled. The button again changed from 0 to 1 and scroll offset changed
from `-168` to approximately `848`. The observer is not required for success.

## Relevant open-source implementations

### KIF

Reviewed commit `38a04eb8f501c5bce21916f6a47705193e681ef4`.

[`UITouch-KIFAdditions.m`](https://github.com/kif-framework/KIF/blob/38a04eb8f501c5bce21916f6a47705193e681ef4/Sources/KIF/Additions/UITouch-KIFAdditions.m#L133)
uses `_UIHitTestContext` and `_hitTestWithContext:` on iOS 18 and later to resolve
a SwiftUI responder that may differ from the ordinary hit UIView. Its initializer
assigns that result to the synthetic touch. This is a closer reference for an
in-app plugin than an external device automation runner.

### EarlGrey 2

Reviewed the `earlgrey2` branch at commit
`a49a21c651221754d1514edb6f9f88249f6b11b7`, not the deprecated master/EarlGrey 1 branch.

[`GREYTouchInjector.m`](https://github.com/google/EarlGrey/blob/a49a21c651221754d1514edb6f9f88249f6b11b7/AppFramework/Event/GREYTouchInjector.m#L219)
resolves a SwiftUI gesture responder using `_UIHitTestContext` and an accessibility
container walk, then assigns it using `UITouch._setResponder:`. It also contains
version-specific handling. This supports testing responder routing explicitly;
it does not establish universal compatibility for Necto's implementation.

The Necto experiment uses the existing hit UIView and its ancestors to resolve
the responder, while retaining the existing view assignment. No KIF or EarlGrey
dependency was added.

### Appium WebDriverAgent

Reviewed commit `3e8aa7de81f254dbb0876baa9e9173c16b55b3a0`.

[`XCUIElement+FBScrolling.m`](https://github.com/appium/WebDriverAgent/blob/3e8aa7de81f254dbb0876baa9e9173c16b55b3a0/WebDriverAgentLib/Categories/XCUIElement%2BFBScrolling.m#L388)
creates XCTest coordinates and invokes `pressForDuration:thenDragToCoordinate:`.
Its [runner setup](https://github.com/appium/WebDriverAgent/blob/3e8aa7de81f254dbb0876baa9e9173c16b55b3a0/README.md)
requires starting WebDriverAgentRunner. It supports real devices, but represents a
separate XCTest automation architecture rather than code that can simply replace
an in-app plugin's public accessibility calls.

## Interpretation

The failures have different causes. Public AX methods did not implement the
requested stock tab/scroll behavior on this fixture. The original synthetic path
could drive those controls, but lost SwiftUI button gesture routing. Resolving the
actual gesture responder corrected that reproduced failure.

This makes accessibility discovery plus responder-aware synthetic input a viable
candidate for Necto, not a completed compatibility guarantee. Keep target discovery,
input delivery, and observed UI outcome distinct. Continue with physical-device
validation and representative nested scroll, overlay, and custom-gesture cases
before replacing the normal Control execution contract.
