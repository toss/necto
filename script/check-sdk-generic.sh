#!/bin/bash
#
#  Copyright (c) 2026 Viva Republica, Inc.
#
# Enforces the harness rules that keep NectoSDK a bridge. See docs/harness.md.

set -uo pipefail
cd "$(dirname "$0")/.."

status=0

fail() {
    echo "FAIL: $1"
    status=1
}

# Rule 1: the SDK carries messages and knows no feature.
#
# The names are the ones a feature would arrive under. A new standard contract adds a
# module, never a mention here.
features="URLProtocol|URLSession|NetworkRecord|networkRecord|ViewInspector|NectoLayout|FeatureFlag|Tuba|Toss"
if rg -q "$features" Sources/NectoSDK/ 2>/dev/null; then
    fail "NectoSDK names a feature. Put it in its own module and register it as an NectoPlugin."
    rg -n "$features" Sources/NectoSDK/
fi

# The SDK may only depend on the model and the transport. Anything else is a feature
# reaching in.
sdk_imports=$(rg --no-filename "^import " Sources/NectoSDK/ | sort -u | grep -v "^import Foundation$" | grep -v "^import UIKit$")
allowed=$'import NectoModel\nimport NectoTransport'
if [ "$sdk_imports" != "$allowed" ]; then
    fail "NectoSDK imports something other than NectoModel and NectoTransport:"
    echo "$sdk_imports"
fi

# Rule 2: a plugin never links its own capture mechanism, or the choice stops being
# the app's. The dependency runs the other way: the capture imports the plugin.
if rg -q "import NectoURLSessionCapture" Sources/NectoDefaultPlugins/ 2>/dev/null; then
    fail "NectoDefaultPlugins imports NectoURLSessionCapture. A plugin must not pull in a capture mechanism."
fi

# Rule 3: a manifest is the contract. `{"type": "object"}` passes validation and tells
# a caller nothing, which is worse than no schema at all — it looks like one.
empty=$(rg -l '"(input|output)Schema": \{\s*"type": "object"\s*\}' --multiline WebPackages/BuiltInPlugins/src/*/public/manifest.json 2>/dev/null)
if [ -n "$empty" ]; then
    fail "A manifest declares a schema with no properties. Say what the operation takes and returns:"
    echo "$empty"
fi

# Rule 1 again, at the wire: message kinds stay generic.
if rg -q 'case [a-z]+ = "(network|view|flag|log)\.' Sources/NectoModel/NectoEnvelope.swift 2>/dev/null; then
    fail "NectoEnvelope declares a feature-specific message kind. Features travel inside plugin.event or plugin.invoke."
fi

# Rule 5: Bonjour is out; USB and loopback are the paths.
if rg -q "NetService|NWBrowser|bonjour|_necto\._tcp" Sources/ NectoMac/Sources/ Necto/ ExampleApp/ 2>/dev/null; then
    fail "Bonjour discovery found. USB through usbmuxd, plus loopback for the simulator, is the connection."
    rg -n "NetService|NWBrowser|bonjour|_necto\._tcp" Sources/ NectoMac/Sources/ Necto/ ExampleApp/
fi

if [ $status -eq 0 ]; then
    echo "OK: NectoSDK is generic, interfaces are unbound, no Bonjour."
fi
exit $status
