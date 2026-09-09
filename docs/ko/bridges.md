# 브리지 카탈로그

플러그인이 Necto에 요청할 수 있는 브리지 목록이에요. 플러그인은 자신의
오퍼레이션 id를 호출하고 런타임이 이를 아래 브리지 중 하나로 연결해요.

## 목차

- 브리지 이름을 짓는 방법
- 호스트 브리지
- 앱 브리지
- Necto가 제공하지 않는 것

## 브리지 이름을 짓는 방법

오퍼레이션 id와 브리지 이름을 구분하세요.

| | 예시 | 정하는 쪽 |
| --- | --- | --- |
| 오퍼레이션 id | `records.list` | 플러그인 |
| 브리지 이름과 버전 | `necto.device.network-records.list` v1 | Necto |

플러그인의 JavaScript는 오직 오퍼레이션 id만 불러요. 매니페스트가 그 id를
브리지에 바인딩해요.

```json
"binding": {
  "name": "necto.desktop.storage.get",
  "version": 1
}
```

플러그인이 바인딩한 브리지가 요청하는 권한이며 별도의 권한 이름은 없어요.
데스크톱 플러그인은 설치 다이얼로그에 브리지를 표시하고
디바이스 플러그인은 패키지를 앱에 추가하는 것을 동의로 봐요.

같은 이름의 두 버전은 서로 다른 두 브리지예요. 프로바이더는 이름·버전·종류가
매니페스트와 일치해야 해요. 페이로드는 매니페스트의 입력·출력 스키마로 검증하며
프로바이더 스키마와의 동일성은 검사하지 않아요. 종류는 한 번 응답하는 `once`와
완료되거나 취소될 때까지 이벤트를 전달하는 `stream`이에요.

`once` 호출은 프로바이더가 취소에 응답하지 않아도 제한 시간 초과나 호출자 취소를
반환해요. 실제 작업은 종료될 때까지 호스트가 관리하며, 정리 중인 동일한 주체·바인딩·타깃의
재시도는 `operationUnavailable`로 거부해요. 뒤늦게 도착한 응답은 버려요.
취소는 정리를 요청하는 것이며 이미 시작한 부수 효과의 취소까지 보장하지는 않아요.

## 호스트 브리지

Mac 앱이 제공해요. 따로 언급하지 않았다면 앱 연결 여부와 관계없이
사용할 수 있어요.

호스트 브리지는 Necto가 보관하거나 접근할 수 있는 데이터를 다뤄요.
테스트 대상 앱의 데이터는 Necto가 배포하는 기능이어도 앱 브리지로 다뤄요.
예를 들어 `DefaultNetworkPlugin`은 자신의 계약을 선언하고 앱의 레코드로 응답해요.
호스트 브리지에는 이 플러그인 이름에 의존하는 코드가 없어요.

### 스토리지 — `necto.desktop.storage.*`

플러그인 주체(principal)별로, 그리고 선택된 타깃이 있으면 타깃별로도
격리돼요. 다른 플러그인은 읽을 수 없고 같은 플러그인이 두 앱에 연결되면
두 앱의 데이터도 따로 보관해요. 다른 소스에서 설치된 플러그인은 같은 id라도
다른 주체예요.

이 격리는 `necto.desktop.storage.*`에 적용돼요. WebView의 쿠키, 로컬 스토리지,
캐시에 같은 주체별 격리가 적용되는 것은 아니에요.

| 키 | 종류 | 입력 | 출력 |
| --- | --- | --- | --- |
| `necto.desktop.storage.get` | once | `key`, `scope?` | `found`, `value` |
| `necto.desktop.storage.set` | once | `key`, `value`, `scope?` | `success` |
| `necto.desktop.storage.remove` | once | `key`, `scope?` | `success` |
| `necto.desktop.storage.keys` | once | `prefix?`, `scope?` | `keys` |

`found`는 저장된 `null`과 없는 키를 구분하므로 `value`와 별도로 반환해요.

### 플러그인 공용 스토리지

스토리지 호출에 `scope: "plugin"`을 넣으면 선택한 디바이스와 무관한 플러그인 주체별
네임스페이스를 사용해요. 앱을 재실행해도 같은 식별 기준을 유지해요.
기본값 `scope: "target"`은 기존 동작을 유지하며 어느 스코프도 인증 정보 저장소는 아니에요.

### 백그라운드 실행과 알림

네 브리지는 모두 버전 1, `once`예요. 매니페스트에 전체 바인딩 이름과 입력·출력
스키마를 선언하고 `necto.desktop.send(...)`에 플러그인의 오퍼레이션 ID를 전달해요.

