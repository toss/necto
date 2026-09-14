# 1부 — 첫 데스크톱 플러그인

웹 페이지와 `manifest.json`으로 플러그인을 만들어 Necto에 설치해요.
iOS 앱, Swift, Xcode는 필요 없어요. 각 단계의 코드 블록은 완성된 파일이므로
순서대로 복사해 실행할 수 있어요.

## 무엇을 만드나요

**Who Is Connected**는 Necto 버전과 앱 목록을 실시간 테이블로 보여 주는 패널이에요.
시뮬레이터와 USB 실기기에서 연결되거나 발견된 앱을 모두 표시해요.
Mac이 가진 정보만 사용하므로 `necto.desktop.*`에 바인딩하고 Necto에 직접 설치하는
*데스크톱* 플러그인이에요. *디바이스* 플러그인은 `necto.device.*`에 바인딩하며
디버깅 대상 앱에 포함돼요. 두 종류의 차이는 [plugin-manifest.md](plugin-manifest.md),
사용 가능한 브리지는 [bridges.md](bridges.md)를 참고하세요.

Node 22.12 이상과 빌드된 [Necto 앱](https://github.com/toss/necto#getting-started)이 필요해요.

## 폴더 구성

플러그인 파일을 담을 폴더를 만들어요.

```bash
mkdir who-is-connected && cd who-is-connected
mkdir public src
```

`package.json` — 브리지 클라이언트와 번들러예요.

```json
{
  "name": "who-is-connected",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "vite build"
  },
  "dependencies": {
    "@necto/bridge": "https://github.com/toss/necto/releases/download/0.1.0/necto-bridge-0.1.0.tgz"
  },
  "devDependencies": {
    "vite": "^6.0.0"
  }
}
```

`vite.config.js` — 패널은 도메인이 아니라 폴더에서 서빙되므로 상대 경로를
써요. `manifest.json`은 `public/`에 두어 빌드가 `index.html` 옆으로 복사하게
해요.

```js
import { defineConfig } from "vite";

export default defineConfig({
  base: "./",
  build: {
    outDir: "dist",
  },
});
```

`public/manifest.json`이 계약이에요. 플러그인이 호출할 수 있는 오퍼레이션을
선언하고 여기에 선언하지 않은 것은 런타임이 연결하지 않아요.

```json
{
  "schemaVersion": 1,
  "id": "who-is-connected",
  "name": "Who Is Connected",
  "description": "Every app Necto can see, as it changes",
  "version": "1.0.0",
  "author": "You",
  "icon": { "systemName": "dot.radiowaves.left.and.right" },
  "assets": ["index.html", "assets"],
  "allowedOrigins": ["self"],
  "operations": [
    {
      "id": "host.info",
      "title": "Host info",
      "description": "Reads the Necto version and protocol version",
      "kind": "once",
      "binding": { "name": "necto.desktop.info", "version": 1 },
      "inputSchema": {
        "type": "object",
        "properties": {},
        "additionalProperties": false
      },
      "outputSchema": {
        "type": "object",
        "properties": {
          "nectoVersion": { "type": "string" },
          "protocolVersion": { "type": "number" }
        },
        "required": ["nectoVersion", "protocolVersion"],
        "additionalProperties": true
      },
      "timeoutMs": 3000
    },
    {
      "id": "targets.observe",
      "title": "Observe targets",
      "description": "Receives the full target list whenever it changes",
      "kind": "stream",
      "binding": { "name": "necto.desktop.targets.observe", "version": 1 },
      "inputSchema": {
        "type": "object",
        "properties": {
          "includeDiscovered": { "type": "boolean" }
        },
        "additionalProperties": false
      },
      "outputSchema": {
        "type": "object",
        "properties": {
          "targets": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "targetHandle": { "type": "string" },
                "name": { "type": "string" },
                "appName": { "type": "string" },
                "appBundleID": { "type": "string" },
                "deviceType": { "type": "string" },
                "isConnected": { "type": "boolean" }
              },
              "required": ["targetHandle", "appName", "appBundleID", "deviceType", "isConnected"],
              "additionalProperties": true
            }
          }
        },
        "required": ["targets"],
        "additionalProperties": true
      },
      "timeoutMs": 0
    }
  ]
}
```

필드별 역할이에요.

- `schemaVersion` — 매니페스트 포맷 버전, `1`이에요.
- `id` — 고유 식별자로 `[A-Za-z0-9._-]+` 형식이에요. 설치되면 폴더 이름이
  되기도 해요.
- `name`, `description`, `version`, `author` — 사이드바와 설치 다이얼로그에
  보이는 정보예요.
- `icon` — SF Symbols 이름이에요. 셸이 사이드바에 그려 줘요.
- `assets` — 패키징할 파일과 디렉터리예요. `assets`는 Vite가 번들을 두는
  곳이에요.
- `allowedOrigins` — 오리진 선언이에요. 여기서는 플러그인 자신의 파일을 뜻하는
  `self`를 사용해요. 현재는 선언 형식만 검증하며 외부 통신을 차단하지 않아요.
- `operations` — 플러그인이 할 수 있는 모든 호출이에요. 각 항목은 JavaScript가
  호출하는 오퍼레이션 id, 응답할 브리지를 지정하는 `binding`,
  `kind`(`once`는 한 번 응답하고 `stream`은 끝날 때까지 이벤트를 전달해요),
  그리고 런타임이 모든 페이로드를 검증하는 JSON 스키마로 이루어져요.

두 바인딩 모두 Mac 앱이 응답하는 `necto.desktop.`으로 시작해요.
디바이스 브리지에 바인딩하면 데스크톱 설치가 거부되는 것을 마지막 섹션에서 확인해요.
세 가지 버전 축과 나머지 포맷은 [plugin-manifest.md](plugin-manifest.md)를 참고하세요.

## 패널 만들기

`index.html` — Necto가 로드하는 페이지예요.

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="color-scheme" content="light dark" />
    <title>Who Is Connected</title>
  </head>
  <body>
    <div class="necto-app">
      <div class="necto-toolbar">
        <span class="necto-badge" id="version">Necto</span>
        <span class="necto-caption" id="count">0 targets</span>
      </div>

      <div class="necto-body">
        <table class="necto-table" id="table" hidden>
          <thead>
            <tr>
              <th>App</th>
              <th>Bundle id</th>
              <th>Device</th>
              <th>State</th>
            </tr>
          </thead>
          <tbody id="rows"></tbody>
        </table>

        <div class="necto-empty" id="empty">
          <p class="necto-empty-title">No targets yet</p>
          <p class="necto-caption">Run an app with the Necto SDK on a simulator or a USB device.</p>
        </div>
      </div>
    </div>

    <script type="module" src="./src/main.js"></script>
  </body>
</html>
```

`src/main.js` — 패널의 동작을 구현해요. Necto의 WebView 안에서 호스트는 WebKit
메시지 핸들러로 응답하며 `@necto/bridge`가 이를 처리해요. 패널은 매니페스트의
오퍼레이션 id로만 호출하고 브리지나 프로바이더 이름을 직접 호출하지 않아요.

```js
import { necto } from "@necto/bridge";
import "./style.css";

const version = document.getElementById("version");
const count = document.getElementById("count");
const table = document.getElementById("table");
const rows = document.getElementById("rows");
const empty = document.getElementById("empty");

function cell(text) {
  const td = document.createElement("td");
  td.textContent = text;
  return td;
}

function stateCell(isConnected) {
  const td = document.createElement("td");
  const mark = document.createElement("span");
  mark.className = isConnected
    ? "necto-status necto-status-ok"
    : "necto-status necto-status-idle";
  mark.textContent = isConnected ? "connected" : "seen";
  td.append(mark);
  return td;
}

function render(targets) {
  rows.replaceChildren();
  for (const target of targets) {
    const row = document.createElement("tr");
    row.append(
      cell(target.appName),
      cell(target.appBundleID),
      cell(target.deviceType),
      stateCell(target.isConnected),
    );
    rows.append(row);
  }
  table.hidden = targets.length === 0;
  empty.hidden = targets.length > 0;
  count.textContent = targets.length === 1 ? "1 target" : `${targets.length} targets`;
}

async function main() {
  if (!necto.isAvailable()) {
    empty.querySelector(".necto-empty-title").textContent =
      "This page must run inside Necto";
    return;
  }

  const info = await necto.desktop.send("host.info");
  version.textContent = `Necto ${info.nectoVersion}`;

  await necto.desktop.subscribe(
    "targets.observe",
    { includeDiscovered: true },
    (event) => render(event.targets),
  );

  // Every handler is registered; the host flushes anything it buffered.
  await necto.ready();
}

void main();
```

`necto.desktop.send`는 응답을 한 번 받고 `necto.desktop.subscribe`는 중단할 때까지
이벤트를 받아요. 스트림은 현재 목록을 보내고 변경될 때마다 전체 목록을 다시 보내므로
패널은 `render`로 화면을 갱신해요. 입력과 출력은 코드에 전달되기 전에
매니페스트 스키마로 검증하며 실패하면 `code`를 담은 `Error`로
거부돼요. 전체 API와 모든 에러 코드는
[WebPackages/Bridge/README.md](https://github.com/toss/necto/blob/main/WebPackages/Bridge/README.md)에 정리되어 있어요.

## 네이티브처럼 보이게 만들기

`src/style.css` — 공유 스타일시트 두 개를 임포트하면 패널이 앱과 같은 토큰으로
그려지고 별도의 테마 코드 없이 창을 따라 다크 모드로 전환돼요.

```css
@import "@necto/bridge/theme.css";
@import "@necto/bridge/components.css";

html,
body,
.necto-app {
  height: 100%;
}
```

위 HTML의 `necto-toolbar`, `necto-table`, `necto-badge`, `necto-status`,
`necto-empty`는 `components.css`에서 제공하는 일반 CSS 클래스예요.
직접 만드는 요소도 색상과 크기를 하드코딩하지 않고
토큰(`var(--necto-text)`, `var(--necto-space-3)`, …)을 사용해요. 토큰 목록과
규칙은 [design.md](design.md)에 있고 `script/serve-design`이 모든 컴포넌트의
라이브 갤러리를 띄워 줘요.

이제 빌드해요.

```bash
npm install
npm run build
```

`dist/`에 `index.html`, `assets/` 아래의 번들, 그리고 `manifest.json`이
담겨요. 완성된 플러그인이에요.

## 설치하기

Necto가 실행 중이면 터미널에서도 설치를 시작할 수 있어요. Settings → About의
CLI 설정 명령을 복사해 실행한 뒤 `necto install dist --local --json`을 실행하고
Necto에서 출처와 브리지를 승인하세요. 명령은 설치 완료 후 결과를 반환해요.
옵션과 `necto delete <pluginID>` 삭제 방법은 [CLI 가이드](control-socket.md)를 참고하세요.

Necto에서 Settings → Desktop Plugins를 열고 Choose…로 `dist` 폴더를 선택해요.
zip 파일도 돼요. 래퍼 폴더가 있는 릴리스 아카이브와 Finder로 압축한 zip 모두
알아서 처리해요.

파일을 저장하기 전에 Necto가 승인 시트를 보여 줘요. 플러그인의 출처와 요청한
모든 브리지를 "Which version of Necto is running", "Which apps and devices are connected"
같은 문구로 표시해요. 승인하면 설치되고 거절하면 파일을 남기지 않아요.
별도의 권한 이름이나 부분 허용을 두지 않는 이유는
[plugin-manifest.md](plugin-manifest.md)를 참고하세요.

승인하면 Who Is Connected가 사이드바에 나타나요. [Necto SDK를 실은](setup.md)
앱을 시뮬레이터에서 실행하면 연결되는 순간 테이블에 행이 하나 늘어나요.

설치된 플러그인은 `~/Library/Application Support/Necto/Plugins`에 플러그인
id마다 폴더 하나로 저장돼요. Desktop Plugins 설정 페이지의 Open으로 폴더를 열고
Reload로 변경을 반영해요. 새 폴더나 수정된 폴더는 Reload 후 출처 확인이 필요해요.
승인된 로컬 폴더는 앱이 제공한 같은 id의 패널보다 우선해요.
지금 만든 플러그인은 `npm run build` 후 새 `dist`를 다시 설치하면 돼요.
같은 ID의 업데이트임을 확인하고 승인하면 설치 UUID와 권한을 유지해요.
삭제 후 다시 설치하면 새 설치로 처리해요. 로컬 업데이트를 승인하기 전에
[신뢰 정책](plugin-manifest.md#identity-and-trust)을 확인하세요.

## 거부 직접 보기

연결된 앱이 응답해야 하는 오퍼레이션 하나를 `public/manifest.json`에 추가해
보세요.

```json
{
  "id": "records.list",
  "title": "List network records",
  "description": "Reads the app's request log",
  "kind": "once",
  "binding": { "name": "necto.device.network-records.list", "version": 1 },
  "inputSchema": { "type": "object", "additionalProperties": false },
  "outputSchema": { "type": "object", "additionalProperties": true },
  "timeoutMs": 3000
}
```

빌드하고 `dist`를 다시 선택해요. 승인 시트가 뜨기도 전에 설치가 거부돼요.

> This plugin binds to 'necto.device.network-records.list', which a connected
> app answers. A plugin that needs the app rides in the app: add its Swift
> package there, and it appears here on its own.

디바이스 브리지는 데스크톱 설치 단계에서 거부해요. 앱이 필요한 플러그인은
패널과 응답 코드를 같은 커밋의 같은 패키지로 앱에 포함해요.
패널 소스를 수정했다면 웹 에셋도 다시 빌드해 함께 커밋해야 해요.
추가한 오퍼레이션을 제거하고 다시 빌드하면 설치할 수 있어요.

## 다음으로

- 다른 사람에게 전달하기: [publishing.md](publishing.md)
- 2부 — 첫 디바이스 플러그인: [tutorial-device.md](tutorial-device.md)
- 플러그인이 바인딩할 수 있는 모든 것: [bridges.md](bridges.md)
- 매니페스트, 오퍼레이션 하나하나: [plugin-manifest.md](plugin-manifest.md)
- 토큰, 컴포넌트, 갤러리: [design.md](design.md)
- 브리지 클라이언트의 전체 API: [WebPackages/Bridge/README.md](https://github.com/toss/necto/blob/main/WebPackages/Bridge/README.md)
