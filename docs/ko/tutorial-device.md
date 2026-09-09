# 2부 — 첫 디바이스 플러그인

[1부](tutorial-desktop.md)에서는 플러그인이 온전히 Mac에서 실행됐어요. 이번
플러그인은 앱 안에 실려요. 디바이스 플러그인은 구현과 웹 패널을 함께 담은
Swift 패키지 하나예요. 앱이 패키지를 링크하고 플러그인을 등록하면 앱이
연결되어 있는 동안 패널이 Necto에 나타나요. Mac 쪽에는 아무것도 설치되지
않아요 — 두 종류의 차이는 [plugin-manifest.md](plugin-manifest.md)가 설명해요.

**Uptime**은 앱 실행 시간을 보여 주는 패널이에요.
종류별로 오퍼레이션을 하나씩 구현해요.

- `uptime.get`은 앱이 시작된 시각과 그 뒤로 흐른 초를 한 번 응답해요.
- `uptime.observe`는 패널이 구독하는 동안 1초마다 실행 시간을 스트리밍해요.

[실행 중인 Necto와 예제 앱](install.md), 그리고 패널 빌드를 위한 Node 22.12 이상이
필요해요.

## 패키지

`toss-necto` 체크아웃 옆에 패키지를 만들어요.

```bash
mkdir -p necto-uptime-plugin/Sources/NectoUptimePlugin
mkdir -p necto-uptime-plugin/panel/public necto-uptime-plugin/panel/src
cd necto-uptime-plugin
```

완성된 패키지의 파일 구성이에요.

```text
necto-uptime-plugin/
  Package.swift
  Sources/NectoUptimePlugin/
    UptimePlugin.swift        the implementation
    Panel/                    the built panel — vite writes it here
  panel/                      the panel source
    index.html
    package.json
    vite.config.js
    public/manifest.json
    src/main.js
    src/style.css
```

`Package.swift`

```swift
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "necto-uptime-plugin",
    platforms: [
        .iOS(.v16),
        .macOS(.v14),
    ],
    products: [
        .library(name: "NectoUptimePlugin", targets: ["NectoUptimePlugin"]),
    ],
    dependencies: [
        // The label after `package:` below is this folder's name — adjust both
        // if your checkout is called something else.
        .package(path: "../toss-necto"),
    ],
    targets: [
        .target(
            name: "NectoUptimePlugin",
            dependencies: [
                .product(name: "NectoSDK", package: "toss-necto"),
            ],
            resources: [
                .copy("Panel"),
            ]
        ),
    ]
)
```

`resources: [.copy("Panel")]`로 빌드된 패널을 모듈 리소스에 포함해요.
패널과 구현을 같은 커밋의 같은 패키지로 배포할 수 있어요.
패널 소스를 수정했다면 웹 에셋도 다시 빌드해 함께 커밋해야 해요.

## 계약

매니페스트는 패널이 호출할 수 있는 오퍼레이션을 선언하는 계약이에요.
선언하지 않은 오퍼레이션은 호출할 수 없어요. Mac과 Swift 타입을 공유하지 않고
JSON을 주고받으며 런타임이 입력과 출력을 스키마로 검증해요.
각 필드의 필수 여부와 정의는
[plugin-manifest.md](plugin-manifest.md)에 있어요.

`panel/public/manifest.json`