| 키 | 입력 | 출력 |
| --- | --- | --- |
| `necto.desktop.background.keepAlive` | — | `active` |
| `necto.desktop.notifications.requestAuthorization` | — | `granted` |
| `necto.desktop.notifications.status` | — | `granted` |
| `necto.desktop.notifications.show` | `id`, `title`, `body` | `submitted` |

데스크톱 패널이 `necto.desktop.background.keepAlive`를 선언하고 승인을 받으면
앱은 선택 여부와 무관하게 해당 패널의 실행을 유지해요. 호출하면 `active: true`를 반환해요.
앱 시작 시 활성 패널을 로드하고 다른 패널이나 Settings를 보는 동안에도 유지해요.
비활성화·삭제·콘텐츠 교체 시 종료하며 타깃은 nil이므로 디바이스 선택으로 재시작하지 않아요.
일반 패널의 기존 종료 동작은 유지해요. 시스템 잠자기, App Nap, WebKit의 실행 제한으로
작업이 지연될 수 있으며 OS 백그라운드 서비스는 아니에요. 마지막 창을 닫거나 앱을 종료하면 멈춰요.

웹 콘텐츠 프로세스가 종료되면 숨겨진 패널도 문서를 다시 로드해요. 1·2·4초 간격으로
최대 세 번 복구하고, 1분 동안 다시 종료되지 않으면 시도 횟수를 초기화해요.
계속 종료되면 자동 복구를 중단하고 시스템 로그에 남겨요. 플러그인을 비활성화한 뒤
다시 활성화하면 재시도할 수 있어요. 화면 이동이나 플러그인 해제 시 예약된 복구를
취소하므로 삭제한 플러그인이 다시 열리지는 않아요.

`notifications.requestAuthorization`은 시스템 알림·소리 권한을 요청하고
`notifications.status`는 현재 `granted` 상태를 반환해요.
`notifications.show`는 알림 센터가 요청을 수락하면 `submitted: true`를 반환해요.
시스템 설정과 집중 모드가 알림을 숨길 수 있으므로 화면 표시를 보장하지는 않아요.
`id`는 1–256자, `title`은 1–160자, `body`는 최대 1,000자예요.
알림 식별자는 플러그인 주체별로 구분하고 알림에 플러그인 ID를 표시해요.
`show` 자체는 권한 요청 창을 띄우지 않아요.

사용자가 누른 HTTPS 링크에 인증 정보가 없으면 시스템 브라우저에서 열고 패널은 유지해요.

### 타깃 — `necto.desktop.targets.*`

| 키 | 종류 | 입력 | 출력 |
| --- | --- | --- | --- |
| `necto.desktop.targets.list` | once | `includeDiscovered?` | `targets` |
| `necto.desktop.targets.observe` | stream | `includeDiscovered?` | 변경마다 `targets` |

타깃은 `targetHandle`, `name`, `appName`, `appBundleID`, `deviceType`,
`isConnected`로 표현해요. 버전을 알 수 있으면 `nectoVersion`도 포함해요.
디바이스 id는 제공하지 않아요. 플러그인은 호스트에서 받은 핸들로만 타깃을
지정할 수 있어요. 핸들은 주체별로 구분하며 호스트 세션 동안 유지돼요.

### 네트워크 레코드 — `necto.device.network-records.*`

*호스트 브리지가 아니라 앱 브리지예요.* `DefaultNetworkPlugin`이 레코드를
앱 안에 보관하고 직접 응답해요. 앱이 레코드를 보고하면 패널이 열려 있지 않아도
수집해요. 나중에 연결해도 보관 중인 레코드를 읽을 수 있어요.
`DefaultNetworkPlugin`은 최대 2,000개를 보관하고 한도를 넘으면 오래된 것부터 제거해요.

| 키 | 종류 | 입력 | 출력 |
| --- | --- | --- | --- |
| `necto.device.network-records.list` | once | `limit?` | `records` |
| `necto.device.network-records.detail` | once | `recordID` | `record` |
| `necto.device.network-records.observe` | stream | — | 변경마다 `record` |
| `necto.device.network-records.clear` | once | — | `cleared` |

`list`는 본문을 포함하지 않아요. 500개 행을 조회할 때 500개의 응답 본문까지
가져오지 않도록 헤더, 본문, 재현 가능한 cURL은 `detail`에서 조회해요.


### 호스트 정보 — `necto.desktop.info`

| 키 | 종류 | 출력 |
| --- | --- | --- |
| `necto.desktop.info` | once | `nectoVersion`, `protocolVersion` |
| `necto.desktop.ticks` | stream | `sequence`, `timestamp` |

<a id="shell-access"></a>

### 셸 — `necto.desktop.shell.*`

