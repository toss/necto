# 하네스

SDK, 와이어 프로토콜, 브리지를 수정할 때 지켜야 할 구현 규칙과 검증 방법이에요.

## 목차

- 전체 구조
- 규칙 1: SDK는 브리지예요
- 규칙 2: Necto는 앱이 동작하는 방식을 정하지 않아요
- 규칙 3: 웹 플러그인과 앱 권한을 구분해요
- 규칙 4: 바인딩은 매니페스트에 선언해요
- 규칙 5: 연결은 USB예요
- 규칙 6: 플러그인은 Necto 없이도 열 수 있어야 해요
- 규칙 7: 디자인 시스템은 하나예요
- 변경별 검사

## 전체 구조

```text
Web plugin (manifest.json + JS)        dynamic, installed at runtime
   │ necto.device.send("records.list")   operation id only, never a bridge key
   ▼
Mac host  ── runtime ──┬─ host bridge      storage, targets, shell
                       └─ app bridge ──┐   contracts a connected app registers
                                       ▼
                              USB ── NectoSDK ── NectoPluginable
                                                  the app's own permission
```

세 레이어는 배포 방식과 수명이 달라요. 웹 플러그인은 런타임에
설치되고 제거돼요. 호스트 브리지는 Mac 앱과 함께 배포돼요. 앱 권한은
연결된 앱에 컴파일돼요.

## 규칙 1: SDK는 브리지예요

`NectoSDK`는 메시지만 전달해요. 기능 코드를 추가하면 안 돼요.

| `NectoSDK`에 속하는 것 | 속하지 않는 것 |
| --- | --- |
| 리스닝, 핸드셰이크, 세션 | 개별 기능 구현 |
| `NectoPluginable`, `NectoHandler` | `URLProtocol`, 뷰 워커, 플래그 저장소 |
| 계약 키에 따른 라우팅 | 개별 계약 키의 동작 구현 |
| 다섯 가지 `plugin.*` 메시지 종류 | 새 기능을 위한 여섯 번째 종류 |

새 권한은 별도 모듈에 `NectoPluginable`을 구현해 추가해요. 와이어 메시지 종류나
`NectoSDKRuntime` 코드를 추가하지 않아요.

**검사** — Swift 패키지의 실제 의존성과 SDK만 추가한 앱의 연결을 확인해요.
기능별 모듈 분리는 코드 리뷰에서 확인하며, 주석이나 식별자 표기를 테스트하지는 않아요.

```bash
node --test script/tests/package.test.mjs
swift test --package-path Tests/Fixtures/SDKConsumer
```

## 규칙 2: Necto는 앱이 동작하는 방식을 정하지 않아요

Necto는 앱이 요청을 만들고 뷰를 배치하고 플래그를 저장하는 방식을 알 수
없어요. 앱은 `URLSession`을 쓸 수도, 소켓 라이브러리나 gRPC를 쓸 수도,
난독화된 구현을 쓸 수도 있어요.

그래서 Necto는 **인터페이스와 선택적인 구현을 별도로 배포해요.**

```swift
NectoDefaultPlugins       // the interface: network.report(record)
NectoURLSessionCapture    // one implementation, its own module, opt-in
```

두 모듈은 `NectoSDK` product에 함께 들어 있어요. 별도의 네트워크 스택을 쓰는
앱은 보고용 플러그인을 등록하고 `report(_:)`를 호출해요. URLSession 캡처는 켜지 않아요.
구현을 인터페이스 모듈에 포함하면 다른 스택을 쓰는 앱에도 특정 구현을 강제하게 돼요.

**검사** — 인터페이스 모듈은 구현 모듈을 절대 import하지 않아요. 캡처
메커니즘은 언제나 별도의 타깃이에요.

## 규칙 3: 웹 플러그인과 앱 권한을 구분해요

웹 플러그인과 앱 권한은 역할과 추가 시점이 달라요.

