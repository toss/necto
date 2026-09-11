# 플러그인 매니페스트 v1

플러그인은 `manifest.json`과 웹 에셋으로 구성해요. 네이티브 코드는 담지
않아요.

매니페스트는 플러그인이 호출할 수 있는 오퍼레이션을 선언하는 계약이에요. 여기에
선언되지 않은 것은 런타임이 연결하지 않아요.

## 세 개의 버전 축

세 버전은 서로 독립적이에요.

| 필드 | 답하는 질문 | 예시 |
| --- | --- | --- |
| `schemaVersion` | 파서가 이 파일을 읽을 수 있는가? | `1` |
| `version` | 이 플러그인의 어느 릴리스인가? | `"1.0.0"` |
| `binding.version` | 이 브리지 하나의 어떤 형태인가? | `1` |

"최소 Necto 버전"은 선언하지 않아요. 필요한 브리지와 버전은 바인딩으로
지정해요. Necto가 필요한 브리지를 제공하지 않으면 어떤 브리지가 없는지 알려 줘요.

<a id="when-a-bridge-version-moves"></a>

### 브리지 버전이 올라가는 때

`binding.version`은 호환성이 깨지는 변경이 있을 때만 올려요.
서버가 응답에 필드를 추가할 때마다 앱 업데이트를 요구하지 않는 것과 같아요.

- 브리지 응답에 필드 추가: **올리지 않아요.** 이전 형태에 맞춰 작성된
  리더도 새 형태를 파싱할 수 있어요. 이를 지원하도록 출력 스키마의
  `additionalProperties`는 `false`로 설정하지 않아요.
- 기본값이 있는 선택적 입력 추가: **올리지 않아요.** 그것을 생략하는 이전
  호출자도 여전히 동작해요.
- 필수였던 필드의 제거나 이름 변경, 타입 변경, 값의 의미 변경: **올려요.**
  이전 리더가 이해할 수 없어요.

버전이 일치하지 않으면 거부돼요. 버전 협상, 범위 문법, fallback은 지원하지 않아요.

## 필드

| 필드 | 필수 | 타입 | 설명 |
| --- | --- | --- | --- |
| `schemaVersion` | ✅ | `1` | 매니페스트 포맷 버전 |
| `id` | ✅ | string | 고유 식별자, `[A-Za-z0-9._-]+` |
| `name` | ✅ | string | 사이드바에 표시되는 이름 |
| `description` | ✅ | string | 한 줄 요약 |
| `version` | ✅ | string | 플러그인 버전 (semver) |
| `author` | ✅ | string | 작성자 표시 이름 |
| `authorUrl` | — | string | 작성자 링크 |
| `icon` | ✅ | object | `{ "systemName": "network" }`, SF Symbols 이름 |
| `assets` | ✅ | string[] | 패키징할 파일과 디렉터리 |
| `allowedOrigins` | ✅ | string[] | 오리진 선언: `self` 또는 `https://…`. 현재는 값의 형식만 검증 |
| `operations` | ✅ | object[] | 플러그인이 호출할 수 있는 오퍼레이션. 순수 웹 도구는 빈 배열 허용 |

`allowedOrigins`는 네트워크 허용 목록이 아니에요. 이 선언과 별개로 호스트는
최상위 문서가 설치한 패널의 오리진 안에서만 이동하도록 제한하고, 그 문서의
네이티브 브리지 메시지만 받아요. 최상위 문서에서 누른 외부 HTTP(S) 링크는
브라우저에서 열어요. 외부 프레임은 웹 콘텐츠를 불러올 수 있지만 네이티브
브리지를 호출할 수는 없어요. 일반 웹 네트워크 요청은 차단하지 않아요.

`permissions` 필드는 없어요. 오퍼레이션이 바인딩한 브리지가 곧 요청하는 권한이에요.
실제 동작과 다른 설명이 붙지 않도록 별도의 권한 이름을 두지 않아요.

데스크톱 플러그인의 설치 승인은 요청한 브리지를 허용하는 절차예요. 다이얼로그에
모든 브리지가 표시되고 거절하면 설치되지 않아요. 로컬 업데이트는 출처를 다시
확인해야 해요. 디바이스 플러그인은 등록한 앱 개발자를 신뢰해요. 모든 호출은
경로와 페이로드를 검증하며 셸 실행은 별도의 런타임 정책도 확인해요.

바인딩에 따라 플러그인을 배포하는 방식이 달라져요.

