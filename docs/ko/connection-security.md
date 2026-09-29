# 연결 인증과 키체인 등록

연결 인증을 켜면 **Mac에 올바른 키를 등록해야 앱을 디버깅할 수 있어요.**
앱에는 공개키를 넣고 Mac에는 개인키를 등록해요. 두 키는 짝이 맞아야 해요.
연결되면 디버깅 데이터와 명령은 TLS 1.3으로 암호화해요.

고객에게 배포하는 Release 빌드에는 SDK를 포함하지 않는 것이 기본이에요.
연결 인증은 개발용·사내 배포용 앱에 추가하는 보호 장치예요.

## 1. 앱에 공개키 설정하기

Swift 6.1 이상이 필요해요. 공개키는 P-256이고 X9.63 형식으로 내보내면
65바이트예요. 이 값을 Base64로 인코딩해 String으로 사용해요.
아래 등록 코드를 실행하면 `SDK publicKey` 값을 출력해요.
이 값을 그대로 사용할 수 있어요.

```swift
#if DEBUG
NectoSDK.start(publicKey: "<Base64 P-256 public key>")
#endif
```

공개키는 앱 저장소에 넣어도 돼요. 개인키는 넣으면 안 돼요.
잘못된 공개키를 설정하면 SDK는 연결을 받지 않아요.

`NectoSDK.start()`를 쓰는 앱은 기존 방식으로 연결돼요.
이 연결에는 인증과 암호화가 적용되지 않아요. 포트는 SDK가 9979~9986 중에서
자동으로 선택하므로 직접 지정할 필요가 없어요.

## 2. Mac에 등록할 값 준비하기

Mac의 개인키는 앱에 설정한 공개키와 짝이 맞아야 해요.
Mac마다 새 키를 만들면 연결할 수 없어요.

여러 앱에서 같은 키를 써도 돼요. 같은 개인키와 인증서로 각 앱의 `bundleID`를
등록하세요. 개인키는 한 번만 저장하고 앱별 등록 정보는 따로 보관해요.
등록하지 않은 `bundleID`에는 이 키를 사용하지 않아요.

| 값 | 용도 |
| --- | --- |
| 앱의 `bundleID` | 어떤 앱의 키인지 구분해요. 실제 앱의 값과 같아야 해요. |
| P-256 개인키의 PEM String | Mac이 연결할 권한을 증명할 때 사용해요. 허용된 사용자에게만 배포하세요. |
| 같은 키의 인증서 | DER 데이터를 Base64 String으로 전달해요. 자체 서명 인증서로 충분하며 CA 서버는 필요 없어요. |
| Necto 실행 파일 경로 | 이 실행 파일에 키 사용 권한을 줘요. |

인증서와 개인키를 String으로 전달할 수 있으므로 사용자가 별도 인증서 파일을
관리할 필요는 없어요.

키체인 등록은 **`bundleID` 기준**이에요. 같은 앱이 여러 iPhone에 있어도
Mac에는 한 번 등록하면 돼요. 인증 성공 여부는 각 기기의 앱 연결에서 따로
확인해요. 같은 `bundleID`의 빌드끼리 키를 공유하려면 공개키도 같아야 해요.

## 3. Mac 키체인에 등록하기

먼저 Mac에 Necto를 설치하세요. 일반적인 실행 파일 경로는
`/Applications/Necto.app/Contents/MacOS/Necto`예요. 로컬 빌드를 실행한다면
그 빌드 안의 `Necto` 실행 파일 경로를 사용해야 해요.

키 등록 도구는 프로젝트 환경에 맞게 구현하세요. 아래 예제는 `NectoMac` 하위
패키지의 `NectoMacService`를 사용해요. 패키지 경로는 로컬 체크아웃에 맞게
수정하세요.

```swift
// In the private setup tool's Package.swift:
dependencies: [
    .package(path: "/path/to/necto/NectoMac"),
],
targets: [
    .executableTarget(
        name: "CompanyNectoSetup",
        dependencies: [.product(name: "NectoMacService", package: "NectoMac")]
    ),
]
```

예시의 String을 등록할 값으로 바꾸고 설정 도구에서 실행하세요.
개인키가 포함된 설정 도구는 공개 저장소에 올리지 마세요.

```swift
import Foundation
import NectoMacService

let bundleID = "com.example.internal-app"
let privateKeyString = "<PEM private key from your restricted provisioning source>"
let certificateString = "<Base64 DER certificate matching that private key>"
guard let certificateData = Data(base64Encoded: certificateString) else {
    fatalError("Invalid Base64 certificate")
}

let store = try NectoKeychainCredentialStore()
try store.install(
    bundleID: bundleID,
    privateKeyPEM: Data(privateKeyString.utf8),
    certificateDER: certificateData,
    trustedApplications: [
        URL(fileURLWithPath: "/Applications/Necto.app/Contents/MacOS/Necto")
    ]
)
if let identity = try store.identity(bundleID: bundleID) {
    print("SDK publicKey: \(identity.publicKey)")
}
```

출력된 공개키를 앱에 설정하고 다시 빌드하세요. 이미 같은 공개키가 설정되어
있다면 앱을 다시 빌드할 필요는 없어요. 개인키는 출력하지 마세요.

등록 API는 개인키를 일반적인 내보내기 API로 추출할 수 없게 저장하고
설정 도구와 지정한 Necto 실행 파일에 사용 권한을 줘요.

## 4. 키체인에서 등록 확인하기

Mac의 **키체인 접근** 앱을 열고 기본 키체인(보통 **로그인**)에서
**모든 항목**을 선택하세요. 다음 이름으로 각각 검색하면 돼요.