| | 웹 플러그인 | 앱 권한 |
| --- | --- | --- |
| 정체 | `manifest.json` + JS | 앱에 컴파일되는 Swift |
| 추가 시점 | 런타임에 | 빌드 타임에 |
| 선언하는 것 | 오퍼레이션 | 계약 |
| 대화 방식 | `necto.device.send(...)` / `necto.desktop.send(...)` | `NectoPluginable` + `NectoHandler` |
| 허용 범위 | 사용자가 승인한 권한 | 앱이 이미 할 수 있는 모든 것 |

웹 플러그인은 자신의 오퍼레이션 id로 호출해요. 브리지 키, 디바이스 id,
스토리지 네임스페이스, 스스로 고른 플러그인 id로 직접 호출하지 않아요.

## 규칙 4: 바인딩은 매니페스트에 선언해요

모든 오퍼레이션은 매니페스트에 자신의 바인딩을 명시하고 프로바이더는
코드에 같은 경로를 명시해요. 이름, 버전, 종류가 일치해야 해요.
매니페스트는 페이로드 스키마의 기준이에요. 런타임은 프로바이더 스키마와의
동일성을 요구하는 대신 매니페스트 스키마로 입력·출력·스트림 이벤트를 검증해요.
셸 실행에는 호스트가 관리하는 별도 승인 정책이 적용돼요.

이름만으로 프로바이더를 매칭하면 호환되지 않는 버전이나 스트림 종류가
선언된 오퍼레이션으로 잘못 호출될 수 있어요.

**검사** — `script/test swift`가 라우트 불일치와 매니페스트 쪽 페이로드 검증을
커버해요.

## 규칙 5: 연결은 USB예요

실기기는 usbmuxd를 거치는 USB로, 시뮬레이터는 loopback으로 연결해요.
Wi-Fi와 Bonjour 연결은 지원하지 않아요.

usbmuxd는 디바이스가 이미 열어 둔 포트에만 접근할 수 있기 때문에 소켓
역할은 프로토콜 역할과 반대예요.

| 레이어 | Mac | 앱 |
| --- | --- | --- |
| 소켓 | 클라이언트, 연결해요 | 서버, 리스닝해요 |
| 프로토콜 | 호스트, 질문해요 | 프로바이더, 응답해요 |

**검사** — 어떤 것도 `Network.framework`의 Bonjour API나 `NetService`를
import하지 않아요.

## 규칙 6: 플러그인은 Necto 없이도 열 수 있어야 해요

Mac 앱 빌드와 디바이스 연결 없이도 플러그인 레이아웃을 확인할 수 있어야 해요.
플러그인을 개발할 때는 `import.meta.env.DEV`에서 목(mock) 호스트를 사용하세요.

```bash
yarn workspace @necto-plugin/network-logger dev
```

목 호스트는 앱이 쓰는 것과 같은 `webkit.messageHandlers.necto` 채널로
응답하므로 웹 브리지 클라이언트의 메시지 처리를 확인할 수 있어요.
Mac의 프로바이더나 실제 디바이스 연결을 검증하는 것은 아니에요.
긴 URL, 실패, pending 행, 잘린 본문을
목 데이터에 넣어 실제 트래픽에서 생길 수 있는 레이아웃 문제를 확인해요.

**검사** — 플러그인 미리보기를 좁은 화면과 넓은 화면에서 열어 가로 넘침,
잘린 헤더, 겹치는 컨트롤을 확인해요. 타입 검사만으로는 이런 레이아웃 문제를
확인할 수 없어요.

## 규칙 7: 디자인 시스템은 하나예요

웹 플러그인은 `WebPackages/Bridge/theme.css`와 `WebPackages/Bridge/components.css`를
사용하고 네이티브 셸은 대응하는 Swift 토큰을 사용해요. 이 값을 맞추면 내장 UI와
같은 디자인을 유지할 수 있어요.
색을 하드코딩하면 앱과 플러그인의 외관이 달라져요.