- **디바이스 플러그인.** `necto.device.*`를 바인딩하는 플러그인은 구현을 담은
  Swift 패키지의 `Panel` 리소스로 배포해요. 앱이 패키지를 링크하고 플러그인을
  등록하면 Necto가 연결된 앱에서 패널을 가져와 표시해요. 패널과 구현은 같은
  커밋의 같은 패키지에 포함돼요. 웹 소스가 바뀌면 커밋하는 에셋도 다시 빌드하고
  등록한 계약과 함께 검증하세요.
- **데스크톱 플러그인.** 순수 웹 도구나 `necto.desktop.*`만 바인딩하는 플러그인은
  앱 없이 동작하며 폴더나 zip으로 Necto에 설치해요.
  `necto.device.*`를 바인딩하는 데스크톱 설치는 거부돼요. 앱이 필요한
  플러그인은 앱에 실려요.

플러그인 폴더는 개발자 오버라이드로도 사용해요. 승인된 폴더는 앱이 제공한
같은 id의 패널보다 우선해요. 앱을 다시 빌드하지 않고 패널을 수정할 때 사용해요.

<a id="identity-and-trust"></a>

### ID와 신뢰

`id`는 플러그인을 식별하고 `name`은 UI에 표시되는 이름이에요. 둘은 독립적으로
관리해요. `com.example.notes`처럼 안정적인 소문자 역도메인 ID를 권장해요.
이 형식은 관례이며 도메인 소유권을 확인하지는 않아요. 허용 형식은 여전히
`[A-Za-z0-9._-]+`이고 짧은 ID도 호환되며 매니페스트에 UUID를 쓸 필요는 없어요.
ID를 바꾸면 업데이트가 아닌 다른 플러그인이 돼요. Swift와 매니페스트의 ID는 같아야 해요.

| 출처 | 권한 식별 기준 | 신뢰를 결정하는 주체 |
| --- | --- | --- |
| 디바이스 | `appBundleID` + `pluginID` | 플러그인을 등록한 앱 개발자 |
| GitHub Release | 정규화한 저장소 출처 + `pluginID` | 저장소를 출처로 승인하는 사용자 |
| 로컬 폴더 / ZIP | 호스트가 만든 설치 UUID + `pluginID` | 파일의 출처를 확인하는 사용자 |
| `necto-cli shell` | Necto의 전용 CLI 주체 | Settings의 별도 Shell Access 항목 |

GitHub 저장소의 릴리스 에셋을 설치하며 임의의 Git 리비전을 가져오지는 않아요.
중앙 플러그인 레지스트리나 플러그인 서명 시스템은 없어요.
역도메인 ID, 매니페스트의 `author`, ZIP 파일 이름이나 폴더 경로만으로 게시자를
인증할 수는 없어요. 설치 UUID는 플러그인 파일 밖의 Necto 기록에 저장하며
ZIP으로 전달하거나 다른 설치에서 이어받을 수 없어요.

**디바이스 업데이트.** 앱 번들 ID와 플러그인 ID가 같으면 파일이 바뀌어도 셸 권한을
유지해요. 다른 앱의 같은 ID는 권한을 공유하지 않아요. 이미 등록된 ID를 다시
등록하면 SDK는 디버그 빌드에서 assertion을 발생시키고 모든 빌드에서 핸들러 등록
전에 거부해요. 의도적으로 교체하려면 `NectoSDK.unregister(id:)` 후 `register`를
호출하세요. 신뢰한 앱 안에서 다른 구현이 같은 ID를 재사용하는 것은 앱 개발자의
책임이에요. 이 정책은 게시자 인증이 아니에요.

브리지 이름과 버전의 조합도 앱 안에서 고유해야 해요. SDK는 중복 계약을 거부하고,
호스트도 같은 계약의 제공자가 여러 개이면 호출을 거부해요.

**저장소 업데이트.** 정규화한 호스트·소유자·저장소 이름으로 출처를 구분하며
릴리스 태그는 식별 기준에 넣지 않아요. 같은 출처와 플러그인 ID의 업데이트는
권한을 유지하고 새 바인딩은 승인을 받아요. 다른 저장소나 로컬 파일로 교체하면
이전 출처의 권한을 이어받지 않아요.

**로컬 업데이트.** Settings → Desktop Plugins의 Choose… 또는 설치된 플러그인을
우클릭한 뒤 Update from file…을 사용해요. 후자는 기존 매니페스트와 같은 ID여야 해요.
신뢰하는 출처의 업데이트인지 확인한 뒤 승인하세요. 승인하면 설치 UUID, 브리지 승인,
셸 설정을 유지해요. 새 기능을 포함해 요청한 모든 브리지가 다시 표시돼요.
가져오기를 취소하거나 실패하면 기존 설치를 유지하고 교체 실패 시에는 복구 가능한
백업을 남겨요. ID가 일치한다는 이유만으로 권한을 자동으로 이어받지는 않아요.

