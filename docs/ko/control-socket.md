# 컨트롤 소켓

`necto`(기존 `necto-cli` 이름도 지원해요)와 같은 Mac의 다른 프로세스가 실행 중인 Necto에 요청을 보내는
방법이에요.

오퍼레이션 호출은 웹 패널과 같은 `NectoPluginRegistry`를 사용하며 같은 경로·페이로드
검증과 프로바이더를 거쳐요. 설치된 매니페스트에 선언된 오퍼레이션만 호출할 수 있어요.
별도의 `surface: "cli"` 권한 플래그가 요청에 전달되지는 않아요.

`necto-cli shell run`은 Necto의 내부 CLI 매니페스트를 호출하고 Settings의 전용
Shell Access 항목을 사용해요. 일반 `plugin invoke`와 `plugin subscribe`는
`pluginID`로 지정한 플러그인의 주체로 실행해요. 그 플러그인이 셸 오퍼레이션을
노출한다면 해당 플러그인의 셸 권한도 사용해요. 소켓은 로컬 OS 사용자 권한으로
실행되는 프로세스를 신뢰하며 플러그인 소유자를 인증하거나 일반 CLI 호출을
플러그인 권한에서 격리하지 않아요. [셸 접근](bridges.md#shell-access)을 참고하세요.

## 어디서, 어떻게

- **소켓** — `~/Library/Application Support/Necto/necto.sock`, 앱이 실행될 때
  `0600`으로 만들어요. 플러그인 폴더와 마찬가지로 사용자 계정별로 접근을 제한해요.
- **프레이밍** — 모든 메시지는 4바이트 빅 엔디언 길이 뒤에 그만큼의 JSON
  바이트가 따라오는 형태예요. 모든 Necto 연결이 사용하는 것과 같은 프레이밍이에요.
- **연결** — 연결한 뒤 요청을 보내고 응답을 읽어요. 한 연결에서 여러 요청을
  처리할 수 있어요. `id`로 각 응답을 요청과 연결해요. 연결을 닫으면 그 연결이
  시작한 스트림이 취소돼요.

## 요청

```json
{ "id": "r1", "kind": "targets" }
{ "id": "r2", "kind": "plugins" }
{ "id": "i1", "kind": "installPlugin", "input": { "path": "/absolute/path/to/dist" } }
{ "id": "i2", "kind": "installPlugin", "input": { "repositoryURL": "https://github.com/owner/plugins" } }
{ "id": "d1", "kind": "deletePlugin", "pluginID": "com.example.plugin" }
{ "id": "r3", "kind": "invoke",    "pluginID": "url-scheme", "operationID": "links.open",
  "input": { "url": "https://example.com" }, "app": "com.example.app" }
{ "id": "r4", "kind": "subscribe", "pluginID": "plugin-sample", "operationID": "host.ticks" }
{ "id": "r4", "kind": "cancel" }
```

- `pluginID`와 `operationID`는 `plugins`가 반환하는 설치된 매니페스트의 id예요.
  목록을 코드에 고정하지 않고 현재 호출할 수 있는 오퍼레이션을 조회해요.
- `app`은 디바이스 오퍼레이션을 처리할 앱의 번들 ID예요. 같은 앱이 여러 기기에서
  실행 중이면 `targets`에 나온 기기 ID를 `device`로 함께 지정해요.
  조건에 맞는 연결 대상이 정확히 하나가 아니면 요청이 실패해요.
- `cancel`은 멈추려는 대기 요청이나 구독의 `id`를 재사용해요.

`installPlugin`에는 로컬 폴더·ZIP의 절대 경로 `path` 또는 HTTPS `repositoryURL` 중
하나만 전달해요. URL에는 인증 정보, 포트, 쿼리, 프래그먼트를 넣을 수 없어요.
앱은 Settings와 같은 릴리스 조회·다운로드·검증·출처 확인·승인·저장 경로를 사용해요.
Necto에 승인 창을 띄우고 승인한 스냅샷의 등록이 끝난 뒤 결과를 반환해요.
설치에는 플러그인 브리지나 셸 권한을 사용하지 않으며 다른 설치가 진행 중이면 거부해요.

저장소 URL은 최신 릴리스를 사용해요. 특정 버전은 `/releases/tag/<tag>` URL로 지정해요.
릴리스에 플러그인이 여러 개면 Necto에서 하나를 선택해요. CLI 호출 한 번에 하나를 설치하며
저장소·태그 출처를 기록해 이후 업데이트에서도 출처 식별 기준을 유지해요.
취소하면 대기 중인 조회·다운로드 작업을 정리하고 뒤늦게 도착한 결과는 설치하지 않아요.

인증 조건도 기존 GUI 설치와 같아요. 공개 저장소는 직접 내려받을 수 있고,
비공개·Enterprise 저장소는 현재 개발자의 `gh` 로그인을 사용해요.
설치기의 인증은 각 플러그인이 관리하는 인증 정보와 별개예요.

성공하면 `installed: true`, `pluginID`, `name`, `version`, `enabled`를 반환해요.
같은 ID의 업데이트도 출처를 확인하며 기존 비활성 상태는 유지해요.
잘못된 파일, 디바이스 브리지에 바인딩한 플러그인, 승인 거부는 실패로 반환해요.
`cancel`이나 CLI 연결 종료는 대기 중인 승인 창을 닫지만 사용자가 승인해 저장을 시작했다면
CLI 종료 후에도 설치가 완료될 수 있어요. 무인 설치나 승인을 생략하는 API는 아니에요.

`deletePlugin`에는 설치된 데스크톱 플러그인의 ID를 전달해요. 경로나 저장소 URL은 받지 않아요.
Settings와 같은 경로로 설치 폴더를 휴지통으로 옮기고 권한·설치 기록·등록을 제거하며
패널과 백그라운드 실행을 종료해요. 완료하면 `deleted: true`, `pluginID`를 반환해요.
없는 ID나 디바이스 플러그인은 파일을 바꾸지 않고 실패해요.
설치·삭제·리로드는 같은 조정자가 관리하며 다른 작업이나 승인 대기가 끝나야 실행할 수 있어요.

## 응답

```json
{ "id": "r3", "kind": "result", "value": { "opened": true } }
{ "id": "r4", "kind": "event",  "value": { "sequence": 1 } }
{ "id": "r4", "kind": "end" }
{ "id": "r3", "kind": "error",  "error": { "code": "INVALID_INPUT", "message": "url is required" } }
```

하나의 요청은 정확히 하나의 `result` 또는 `error`를 받아요 — 예외는
`subscribe`로, 몇 개든 `event`를 받은 뒤 하나의 `end` 또는 `error`를 받아요.
에러 코드는 브리지 자체의 것이에요(`docs/plugin-manifest.md`에 목록이 있어요).
레지스트리의 에러를 그대로 전달해요.

## CLI 사용 순서

```bash
necto-cli plugin list                      # installed plugins and their operations
necto install owner/plugins --json         # remote is the default
necto install https://github.com/owner/plugins --remote
necto install https://github.com/owner/plugins/releases/tag/v1.2.0
necto install ./dist --local               # approve in Necto; wait for installation
necto install ./my-plugin.zip --local
necto delete com.example.plugin --json     # ID from plugin list; moves files to Trash
necto-cli plugin schema <plugin> <op>      # what one operation takes and returns
necto-cli plugin invoke <plugin> <op> --input '{}'
necto-cli plugin invoke <plugin> <op> --input '{}' --app <bundle-id> --device <device-id>
necto-cli plugin subscribe <plugin> <op>   # one JSON object per line, ^C cancels
necto-cli targets --json                   # includes bundle ids and device ids
necto-cli shell run 'git status --short'   # shell policy is managed in Necto Settings
```

자리표시자는 `plugin list`와 `targets --json`에서 확인한 값으로 바꾸고,
`--input`은 오퍼레이션의 `schema`에 맞춰 작성해요. `schema`와 `invoke`는 기본으로
JSON을 출력하고 `subscribe`는 이벤트마다 JSON 한 줄을 출력해요.
`targets`와 `plugin list`에서 JSON이 필요할 때만 `--json`을 붙이세요.
`subscribe`에도 `--app`, `--device`를 지정할 수 있어요.

`install`의 기본 모드는 `--remote`예요. `owner/repo`는 GitHub.com으로 해석하고
HTTPS 저장소·릴리스 URL도 받을 수 있어요. 로컬 폴더와 ZIP은 `--local`이 필요하며
`--local`과 `--remote`를 함께 사용할 수 없어요. `necto plugin install`과
`necto-cli plugin install`도 같은 옵션을 지원해요.

Settings → About에 표시된 명령을 복사해 실행하면 앱에 포함된 실행 파일을 가리키는
`necto`와 `necto-cli` 링크를 `PATH`에 등록해요. 앱 업데이트 후 기존 `necto-cli`만
있다면 해당 명령을 다시 실행하세요. 기존 CLI 명령도 계속 사용할 수 있어요.

`necto plugin delete <pluginID>`와 `necto-cli plugin delete <pluginID>`도 지원해요.
삭제 명령은 별도 설치 승인을 다시 묻지 않으며 GitHub 저장소를 삭제하지 않아요.
옵션은 `necto install --help`, `necto delete --help`, `necto plugin --help`에서 확인하세요.