| 항목 | 검색할 이름 |
| --- | --- |
| 개인키 | `Necto Connection: <처음 등록한 앱의 bundleID>` |
| 인증서 | `Necto Certificate: <처음 등록한 앱의 bundleID>` |
| 앱 등록 정보 | `im.necto.connection.certificate` — 계정 값이 `<bundleID>`인지 확인하세요. |

예를 들어 앱의 `bundleID`가 `com.example.internal-app`이면 개인키 이름은
`Necto Connection: com.example.internal-app`이에요.
다른 앱이 같은 키를 쓰더라도 개인키 이름은 바뀌지 않아요.
인증서도 함께 사용해요. 각 앱의 등록 여부는 앱 등록 정보의 계정 값으로 확인하세요.

같은 Necto 실행 파일에 앱을 추가할 때는 기존 키의 접근 권한을 그대로 사용해요.
설정 도구나 Necto 실행 파일에 기존 키를 쓸 권한이 없으면 등록에 실패해요.
권한 변경은 설정 도구에서 별도로 처리하세요.
앱 하나의 등록을 삭제하더라도 다른 앱이 쓰고 있는 개인키와 인증서는 지우지 마세요.

인증서와 앱 등록 정보는 공개 정보라서 읽을 때 승인이 필요하지 않아요.
개인키로 서명할 때 키체인 사용 승인을 받아요. 같은 이름으로 암호 항목을
직접 만들어도 개인키는 등록되지 않으니 위 등록 API를 사용하세요.

아무것도 나오지 않으면 설정 도구가 성공했는지 확인하세요.
Necto 앱만 설치한 상태에서는 이 항목들이 없어요.

## 5. 연결 확인하기

키를 등록하면 Necto가 다음 연결 시도에 읽어 사용해요. Necto나 iPhone 앱을
다시 실행할 필요는 없어요. GUI와 CLI 중 어느 쪽을 사용하든 Mac의 Necto 앱이
실행 중이어야 해요.

인증 연결은 키체인 승인 시간을 포함해 최대 2분 동안 기다려요. 여러 앱이나
기기가 같은 개인키를 쓰면 서명 요청을 하나씩 처리해요.

```bash
necto-cli device list --json
necto-cli plugin list --device <device-id> --app com.example.internal-app --json
```

첫 번째 명령에서 `<device-id>`를 확인해 두 번째 명령에 넣으세요.
해당 앱이 `connected` 상태이고 플러그인 목록이 나오면 연결된 거예요.

인증 전에는 앱 목록에 `unauthorized`가 표시돼요. 해당 앱의 플러그인 조회,
도움말, 명령 실행, 구독은 모두 `UNAUTHORIZED`로 거부돼요.
다른 앱과 데스크톱 플러그인은 계속 사용할 수 있어요.

## 연결되지 않을 때

Necto의 **인증되지 않음** 행을 누르면 이유를 확인할 수 있어요.

| 이유 | 확인할 것 |
| --- | --- |
| `missingKey` | 해당 앱의 정확한 `bundleID`로 Mac 사용자의 기본 키체인에 키를 등록했는지 확인하세요. |
| `rejectedKey` | 앱의 공개키와 Mac의 개인키가 짝이 맞는지 확인하세요. 맞는데도 TLS 연결에 실패하면 연결 상태도 확인하세요. |
| `credentialUnavailable` | 기본 키체인이 잠겨 있지 않은지, 앱 등록 정보·인증서·개인키가 모두 있는지, 실행 중인 Necto에 키 사용 권한이 있는지 확인하세요. |

등록을 다시 실행해 중복 오류가 나면 기존 키는 그대로 남아 있어요.
교체가 필요하면 설정 도구는 자신이 등록한 항목을 삭제한 뒤 다시 등록하거나
접근 권한을 갱신해야 해요. `install`을 다시 호출해도 기존 키를 덮어쓰지는 않아요.

## 보호 범위

공개키를 설정한 앱에는 두 가지 보호가 적용돼요.

- **접근 제한:** 올바른 개인키가 없으면 GUI와 CLI 모두 해당 앱을 디버깅할 수
  없어요. 인증에 실패하면 연결을 종료해요.
- **통신 암호화:** 인증 후에는 플러그인 정보, 데이터, 명령을 TLS 1.3으로
  암호화해서 주고받아요. 인증에 실패했다고 암호화 없는 연결을 허용하지는 않아요.

앱은 접속한 Mac이 올바른 개인키를 가졌는지 확인해요.

개인키는 허용된 사용자에게만 배포하세요. 같은 키를 공유하면 특정 사용자만
차단할 수 없어요. 키가 유출되면 앱의 공개키와 Mac의 개인키를 함께 교체해야 해요.

::: details 암호화 범위와 키 관리 세부 사항

앱 이름, `bundleID`, 기기 이름 등은 연결할 앱을 찾을 때 써요.
이 정보는 인증 전에 전달하므로 암호화하지 않아요. Mac의 GUI와 CLI는
로컬 소켓으로 통신하며 여기에 TLS를 추가하지 않아요.

SDK는 인증서의 공개키가 앱에 설정한 값과 일치하는지 확인해요. 인증서의
발급자, 호스트 이름, 만료일은 확인하지 않아요. 인증서만 갱신하고 키를
유지하면 앱의 공개키 설정도 유지할 수 있어요.

키체인은 저장된 개인키의 내보내기를 막아요. 설정 도구 속의 개인키
원본까지 숨겨주지는 않아요. 난독화한 도구라도 개인키가 들어 있다면
허용된 사용자에게만 배포하세요.

:::