`contentHash`는 마지막으로 승인한 파일을 기록하고 변경을 감지하는 값이며 권한 키가
아니에요. Necto는 검사한 에셋의 메모리 스냅샷을 제공해요. Reload 후 새 폴더나 수정된
폴더는 Review required에 표시되고 승인 전에는 로드하지 않아요. 중복 로컬 ID는
검색 순서로 선택하지 않고 거부해요. Necto에서 삭제하면 권한과 설치 기록도 제거해요.
폴더를 직접 삭제한 경우 다음 Reload나 실행 시 반영하며 그 뒤 재설치하면 새 UUID가
부여돼요. 검사 사이에 삭제하고 같은 위치에 다시 넣은 경우는 업데이트와 구분할 수
없으므로 내용이 바뀌면 출처를 다시 확인해요. 같은 OS 사용자 권한으로 Necto의 기록이나
프로세스 자체를 조작하는 공격까지 방어하지는 않아요.

**기존 설치.** 경로만 기록하던 이전 로컬 설치는 신뢰할 설치 기록이 없어요. 한 번
출처를 확인해 UUID를 만들어야 하고 이전 권한이나 스토리지 네임스페이스를 자동으로
이어받지 않아요. 디바이스와 CLI 주체는 바뀌지 않아요. 이후 승인한 로컬 업데이트는
UUID를 유지해요.

파일 경계를 길이로 구분하는 새 콘텐츠 해시 형식은 이전 콘텐츠 승인값과 호환되지
않아요. 업그레이드 후 로컬 파일을 한 번 확인해야 하며 설치 UUID와 권한은 유지해요.
이전 디바이스 SDK도 연결할 수 있지만 이전 해시로 캐시를 재사용하지 않고 패널을
다시 가져와요.

Global Full Access를 켜면 플러그인별·CLI별 셸 권한 검사를 건너뛰어요. 새 로컬 파일을
승인하거나 플러그인을 설치하는 기능은 아니며 끄면 개별 접근 수준이 다시 적용돼요.
권한 격리를 테스트할 때는 꺼두세요.

### 종류별로 할 수 있는 것

|  | 디바이스 플러그인 | 데스크톱 플러그인 |
| --- | --- | --- |
| `necto.device.*` 바인딩 | 가능 | 설치 시 거부 |
| `necto.desktop.*` 바인딩 | 가능 | 가능 |
| 표시되는 때 | 앱이 연결되어 있는 동안 | 항상 |
| 동의 | 앱에 패키지를 추가하는 것 | 설치 다이얼로그 |
| 제거 | 앱에서 패키지 제거 | Settings, 또는 폴더 삭제 |
| 같은 앱이 여러 기기에 | 타깃별 등록, 동일한 패널 콘텐츠는 캐시 공유 가능 | — |

연결과 표시에는 다음 조건이 적용돼요.

- 시뮬레이터 앱은 Mac의 루프백을 공유하지만 각 SDK는 설정된 시작 포트부터
  8개 포트 범위(기본값 9979–9986)에서 빈 포트를 찾아요. Mac도 이 범위를 탐색하므로
  빈 포트가 있으면 여러 시뮬레이터 앱을 연결할 수 있어요. USB 기기도 함께 연결할 수 있어요.
- 디바이스 매니페스트는 타깃별로 등록해요. 다른 앱이나 기기가 같은 플러그인 ID의
  다른 빌드를 제공해도 서로의 등록을 덮어쓰지 않아요. 셸 권한은 기기나 콘텐츠 해시가
  아닌 앱 번들 ID와 플러그인 ID를 기준으로 관리해요.
- 앱 연결이 끊기면 디바이스 플러그인은 캐시된 패널과 함께 사이드바에 회색으로
  남아요. 앱이 재연결되면 다시 활성화돼요. 기록되는 것은 id뿐이에요.
  우클릭 메뉴의 Forget으로 지울 수 있어요. 앱이 더 이상 제공하지 않는 id는 다음 연결 해제
  때 사라져요.
- 디바이스 플러그인을 비활성화하면 이 Mac에서만 숨겨요. 섹션의 맨 아래로
  이동하며 레지스트리와 CLI에서는 계속 호출할 수 있어요.