각 호출자는 Protected 모드에서 시작해요. 사용자는 **Settings → Shell Access**에서
접근 수준을 바꾸거나 플러그인의 권한 요청을 Necto의 네이티브 창에서 승인할 수 있어요.
플러그인 설치는 아래 브리지에 접근하도록 허용하는 절차이며 명령 실행을 승인하는
것은 아니에요. 실행 여부는 플러그인 주체를 기준으로 호스트의 별도 정책이 결정해요.

| 키 | 종류 | 입력 | 출력 |
| --- | --- | --- | --- |
| `necto.desktop.shell.execute` | once | `command`, v2에서 선택적 `stdin` | `stdout`, `stderr`, `exitCode` |
| `necto.desktop.shell.authorization.request` | once | `access?`, `commands?`, `title?`, `message?` | `approved`, `approvedCommands` |

`execute`는 전달한 문자열을 `/bin/bash --noprofile --norc -c`로 실행해요.
Command approval 모드에서는 해당 주체에 승인된 문자열과 정확히 일치해야 해요.
Protected 모드는 모든 명령을 거부하고 플러그인별 Full access는 해당 주체의
모든 명령을 허용해요. Global Full Access는 저장된 개별 설정을 바꾸지 않고
켜져 있는 동안 모든 호출자를 허용해요.

`authorization.request`는 새 승인이 필요할 때 Necto의 네이티브 창을 띄워요.
이미 허용된 요청은 창 없이 반환될 수 있어요. JavaScript가 직접 승인을 추가할 수는
없어요. 플러그인은 제목과 메시지를 제공할 수 있지만 Necto는 플러그인 식별 정보를
별도로 표시해 호스트의 안내와 구분해요. 응답에는 승인된 명령 목록이 담겨요.
기존 `reason` 입력은 호환성을 위해 메시지로 사용할 수 있어요.

`access` 기본값은 `commandApproval`이며 정확한 명령 문자열이 하나 이상 필요해요.
`fullAccess` 요청에는 명령 목록을 넣을 수 없고 더 강한 경고를 표시해요. 승인하면
해당 플러그인 주체만 Full access로 바뀌어요. 플러그인이 요청할 수는 있지만
사용자의 네이티브 승인 없이 스스로 권한을 높일 수는 없어요.

`necto-cli shell run`은 Settings에서 설정하는 전용 CLI 주체를 사용해요.
일반 `necto-cli plugin invoke`는 지정한 플러그인의 주체로 호출하며 셸 오퍼레이션을
노출한 플러그인이라면 그 플러그인의 셸 권한도 사용해요. 컨트롤 소켓은 로컬 OS
사용자를 신뢰하며 CLI 호출자를 별도의 플러그인 소유자로 인증하지 않아요.

셸 실행 v2는 승인한 명령과 별도로 최대 512 UTF-8 바이트의 `stdin`을 받아요.
기존 플러그인을 위해 v1도 등록하며 두 버전은 권한과 동시 실행 제한을 공유해요.
프로세스 시작 전에 입력을 파이프에 기록하고 쓰기 쪽을 닫아요. 명령 승인 문자열이나
프로세스 인자에는 포함되지 않아요. 인증 정보를 명령 문자열에 넣지 말고 사용 후 임시
입력을 지우세요. 스크립트가 출력한 stdout을 브리지가 자동으로 가리지는 않아요.

기본 실행기는 실행 시간 30초, stdout·stderr 합계 1 MiB로 제한해요. 프로바이더의
동시 실행 한도는 전체 4개, 주체별 2개예요. 취소·타임아웃·출력 한도 초과 시
`Foundation.Process`로 실행한 Bash를 종료하고 1초 뒤에도 실행 중이면 `SIGKILL`을
보내요. 백그라운드 자식 프로세스의 종료까지 보장하지는 않아요. 승인 요청이 취소되면
대기 중이거나 표시 중인 승인 창을 제거하며 플러그인의 연결 해제나 삭제 시에도
해당 요청을 취소해요.

명령 승인은 실행 허용 정책이지 샌드박스가 아니에요. 승인한 명령이 다른 프로그램이나
수정 가능한 스크립트를 실행할 수 있고 Full access는 호출자를 로컬 네이티브 앱처럼
신뢰해요. Settings에서도 셸이 호출자를 격리하지 않는다는 점을 안내해요.

