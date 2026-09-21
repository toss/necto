# 아키텍처

## 목차

- 시스템의 형태
- 모듈 경계
- 서버 프로세스가 없는 이유
- 앱이 리스닝하고 Mac이 연결하는 이유
- 플러그인 식별 기준
- 빌드 레이아웃

## 시스템의 형태

```text
Web panel / CLI
   │ operation id
   ▼
NectoPluginRegistry
   ├── desktop provider (Mac)
   └── device provider
         ↕ NectoDeviceBridgeClient / session
       usbmuxd (device) · loopback (simulator)
         ↕ NectoSDK
       NectoPluginable → NectoHandler (in the iOS app)
```

플러그인은 자기 매니페스트에 있는 오퍼레이션 id를 호출해요. 런타임은
이름·버전·종류를 프로바이더 디스크립터와 대조하고 매니페스트에 따라 입력을
검증한 뒤 프로바이더를 호출해요. 셸 프로바이더는 호출자의 셸 권한도 확인해요.

앱 플러그인은 `NectoHandler`로 핸들러를 등록해요. 호스트는 `plugin.invoke`를
보내고 `plugin.result`를 받아요. `NectoDeviceBridgeClient`가 요청 ID로 응답을 연결해요.

- `once`는 결과를 한 번 반환해요.
- `stream`은 완료되거나 취소될 때까지 이벤트를 반환해요. 예를 들어
  `NectoNetworkPlugin`은 앱에 레코드를 보관하고 `network-records.observe`를
  구독 중인 호출자에게 `NectoHandler.Out`으로 변경을 전달해요.

둘 다 같은 공통 메시지를 사용해요. 앱 기능을 추가할 때는 플러그인의 핸들러와
매니페스트 바인딩을 추가하며 기능 전용 호스트 어댑터나 와이어 메시지는 필요 없어요.

## 모듈 경계

| 모듈 | 소유하는 것 | 담으면 안 되는 것 |
| --- | --- | --- |
| `NectoModel` | 매니페스트, 오퍼레이션, 타깃, 핸드셰이크 타입과 스키마 검증 | UI, 네트워킹, WebKit 의존성 |
| `NectoTransport` | 비동기 소켓 I/O, accept 기반 기능, 메시지 프레이밍, 공통 연결 기본값 | USB 탐색, SDK 수신 정책, 오퍼레이션 의미 |
| `NectoCLIService` | 앱과 CLI가 공유하는 control request, response, socket endpoint | 명령어 파싱, provider 실행 |
| `NectoMacService` | 오퍼레이션 라우팅, host provider, device 연결, control server | UI, 앱 특유의 기능 |
| `NectoSDK` | 앱 쪽 리스닝, 플러그인 등록, 메시지 라우팅 | 기능 구현, `URLProtocol`, 도메인 타입 |
| `NectoDefaultPlugins` | Necto가 배포하는 플러그인: 네트워크, 이벤트, 성능 | 앱이 트래픽을 캡처하는 방법 |
| `NectoProcessMetrics` | 선택적인 CPU, 메모리, FPS, 스레드 샘플링 | 앱에 등록되거나 리더가 구독하기 전의 샘플링 |
| `NectoURLSessionCapture` | `URLSession`을 쓰는 앱을 위한 하나의 캡처 메커니즘 | 앱에서 끌 수 없는 캡처 기능 |
| `Necto/` | 셸 UI와 플러그인 호스트 | 기능 화면 |
| `ExampleApp/` | 디바이스에서 연결과 플러그인 검증 | 제품 기능 |

웹과 CLI 호출은 모두 `NectoMacService` registry를 거쳐 프로바이더에 접근해야 해요.

셸 실행도 같은 경로를 사용해요. `necto-cli shell run`은 내부 CLI 매니페스트의
오퍼레이션을 레지스트리로 호출하고 웹 플러그인은 자신의 매니페스트에서 같은
호스트 프로바이더에 바인딩해요. 프로바이더는 레지스트리가 전달한 주체(principal)를
기준으로 셸 정책을 확인한 뒤 프로세스를 실행해요.

## 서버 프로세스가 없는 이유

Mac 앱이 연결과 실행을 직접 담당해요. 플러그인 호출은 추가 IPC 없이
프로세스 안에서 처리하므로 별도 서버를 관리하는 코드가 필요 없어요.

`necto-cli`를 사용하려면 Mac 앱이 실행 중이어야 해요. CLI는 앱의 Unix domain
socket인 `~/Library/Application Support/Necto/necto.sock`에 연결하고 길이 정보가
앞에 붙은 JSON 메시지를 주고받아요. 컨트롤 서버는 웹 패널과 같은 레지스트리로
요청을 전달하며 HTTP 서비스는 아니에요. [컨트롤 소켓](control-socket.md)을 참고하세요.

