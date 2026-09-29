# 앱에 Necto 설정하기

Necto SDK는 앱과 함께 컴파일되는 디버그 도구예요. SDK를 연결하고
사용자에게 노출하지 않도록 설정하는 방법을 다뤄요.
Mac 앱 설치 방법은 [install.md](install.md)를 참고하세요.

## 연결하기

Xcode의 Package Dependencies에 `https://github.com/toss/necto.git`을 추가해요.
앱 타깃에는 `NectoSDK` product 하나만 선택해요. SDK와 기본 플러그인 모듈이
함께 들어 있어요. 코드에서는 아래처럼 사용하는 모듈을 `import`해요.
앱 시작 시 플러그인을 한 번 등록한 다음 SDK를 시작하세요.

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

필요한 플러그인만 등록하세요. 패키지를 추가하는 것만으로 플러그인이 등록되거나
수신 대기·캡처가 시작되지는 않아요. 등록하지 않은 기본 플러그인의 코드와 패널
리소스도 product에는 포함돼요. 직접 만든 플러그인도 같은 방식으로
등록하며 앱이 연결되면 해당 패널이 Mac의 Necto 앱에 나타나요.
전체 구현 예제는 [디바이스 플러그인 튜토리얼](tutorial-device.md)을 참고하세요.

### 기존 의존성 변경하기

앱이나 플러그인 패키지에서 `NectoDefaultPlugins`, `NectoProcessMetrics`,
`NectoURLSessionCapture`, `NectoModel`, `NectoTransport` product를 직접 지정했다면
`NectoSDK` 하나로 바꿔 주세요. `Package.swift`에서는 다음과 같이 지정해요.

```swift
.product(name: "NectoSDK", package: "necto")
```

모듈 이름과 `import`, 등록 API는 그대로예요. 다만 기존 product를 참조하는
패키지 설정은 새 버전을 적용하기 전에 바꿔야 해요. Mac 호스트 product는
로컬 `NectoMac` 패키지로 옮겼으며 SDK에는 포함되지 않아요.

## 사용자에게 노출하지 않기

사용자에게 배포하는 빌드에서는 디버깅 도구를 실행하면 안 돼요.

> 모든 Necto 호출을 `#if DEBUG`로 감싸 주세요.

`#if DEBUG` 안의 호출은 `DEBUG`가 정의되지 않은 빌드에서 제외돼요.
Release 빌드 설정에 `DEBUG`가 없는지도 확인하세요.

`NectoSDK.start()`는 수신 대기를 시작해요. 다만 `URLSessionNetworkPlugin`은
등록할 때 캡처를 시작하므로 `start()`뿐 아니라 플러그인 생성과 등록도 함께 감싸야 해요.

호출을 제외해도 패키지의 코드와 리소스까지 모두 제거된다고 보장하지는 않아요.
제거 여부는 링크 방식과 데드 코드 스트리핑 등 빌드 설정에 따라 달라져요.
완전히 제외해야 한다면 Necto 의존성이 없는 배포용 타깃을 분리하고 실제 Release
산출물에 코드와 리소스가 남는지 확인하세요. `EXCLUDED_SOURCE_FILE_NAMES`만으로
Swift 패키지의 소스를 제외할 수는 없어요.

## 연결 방식

앱에 `NectoSDK.start(publicKey:)`를 설정하면 올바른 키를 등록한 Mac만
연결할 수 있어요. 앱 설정과 Mac 키체인 등록 방법은
[연결 인증과 키체인 등록](connection-security.md)을 참고하세요.

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
이 호출도 `#if DEBUG`로 감싸야 해요. 나머지 플러그인은 확인할 데이터에 맞춰 추가하세요.
