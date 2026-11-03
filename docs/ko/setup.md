# 앱에 Necto 설정하기

Necto SDK는 앱과 함께 컴파일되는 디버그 도구예요. SDK를 연결하고
사용자에게 노출하지 않도록 설정하는 방법을 다뤄요.
Mac 앱 설치 방법은 [install.md](install.md)를 참고하세요.

Necto는 신뢰할 수 있는 앱과 실행 환경(개발 기기·네트워크 등)에서만 사용하세요.
SDK 연결에는 상대 인증과 TLS가 없어요. USB나 루프백만으로는 같은 기기의 다른 앱이나
Mac의 다른 프로그램이 접근하는 것을 막지 못해요. 포트를 신뢰할 수 없는 네트워크에
노출하거나 전달하지 마세요.

## 연결하기

Xcode의 Package Dependencies에 `https://github.com/toss/necto.git`을 추가해요.
기본 SDK인 `NectoSDK`와 사용할 플러그인 product만 선택해요. 아래 예제에는
`NectoEventsPlugin`, `NectoProcessMetricPlugin`, `NectoURLSessionCapturePlugin`,
`NectoUIControlPlugin`이 필요해요. 자동 캡처와 UI 제어는 비공개 API를 사용하므로
이를 허용하지 않는 앱은 두 product를 추가하지 마세요.

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

필요한 플러그인만 등록하세요. 패키지를 추가하는 것만으로 플러그인이 등록되거나
수신 대기·캡처가 시작되지는 않아요. 선택한 플러그인의 코드와 패널만 의존성에
포함돼요. 직접 만든 플러그인도 같은 방식으로
등록하며 앱이 연결되면 해당 패널이 Mac의 Necto 앱에 나타나요.
전체 구현 예제는 [디바이스 플러그인 튜토리얼](tutorial-device.md)을 참고하세요.

### 필요한 product 선택하기

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

기존 `NectoSDK` 하나만 사용하던 앱은 사용하는 product를 명시적으로 추가해야 해요.
`import NectoDefaultPlugins`는 위 표의 개별 플러그인 import로 바꾸세요.
`NectoProcessMetrics`와 `NectoURLSessionCapture` import는 각각
`NectoProcessMetricPlugin`과 `NectoURLSessionCapturePlugin`으로 변경해요.
등록 함수와 플러그인 타입 이름은 유지해요.

```swift
.product(name: "NectoSDK", package: "necto"),
.product(name: "NectoNetworkPlugin", package: "necto"),
.product(name: "NectoEventsPlugin", package: "necto")
```

## 사용자에게 노출하지 않기

사용자에게 배포하는 빌드에서는 디버깅 도구를 실행하면 안 돼요.

SDK는 캡처를 특정 빌드 설정으로 제한하지 않아요. 내부 테스트용 Release 빌드를
포함해 어떤 타깃에 product를 넣고 언제 플러그인을 등록·시작할지는 앱에서 결정해요.

`URLSessionNetworkPlugin`을 등록하면 네트워크 캡처가 시작돼요.
`NectoSDK.start()`를 호출하면 Mac의 Necto 앱에서 캡처한 요청을 확인할 수 있어요.

호출을 제외해도 패키지의 코드와 리소스까지 모두 제거된다고 보장하지는 않아요.
제거 여부는 링크 방식과 데드 코드 스트리핑 등 빌드 설정에 따라 달라져요.
완전히 제외해야 한다면 Necto 의존성이 없는 배포용 타깃을 분리하고 실제 Release
산출물에 코드와 리소스가 남는지 확인하세요. `EXCLUDED_SOURCE_FILE_NAMES`만으로
Swift 패키지의 소스를 제외할 수는 없어요.

## 연결 방식

- **시뮬레이터** — Mac이 루프백으로 앱에 접근해요.
- **실기기** — USB 케이블로 연결하면 `usbmuxd`를 거쳐요.
- SDK는 로컬 TCP 포트에서 수신 대기해요. 다른 시뮬레이터 앱이 포트를 쓰고
  있으면 정해진 포트 범위에서 빈 포트를 찾아요.
  Necto는 Bonjour나 멀티캐스트를 쓰지 않아요.
- 앱 두 개, 또는 두 기기에서 실행한 같은 앱도 나란히 연결돼요. 사이드바와
  `necto-cli`의 `--app`, `--device` 옵션으로 구분해요.

## 먼저 추가할 플러그인

`URLSessionNetworkPlugin`과 `NectoEventsPlugin`부터 추가해 보세요. 네트워크
요청이 일어나는 즉시 패널에 나타나요. 등록한 `events` 인스턴스를 앱의 디버그
로깅 코드에 보관하고 위 예제처럼 `events.report(...)`로 로그를 보내세요.
나머지 플러그인은 확인할 데이터에 맞춰 추가하세요.

### 캡처되는 요청

`NectoURLSessionCapturePlugin`을 추가하고
`NectoSDK.register(URLSessionNetworkPlugin())`을 호출하면 `URLSession.shared`와
앱에서 직접 만든 세션의 HTTP(S) 요청을 자동으로 기록해요. 기존 `URLSession` 생성과
요청 코드를 유지하세요. `makeSession`이나 별도 세션 프로토콜은 필요하지 않아요.
기존 `NectoURLSessionCapture.protocolClass` 등록은 제거해도 돼요.
호환용으로 남아 있지만 요청을 가로채지 않아요.

PulseProxy처럼 원래 세션의 실행 경로를 후킹해 관찰해요. 요청을 재전송하거나
앱의 configuration·delegate를 교체하지 않으므로 정상 인증, 쿠키 저장소와 인증
저장소의 격리, 인증 challenge·리다이렉트 판단은 Foundation과 앱이 그대로 처리해요.
수동 로깅만 필요하다면 공개 API만 사용하는 `NectoNetworkPlugin`을 사용하세요.

- 설치하면 Debug·Release 모두 캡처해요. 비공개 API를 제외하려면 앱 타깃의
  의존성에서 `NectoURLSessionCapturePlugin`을 빼세요.
- 비공개 Foundation 클래스·메서드를 사용해요. OS 변경과 다른 SDK의 후킹에
  영향을 받을 수 있어요. 메서드 존재 여부와 시그니처를 확인하지만 향후 호환성을 보장하지 않아요.
- 데이터·업로드·다운로드·스트리밍 요청을 기록하고 본문 미리보기 크기는 제한해요.
  앱의 스트림을 읽어서 소비하지 않으므로 스트림 기반 업로드 본문은 기록되지 않을 수 있어요.
- WebSocket 메시지와 별도 프로세스에서 실행되는 백그라운드 전송은 지원 범위가 아니에요.
- `uninstall()`은 기록을 멈춰요. 다른 SDK의 후킹을 덮어쓰지 않도록 설치한 후크는
  원래 구현을 호출하는 상태로 남아요.

참고 구현: [PulseProxy](https://github.com/kean/Pulse/blob/main/Sources/PulseProxy/URLSessionSwizzler.swift),
[Atlantis의 Network.framework 로더 지원](https://github.com/ProxymanApp/atlantis/blob/main/Sources/NetworkInjector%2BNWURLSession.swift).