- 한 기기의 여러 앱이 연결되고 서로 구별돼요 — 다만 iOS는 백그라운드에 있는
  앱을 일시 중단하므로 포그라운드 앱만 확실하게 응답해요. 일시 중단된 앱에
  대한 호출은 타임아웃으로 실패해요.

## 오퍼레이션

`operations`의 각 항목에서 아래 필드는 모두 필수예요.

| 필드 | 타입 | 설명 |
| --- | --- | --- |
| `id` | string | 플러그인 안에서 고유 |
| `title` | string | 사람이 읽는 이름 |
| `description` | string | 무엇을 하는지 |
| `kind` | `once` \| `stream` | 어떻게 응답하는지 |
| `binding` | object | 어느 프로바이더로 해석되는지 |
| `inputSchema` | JSON Schema | 입력을 검증 |
| `outputSchema` | JSON Schema | 출력 또는 각 스트림 이벤트를 검증 |
| `timeoutMs` | integer | 시간 제한(밀리초). `0`은 오퍼레이션 시간 제한 없음 |

`timeoutMs`는 필수 필드예요. `0`이어도 셸 프로바이더가 별도로 정한 실행 제한은 적용돼요.

CLI의 `plugin help`도 기존 설명과 스키마를 사용해요. 필수 필드·타입·열거형·제약은
스키마에 두고 오퍼레이션의 `description`에는 사전 조건, 변경되는 내용, 입력값을
얻는 방법을 적으세요. 예를 들어 "먼저 records.list를 호출하고 반환된 레코드의 id를
recordID로 전달하세요"처럼 안내할 수 있어요. 스키마 속성에도 `description`을 넣을 수
있어요. 설명은 도움말로만 표시하며 호출 경로나 권한 규칙으로 해석하지 않아요.
별도 도움말 파일이나 새 필드는 필요 없어요. [CLI 사용 순서](control-socket.md#cli-사용-순서)를 참고하세요.

`kind`가 호출 방식을 결정해요.

- `once`는 `send`로 한 번 응답해요.
- `stream`은 `subscribe`로 끝날 때까지 이벤트를 전달해요.

읽기와 쓰기는 별도로 구분해 선언하지 않아요. 작성자의 선언만으로 안전성을
판단할 수 없으므로 `necto.device.events.clear`처럼 브리지 이름으로 동작을 드러내요.

`binding`은 다음 두 필드로 오퍼레이션을 처리할 브리지를 지정해요.

```json
"binding": {
  "name": "necto.device.network-records.list",
  "version": 1
}
```

브리지 이름의 접두어로 응답하는 쪽을 구분해요.

- `necto.desktop.…`은 Mac 앱이 응답해요 — 스토리지, 타깃, 실행 중인 버전.
- `necto.device.…`는 연결된 앱이 SDK로 응답하고
  `(deviceID, appBundleID)` 타깃으로 스코프돼요. 선택된 타깃이 없는 호출은
  거부돼요.

패널은 해당하는 쪽의 API로 자신의 오퍼레이션 ID를 호출해요. 예를 들어
`records.list`가 `necto.device.network-records.list`에 바인딩되어 있다면
`necto.device.send("records.list")`로 호출해요. 어느 소유자에게도 속하지 않는
바인딩 이름은 매니페스트 검증 시 거부돼요.

두 오퍼레이션이 같은 브리지에 바인딩할 수는 없어요. 하나의 권한을 두 번
요청하면 두 번 표시되고 두 번 동의받게 돼요.

플러그인은 연결된 앱이 필요한지를 선언하지 않아요. 런타임이 바인딩에서
도출해요. `necto.device.…`가 하나라도 있으면 타깃이 필요하다는 뜻이에요.

프로바이더는 매니페스트의 바인딩 이름, 버전, 오퍼레이션 종류와 일치해야 해요.
입력·출력·스트림 이벤트는 매니페스트 스키마로 검증하며 프로바이더 스키마와의
동일성은 검사하지 않아요. 이름만으로 맞추면 호환되지 않는 버전이나 종류를
잘못된 구현으로 연결할 수 있어요.


## 오퍼레이션 발견과 호출

플러그인 JavaScript는 프로바이더를 지목하지 않아요. 자신의 매니페스트에 선언된
오퍼레이션 id를 호출해요.

```text
manifest.json operations[]
        │ matched against provider descriptors at install time
        ▼
runtime registry (resolve binding name, version and kind; validate payloads)
        │
        ├─ necto.context()                         → availability
        ├─ necto.device.send() / necto.desktop.send() → once
        └─ necto.device.subscribe() / necto.desktop.subscribe() → stream
```

### 발견

`context()`가 오퍼레이션을 현재 상태와 함께 반환해요. 별도의 목록 API는 없어요.

```js
import { necto } from "@necto/bridge";

const context = await necto.context();

context.operations
// [{ id: "records.list", kind: "once", available: true },
//  { id: "variables.list", kind: "once", available: false,
//    unavailableReason: "The selected app does not provide this operation" }]

context.target  // selected target, or undefined
```

`available: false`는 현재 그 브리지에 응답할 프로바이더가 없다는 뜻이에요. 선택된
앱이 없거나 앱이 해당 브리지를 등록하지 않았거나 프로바이더의 계약이
매니페스트와 어긋나는 경우예요. `unavailableReason`을 그대로 사용자에게 보여
주고 컨트롤을 비활성화해 주세요.

사용 가능한 오퍼레이션은 선택된 타깃에 따라 달라지므로 선택이 바뀌면
`context()`를 다시 읽어 주세요.

### 호출

```js
import { necto } from "@necto/bridge";

const page = await necto.device.send("records.list", { limit: 50 });

const subscription = await necto.device.subscribe(
  "records.observe",
  {},
  (event) => appendRow(event),
  (error) => showError(error),
);
await necto.ready();

// When the panel no longer needs updates:
await subscription.unsubscribe();
```

위 예제는 매니페스트에 `records.list`와 `records.observe`가 선언되어 있다고
가정해요. 스트림 핸들러를 등록한 뒤 `necto.ready()`를 호출하세요. 호스트는
그 호출이 완료될 때까지 이벤트를 버퍼링해요.

입력은 `inputSchema`에 대해, 출력과 스트림 이벤트는 `outputSchema`에 대해
런타임 경계에서 검증돼요. 잘못된 입력은 프로바이더 실행 전에 `INVALID_INPUT`으로
실패해요. 잘못된 프로바이더 출력은 호출자에게 전달되기 전에 `INVALID_OUTPUT`으로 실패해요.

### 에러

| 코드 | 의미 |
| --- | --- |
| `INVALID_INPUT` | 입력이 `inputSchema`와 일치하지 않았어요 |
| `OPERATION_NOT_FOUND` | 매니페스트에 그런 오퍼레이션 id가 없어요 |
| `OPERATION_UNAVAILABLE` | 현재 상태나 호출 경로에서 사용할 수 없어요 |
| `PERMISSION_DENIED` | 호출자의 식별 정보나 셸 정책이 요청을 허용하지 않아요 |
| `TARGET_DISCONNECTED` | 선택된 연결 앱이 없거나, 연결이 끊겼어요 |
| `TIMEOUT` | 프로바이더가 `timeoutMs`를 초과했어요 |
| `CANCELLED` | 호출이 취소됐어요 |
| `PROVIDER_FAILED` | 프로바이더가 에러를 일으켰어요 |
| `INVALID_OUTPUT` | 프로바이더 출력이 `outputSchema`와 일치하지 않았어요 |

## 예시

```json
{
  "schemaVersion": 1,
  "id": "network-logger",
  "name": "Network Logger",
  "description": "Watch the app's network requests as they happen",
  "version": "1.0.0",
  "author": "Necto",
  "icon": { "systemName": "network" },
  "assets": ["index.html", "assets"],
  "allowedOrigins": ["self"],
  "operations": [
    {
      "id": "records.observe",
      "title": "Observe network records",
      "description": "Receives a change whenever a request is recorded",
      "kind": "stream",
      "binding": {
        "name": "necto.device.network-records.observe",
        "version": 1
      },
      "inputSchema": { "type": "object", "additionalProperties": false },
      "outputSchema": {
        "type": "object",
        "properties": { "record": { "type": "object" } },
        "required": ["record"]
      },
      "timeoutMs": 0
    }
  ]
}
```

## 디자인 노트

**바인딩이 곧 권한 요청이에요.** Necto는 웹 에셋만 실행하며 매니페스트에 선언된
브리지만 연결해요. 승인 화면에는 이 바인딩을 직접 표시해요.
필요한 브리지 중 일부가 거부되면 플러그인이 제대로 동작하지 않을 수 있으므로
요청한 브리지 전체를 승인하거나 거절해요.

**플랫폼 플래그는 없어요.** Necto는 macOS 전용이므로 `isDesktopOnly` 같은
플래그가 필요 없어요. 연결된 앱이 필요한지는 바인딩으로 판단해요.

**선언과 실행 제한은 구분해요.** `allowedOrigins`는 필수 필드지만 현재 구현은
형식만 검증해요. 외부 통신을 차단하는 보안 장치로 사용하지 마세요.