승인은 콘텐츠 해시가 아니라 주체에 속해요. 디바이스 플러그인은 앱 번들 ID와
플러그인 ID가 같으면 업데이트 시 권한을 유지해요. 로컬 폴더·ZIP 업데이트는 사용자가
출처를 확인해야 설치 UUID와 권한을 유지해요. 바뀐 로컬 파일은 검토 전까지 로드하지
않고 삭제 후 재설치하면 새 UUID를 부여해요. [ID와 신뢰](plugin-manifest.md#identity-and-trust)를 참고하세요.

`WebPackages/BuiltInPlugins/Plugins/shell-demo`는 앱 연결 없이 이 흐름을 확인할 수
있는 데스크톱 플러그인이에요. `yarn workspace @necto-plugin/shell-demo build`로 빌드한
뒤 Necto의 Desktop Plugins 설정에서 이 폴더를 선택해 설치하세요.

<a id="app-bridges"></a>

## 앱 브리지

연결된 앱이 SDK로 등록하고 하나의 `(pluginID, deviceID,
appBundleID)`로 범위가 한정돼요. 선택된 타깃이 없는 호출은 프로바이더를
조회하기 전에 거절돼요.

앱은 핸들러를 등록해서 이를 선언해요.

```swift
struct VariablesPlugin: NectoPluginable {
    let id = "com.example.variables"

    func register(_ necto: NectoHandler) {
        necto.handle("variables.list") { input in
            ["variables": …]
        }

        necto.handle("variables.observe") { _, out in
            for await change in changes { await out.send(change) }
        }
    }
}
```

이름은 `necto.device.`를 기준으로 한 상대 이름이에요.
`handle("variables.list")`는 패널에서
`necto.device.send("variables.list")`로 호출하고 매니페스트에서는
`necto.device.variables.list`예요.

값을 반환하면 오퍼레이션은 한 번 응답하고 `out`을 받으면 스트림으로 응답해요.
런타임은 이 형태로 호출 종류를 구분해요. 이름을 별도 목록에 선언하지 않고
핸들러를 등록할 때 한 번만 적어요.

핸들러가 읽기인지 쓰기인지는 별도로 선언하지 않아요. 작성자의 선언만으로
안전성을 판단할 수 없으므로 `events.clear`처럼 브리지 이름으로 동작을 드러내요.
삭제 같은 작업에 확인이 필요하면 패널에서 해당 기능에 맞는 문구로 사용자에게 물어요.

호스트는 `plugin.invoke`를 보내고 그에 대응하는 `plugin.result`를
기다려요. 응답 대기 중에 앱 연결이 끊기면 호출은 실패해요.

플러그인은 앱이 실행 중인 동안에도 추가되고 제거될 수 있어요.

```swift
NectoSDK.register(VariablesPlugin())
NectoSDK.unregister(id: "com.example.variables")
```

둘 다 `plugin.register`로 전달해요. 이 메시지는 플러그인의 *전체* 카탈로그를
담으며 마지막 메시지가 현재 등록 상태를 결정해요. 제거할 때는 빈 카탈로그를
보내므로 별도의 제거 메시지는 필요 없어요. 다시 연결하면 기존 등록을 모두
다시 보내요. SDK에서 구현을 교체하려면 기존 ID를
등록 해제한 뒤 새 구현을 등록하세요. 중복 등록은 디버그 빌드에서 assertion을
발생시키고 모든 빌드에서 거부돼요.

앱 플러그인은 활성 구독의 `NectoHandler.Out`으로 스트림 이벤트를 보내요.
`DefaultNetworkPlugin.report(_:)`는 앱에 레코드를 저장하고
`network-records.observe` 구독자에게 변경을 알려요. 패널은
`necto.device.subscribe("records.observe", ...)`로 구독해요. 이를 위한 공개
`bridge.emit` API나 기능 전용 호스트 채널 어댑터는 없어요.

## Necto가 제공하지 않는 것

다음 기능은 Necto 브리지 API로 제공하지 않아요.

- raw 소켓, 또는 그것을 위한 토큰
- 다운로드한 네이티브 코드를 플러그인 모듈로 로드하는 것(셸 명령은 위의 별도 정책 적용)
- 절대 파일 경로, 또는 다른 플러그인의 불투명한 핸들
- JavaScript가 스스로 고른 플러그인 id, 스토리지 네임스페이스, 디바이스
  id, 번들 id

브리지의 제한이 WebView의 모든 웹 API를 차단한다는 뜻은 아니에요.
현재 `allowedOrigins`는 `fetch`, XHR, WebSocket, beacon이나 페이지 탐색을
제한하는 데 사용되지 않아요. 쿠키, 로컬 스토리지, 캐시도 플러그인 주체마다
별도 데이터 저장소로 분리하지 않아요. 신뢰하는 플러그인만 설치하세요.

새 기능은 디스크립터, 타입이 있는 페이로드, 범위가 제한된 호스트 포트로 추가해요.
임시 JavaScript 전역으로 노출하지 않아요.