```json
{
  "schemaVersion": 1,
  "id": "uptime",
  "name": "Uptime",
  "description": "How long the app has been running",
  "version": "1.0.0",
  "author": "You",
  "icon": { "systemName": "clock" },
  "assets": ["index.html", "assets"],
  "allowedOrigins": ["self"],
  "operations": [
    {
      "id": "uptime.get",
      "title": "Read uptime",
      "description": "When the app started, and the seconds since",
      "kind": "once",
      "binding": {
        "name": "necto.device.uptime.get",
        "version": 1
      },
      "inputSchema": { "type": "object", "additionalProperties": false },
      "outputSchema": {
        "type": "object",
        "properties": {
          "startedAt": { "type": "string" },
          "uptimeSeconds": { "type": "number" }
        },
        "required": ["startedAt", "uptimeSeconds"],
        "additionalProperties": true
      },
      "timeoutMs": 3000
    },
    {
      "id": "uptime.observe",
      "title": "Observe uptime",
      "description": "The seconds since launch, once per second",
      "kind": "stream",
      "binding": {
        "name": "necto.device.uptime.observe",
        "version": 1
      },
      "inputSchema": { "type": "object", "additionalProperties": false },
      "outputSchema": {
        "type": "object",
        "properties": {
          "uptimeSeconds": { "type": "number" }
        },
        "required": ["uptimeSeconds"],
        "additionalProperties": true
      },
      "timeoutMs": 0
    }
  ]
}
```

매니페스트의 `id`는 Swift 쪽의 문자열과 같아야 해요. 이 값으로 패널과 프로바이더를
같은 플러그인으로 식별해요. 각 `binding`은 앱이 응답하는 `necto.device.` 브리지를
가리켜요. 디바이스 브리지를 사용하므로 데스크톱 설치는 거부돼요.