`docs/design.md`는 Necto가 관리하는 `Necto/`, `WebPackages/Bridge/`,
`WebPackages/BuiltInPlugins/src/`에서 지켜야 하는 가이드예요. 외부 플러그인에는
강제하지 않아요. 가이드를 따르지 않아 앱과 외관이 달라도 브리지는 로드를 차단하지 않아요.

갤러리 `docs/design/index.html`은 배포되는 스타일시트를 직접 import해요.
디자인을 수정할 때 함께 열어 실제 스타일이 적용된 모습을 확인하세요.

```bash
script/serve-design
```

디바이스 플러그인은 앱 빌드 시점의 웹 에셋을 포함하므로 토큰 기본값이 Mac 셸보다
오래됐을 수 있어요. 호스트는 WebView에 현재 외관, 뉴트럴 색상 단계, surface
토큰을 다시 적용해요. Necto 토큰을 쓰는 플러그인의 외관은 맞추지만
하드코딩된 CSS까지 바꾸지는 않아요.

`NectoThemeTests`는 공용 스타일시트와 커밋된 패널 스타일을 실제 WKWebView에
적용해 네이티브 색상과 비교해요. 두 외관과 오래된 패널 토큰을 호스트가
갱신하는 동작도 확인해요.

```bash
script/test native
```

셸을 변경할 때는 갤러리의 레이아웃과 문구도 직접 확인하세요.

패널 에셋 하네스는 커밋된 모든 패널에 `index.html`이 있는지, 그리고
패널이 참조하는 각 로컬 스크립트와 스타일시트가 존재하고 비어 있지 않은지도
검사해요.

```bash
node script/check-panel-assets.mjs
```

디자인 토큰을 변경하면 다음을 확인하세요.

- **토큰 값 일치:** `script/test native`로 WebView에 표시된 색상과
  `NectoTheme`을 두 외관에서 비교해요.
- **텍스트 대비:** 배경, 사이드바, surface, hover, selected 상태에서 실제로
  사용하는 텍스트와 배경색의 대비를 계산해요.

## 변경별 검사

| 변경한 것 | 실행할 것 |
| --- | --- |
| `NectoModel`, `NectoMacService`의 순수 로직 | `script/test swift` |
| 와이어 프로토콜 | `script/test swift`에 더해 실제 연결, 양방향 모두 |
| `NectoSDK` | `swift test`, 그다음 규칙 1의 검사 |
| 브리지 또는 프로바이더 | `script/test swift`, 그다음 웹 플러그인에서 호출 |
| Mac UI, DI, 호스트 브리지 | `xcodebuild -scheme Necto -destination 'platform=macOS' build` |
| SDK 또는 ExampleApp 런타임 | 부팅된 시뮬레이터에서 `ExampleApp` 빌드 후 실행 |
| 웹 플러그인 | `yarn build`, `script/test web`, 그다음 앱에서 로드 |
| 디자인 토큰, `NectoTheme`, `components.css` | `script/test native`, 그다음 두 외관 모두에서 갤러리 열기 |

ExampleApp에는 부팅된 시뮬레이터가 필요하고 디바이스 이름은 머신마다
다르므로 절대 하드코딩하지 마세요.

```bash
SIM_ID="$(xcrun simctl list devices booted | awk -F '[()]' '/Booted/{print $2; exit}')"
xcodebuild -project Necto.xcodeproj -scheme ExampleApp -destination "id=$SIM_ID" build
```

## 남겨 둘 증거

와이어 프로토콜이나 브리지를 바꿨다면 실제 연결에서 응답이 돌아오는지 검증해야 해요.
다음 중 확인한 항목을 기록해 주세요.

- 실기기의 앱이 USB로 연결되는지
- 앱의 데이터가 웹 플러그인에 표시되는지
- 연결이 끊기면 대기 중인 호출이 실패하는지
- 앱이나 Necto를 재시작하지 않고 재연결되는지
- 실제 플러그인 화면에서 컬럼 잘림 같은 레이아웃 문제가 없는지