## 앱이 리스닝하고 Mac이 연결하는 이유

usbmuxd는 디바이스가 이미 열어 둔 포트에만 접근할 수 있으므로 소켓
역할은 프로토콜 역할과 반대예요.

| 레이어 | Mac | 앱 |
| --- | --- | --- |
| 소켓 | 클라이언트, 연결해요 | 서버, 리스닝해요 |
| 프로토콜 | 호스트, 런타임을 실행하고 요청해요 | 프로바이더, 핸들러를 등록하고 응답해요 |

앱은 자신의 정보를 담은 핸드셰이크 hello를 먼저 보내요. 디바이스 id는 Mac이
부여해요. 앱은 자신에 대한 안정적인 디바이스 id를 알 수 없기 때문이에요.

hello의 프로토콜 버전이 다르면 협상 없이 연결을 거부해요.
버전이 다른 앱과 호스트가 일부 기능만 동작하는 상태로 연결되는 것을 막아요.

## 플러그인 식별 기준

`NectoApp`이 `NectoAppModel` 하나를 소유해 registry, 컨트롤 서버, 설치 조정자,
활성화 상태와 백그라운드 페이지를 공유해요. 각 `ContentView`는 선택과 Settings를
관리하는 `NectoWindowState`와 검색 상태를 따로 가져요. 백그라운드 플러그인의 WebView는
하나만 유지하고, 창을 활성화하면 문서를 다시 로드하지 않고 해당 창으로 옮겨요.
설치·셸 승인은 살아 있는 창 하나에만 표시해요. 그 창을 닫으면 남은 창으로 표시 대상을
옮기고, 창이 없으면 CLI 설치를 즉시 거부해요. 숨긴 페이지는 자신의 키보드 포커스를 해제해요.

`InstallCoordinator`가 설치·삭제·리로드의 시작 여부, 다운로드 작업, 출처 선택,
승인, 저장, 완료를 관리해요. `NectoAppModel`은 화면 상태를 전달하고 목록 리로드와
삭제 콜백을 제공해요. GUI 업데이트는 조정자가 수락한 뒤에만 업데이트 목록에서 제거해요.
취소한 IO 작업의 정리가 끝나야 다음 요청을 받아요. 최초 로드와 수동 리로드도 같은
진입 조건을 사용하며 설치 완료 후 리로드는 설치 작업의 소유권을 유지한 채 실행해요.

플러그인 권한은 호스트가 부여한 주체를 기준으로 관리해요. 디바이스 플러그인은
앱 번들 ID와 플러그인 ID를, 로컬 데스크톱 플러그인은 설치 UUID와 플러그인 ID를
조합해요. 원격 데스크톱 플러그인은 정규화한 저장소 출처와 플러그인 ID를 조합해요.
로컬 설치 기록의 마지막 승인 콘텐츠 해시는 권한 식별자와 분리돼요.
설치기는 승인된 스냅샷을 저장하고 WebView는 수정 가능한 로컬 파일 대신 그
스냅샷을 제공해요. 패널 호출은 예상 주체도 검사하므로 이전 페이지가 교체된
설치의 권한으로 호출할 수 없어요. [신뢰 정책](plugin-manifest.md#identity-and-trust)을 참고하세요.

## 빌드 레이아웃

라이브러리는 Swift 패키지로, 앱 타깃은 `Necto.xcodeproj`로 관리해요.

루트 패키지는 SDK, 공용 모듈, 기본 플러그인을 담은 `NectoSDK` product 하나만
제공해요. 모듈은 분리된 상태로 유지하며 앱에서 사용할 플러그인을 `import`하고
등록해요. 로컬 `NectoMac/Package.swift`는 Mac 서비스와 `necto-cli`, 해당 테스트를
빌드해요. 공용 타입과 전송 모듈은 루트 product를 통해 사용해요. 반대로 SDK는
Mac 패키지나 ArgumentParser에 의존하지 않아요. `script/test swift`는 두 패키지와
단일 product를 사용하는 외부 패키지 예제를 테스트해요.

패널은 Yarn workspaces로 빌드해 Swift 패키지에 포함해요. 기본 플러그인은
`Sources/NectoDefaultPlugins/Panels/<id>`에, 샘플은 예제 앱 번들에 들어가요.
빌드 결과를 커밋하므로 앱만 빌드할 때는 Node가 필요 없어요.