출력 스키마는 `additionalProperties`를 열어 두어 나중에 필드를 추가해도
호환성을 유지해요. `binding.version`을 올리는 기준은
[plugin-manifest.md](plugin-manifest.md#when-a-bridge-version-moves)를 참고하세요.

## 디바이스에서 응답하기

[`NectoPluginable`](https://github.com/toss/toss-necto/blob/main/Sources/NectoSDK/NectoPluginable.swift)을
채택하면 `id`와 `register(_:)`를 구현해야 해요. `panel`의 기본값은 `nil`이며
패널을 포함하는 플러그인은 이 프로퍼티로 모듈 리소스의 `Panel` 디렉터리를 지정해요.

`Sources/NectoUptimePlugin/UptimePlugin.swift`

```swift
import Foundation
import NectoModel
import NectoSDK

/// How long the app has been running, asked once or watched live.
public struct UptimePlugin: NectoPluginable {
    public let id = "uptime"

    private let startedAt = Date()

    public var panel: NectoPluginPanel? { NectoPluginPanel(bundle: .module) }

    public init() {}

    public func register(_ necto: NectoHandler) {
        necto.handle("uptime.get") { _ in
            [
                "startedAt": .string(ISO8601DateFormatter().string(from: startedAt)),
                "uptimeSeconds": .number(Date().timeIntervalSince(startedAt)),
            ]
        }

        necto.handle("uptime.observe") { _, out in
            while !Task.isCancelled {
                await out.send(["uptimeSeconds": .number(Date().timeIntervalSince(startedAt))])
                try await Task.sleep(for: .seconds(1))
            }
        }
    }
}
```

핸들러 이름은 `necto.device.`를 기준으로 한 상대 이름이에요. 여기의
`handle("uptime.get")`은 매니페스트의 `necto.device.uptime.get`에 해당하며
패널에서 `necto.device.send("uptime.get")`로 호출해요. 클로저 형태로 종류를 구분해요.
값을 반환하면 한 번 응답하고 `out`을 받으면 클로저가 반환하거나 호출자가 구독을
취소할 때까지 스트리밍해요. 구독을 취소하면 클로저의 태스크도 취소돼 루프가 끝나요.
자세한 내용은
[bridges.md](bridges.md#app-bridges)에 있어요.

페이로드는 `NectoJSONValue`로 전달하고 매니페스트 스키마로 검증해요.
앱과 호스트가 페이로드 타입을 공유하면 버전도 함께 관리해야 하므로 공유 구조체를 쓰지 않아요.

## 패널

패널은 매니페스트의 오퍼레이션 id로 오퍼레이션을 호출하는 웹 페이지예요.
이 예제는 외부 파일을 내려받지 않고 실행하도록 `@necto/bridge`를 vite로 번들링해요.

`panel/package.json`

```json
{
  "name": "uptime-panel",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build"
  },
  "dependencies": {
    "@necto/bridge": "https://github.com/toss/toss-necto/releases/download/0.4.0/necto-bridge-0.4.0.tgz"
  },
  "devDependencies": {
    "vite": "^6.0.0"
  }
}
```

`panel/vite.config.js` — 빌드 결과는 Swift 패키지의 리소스로 들어가고
`public/manifest.json`도 그 옆에 복사돼요.

```js
import { defineConfig } from "vite";

export default defineConfig({
  base: "./",
  build: {
    outDir: "../Sources/NectoUptimePlugin/Panel",
    emptyOutDir: true,
    rollupOptions: {
      output: {
        entryFileNames: "assets/[name].js",
        chunkFileNames: "assets/[name].js",
        assetFileNames: "assets/[name].[ext]",
      },
    },
  },
});
```

`panel/index.html`

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="color-scheme" content="light dark" />
    <title>Uptime</title>
    <link rel="stylesheet" href="./src/style.css" />
  </head>
  <body>
    <div class="necto-app">
      <div class="necto-body">
        <h2 class="necto-section-title">Uptime</h2>
        <div class="necto-toolbar-group">
          <button type="button" class="necto-button" id="refresh">Refresh</button>
        </div>
        <dl class="necto-pairs">
          <div><dt>Started at</dt><dd id="started-at">—</dd></div>
          <div><dt>Uptime</dt><dd id="uptime">Loading…</dd></div>
        </dl>
      </div>
    </div>
    <script type="module" src="./src/main.js"></script>
  </body>
</html>
```

`panel/src/style.css` — 공유 스타일시트 두 개를 임포트하고 하드코딩 없이 토큰을
사용해요. 패널에 별도 테마 코드를 넣지 않아도 창을 따라 다크 모드로 전환돼요.
규칙과 전체 토큰 목록은 [design.md](design.md)에 있어요.

```css
@import "@necto/bridge/theme.css";
@import "@necto/bridge/components.css";

.necto-body {
  padding: var(--necto-space-3);
}
```

`panel/src/main.js` — 쿼리는 `necto.device.send`, 스트림은
`necto.device.subscribe`로 불러요. 호출 지점에서 `device`를 구분하는 것은
연결된 앱이 없을 때 이 호출만 실패할 수 있기 때문이에요.

```js
import { necto, isNectoBridgeError } from "@necto/bridge";

function show(id, text) {
  document.getElementById(id).textContent = text;
}

function describe(error) {
  return isNectoBridgeError(error) ? `${error.code}: ${error.message}` : String(error);
}

async function refresh() {
  try {
    const snapshot = await necto.device.send("uptime.get");
    show("started-at", snapshot.startedAt);
    show("uptime", `${Math.round(snapshot.uptimeSeconds)} s`);
  } catch (error) {
    show("uptime", describe(error));
  }
}

async function main() {
  if (!necto.isAvailable()) {
    show("uptime", "This plugin only works inside Necto");
    return;
  }

  document.getElementById("refresh").addEventListener("click", () => void refresh());

  await refresh();

  try {
    await necto.device.subscribe(
      "uptime.observe",
      {},
      (event) => show("uptime", `${Math.round(event.uptimeSeconds)} s`),
      (error) => show("uptime", describe(error)),
    );
  } catch (error) {
    show("uptime", describe(error));
  }

  // Signal only after every handler is registered; the host buffers events until then.
  await necto.ready();
}

void main();
```

이제 빌드해요.

```bash
cd panel
npm install
npm run build
cd ..
```

이제 `Sources/NectoUptimePlugin/Panel/`에 `manifest.json`, `index.html`,
`assets/`가 담겨요. 패널은 항상 앱보다 먼저 빌드해요. SDK가 등록 시점에
`Panel` 폴더를 읽으므로 먼저 빌드된 앱은 오래된 에셋을 싣거나 아무것도 싣지
못해요.

## 앱에 싣기

앱에 패키지를 추가하는 것을 디바이스 플러그인의 설치 동의로 봐요.
Mac에서 별도의 설치 다이얼로그를 띄우지 않아요.

1. `toss-necto` 체크아웃에서 `Necto.xcodeproj`를 열어요.
2. File ▸ Add Package Dependencies… ▸ Add Local…에서 `necto-uptime-plugin`을
   선택해요.
3. `ExampleApp` 타깃의 General ▸ Frameworks, Libraries, and Embedded Content에
   `NectoUptimePlugin`을 추가해요.

그다음 `ExampleApp/ExampleApp.swift`에서 `NectoSDK.start()` 앞 아무 곳에나
등록해요.

```swift
import NectoUptimePlugin
```

```swift
NectoSDK.register(UptimePlugin())
```

[verification.md](verification.md)의 시뮬레이터 루프로 실행해요.

```bash
xcrun simctl list devices available          # pick a device id
xcrun simctl boot <device-id>
xcodebuild -project Necto.xcodeproj -scheme ExampleApp -destination "id=<device-id>" build
xcrun simctl install <device-id> Build/Products/Debug-iphonesimulator/ExampleApp.app
xcrun simctl launch <device-id> im.toss.necto.example
```

Necto가 실행 중이면(`open Build/Products/Debug/Necto.app`) 몇 초 안에
사이드바에 앱과 **Uptime**이 나타나요. 패널을 열면 실행 시간이 1초마다 갱신되고
Refresh를 누르면 다시 조회해요. 패널은 연결된 앱에서 가져오므로 Mac에 별도로
설치하지 않아요. 앱 연결이 끊기면 패널이 회색으로 바뀌어요.

<a id="기여자처럼-검증하기"></a>

## 플러그인 검증하기

[verification.md](verification.md)의 체크 중 여기에 해당하는 것들이에요.

- **순서가 중요해요.** 패널 먼저(`npm run build`), 그다음 앱이에요. 플러그인
  결과물이 패키지 안에 실리므로 패널보다 먼저 빌드된 앱은 오래된 에셋을
  실어요. 그리고 지금 살펴보는 시뮬레이터에 앱을 다시 설치해요. 부팅된 다른
  시뮬레이터를 대상으로 빌드하면 그쪽 결과물만 갱신되고 패널을 제공 중인 앱은
  그대로예요.
- **앱에서도 확인해요.** 브리지와 창이 적용하는 테마는 실제 호스트에서 확인해야 해요.
  `npm run dev`로는 레이아웃을 확인해요. 브리지가 없어 페이지에 폴백 문구가 표시돼요.
- **패널을 열어 둔 채 시스템 설정에서 라이트와 다크를 전환해 보세요.** 패널이
  토큰에서 색을 가져오므로 리로드 없이 따라와요.
- **일부러 계약을 깨 보세요.** 스키마가 number라고 말하는 자리에 `.string`을
  반환하면 호출이 패널에 도달하기 전에 `INVALID_OUTPUT`으로 실패해요.
  런타임은 스키마와 다른 출력을 거부해요.
- **USB 경로는 시뮬레이터에서 검증할 수 없어요.** 시뮬레이터는 루프백을 써요.
  USB로 실기기를 연결해 실행해 보고 검증하지 못했다면 그 범위를 알려 주세요.

플러그인을 기여하거나 브리지를 바꿀 때는
[harness.md](harness.md)의 규칙과 검증 방법을 확인하세요.

## 다음으로

- [plugin-manifest.md](plugin-manifest.md) — 매니페스트 전체 레퍼런스예요.
  버전 축, 에러 코드, 각 플러그인 종류가 할 수 있는 일을 다뤄요.
- [bridges.md](bridges.md) — 데스크톱 브리지를 포함한 전체 브리지 목록이에요.
- [harness.md](harness.md) — 플러그인 구현 규칙과 목 호스트로 패널을 검증하는 방법이에요.
- [setup.md](setup.md) — 내 앱에 플러그인을 연결하고 Release 빌드에서 SDK 호출을
  제외하는 방법이에요.
- [CONTRIBUTING.md](https://github.com/toss/toss-necto/blob/main/CONTRIBUTING-ko.md) — 플러그인을 기여하는 방법이에요.
