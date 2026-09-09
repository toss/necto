# Necto 앱 설치하기

배포된 Mac 앱을 설치하거나 소스에서 빌드한 뒤 SDK를 연동한 앱을 연결해요.

앱에 아직 SDK를 연결하지 않았다면 [앱에 Necto 연결하기](setup.md)부터
시작하세요. Mac 앱에서 데이터를 보려면 SDK를 연동한 앱이 필요해요.
함께 제공하는 예제 앱으로 시작해도 돼요.

## 배포된 앱 설치하기

[릴리스 페이지](https://github.com/toss/toss-necto/releases)에서
`Necto-<version>.dmg`를 내려받아 열고 Necto를 Applications로 옮기세요.
무결성을 직접 확인하려면 `shasum -a 256 Necto-<version>.dmg` 결과를
GitHub가 해당 파일에 표시하는 SHA-256 값과 비교하세요. 체크섬은 다운로드가
일치하는지 확인하는 값이며 게시자를 인증하지는 않아요.

앱과 내장 CLI는 회사 Developer ID 인증서나 Apple 공증 없이 ad-hoc 서명으로
배포해요. 저장소의 릴리스 페이지에서만 내려받으세요. Necto는 Gatekeeper를
우회하기 위해 시스템 보안 설정을 바꾸지 않아요.

앱 업데이트는 `gh`나 GitHub 로그인 없이 HTTPS로 받아요. 교체 전에 DMG의 해시를
GitHub 릴리스 파일의 `digest`와 비교하고, 새 앱의 서명 무결성, 번들 ID와
더 최신 버전인지 확인해요. ad-hoc 서명 앱도
업데이트할 수 있어요. 다만 이 검사는 파일 손상이나 다른 앱을 걸러내는 것으로,
저장소 계정이 탈취돼 악성 릴리스가 게시되는 경우까지 막지는 못해요.
업데이트는 릴리스 저장소를 신뢰하는 구조예요.

## 소스 빌드 요구 사항

- macOS 14 이상, Swift 6.0 이상을 제공하는 Xcode 툴체인이 필요해요.
- `script/build`를 실행하려면 Node.js 22.12.0 이상과 Yarn 4.6.0도 필요해요.

## 빌드하고 실행하기

```bash
git clone https://github.com/toss/toss-necto.git
cd toss-necto
corepack enable
script/build   # 웹 패키지, Swift 패키지, 앱 순서로 빌드
open Build/Products/Debug/Necto.app
```

`Necto.xcodeproj`를 열어 `Necto` 스킴을 실행해도 돼요. 빌드된 플러그인
결과물이 커밋되어 있어 앱만 빌드할 때는 Node가 필요 없어요.

## 앱 연결하기

**내 앱** — [setup.md](setup.md)대로 SDK를 연결했다면, 시뮬레이터에서
실행하거나 실기기를 USB로 연결하세요. 연결되면 Necto 사이드바에 앱이 나타나요.

**아직 앱이 없다면** — 시뮬레이터에서 예제 앱을 실행해요.

```bash
xcrun simctl list devices available          # 디바이스 id를 하나 골라요
xcrun simctl boot <device-id>
xcodebuild -project Necto.xcodeproj -scheme ExampleApp -derivedDataPath Build -destination "id=<device-id>" build
xcrun simctl install <device-id> Build/Products/Debug-iphonesimulator/ExampleApp.app
xcrun simctl launch <device-id> im.toss.necto.example
```

## 첫 요청 확인하기

사이드바에서 앱을 선택하고 **Network** 패널을 열어 보세요. 요청은 시작하는
순간 나타나고 끝나면 내용이 채워져요. 메서드, 상태, 크기, 시간이 최신순으로
보여요.

예제 앱의 **Plugin Sample** 패널에서는 브리지 호출과 거부된 요청의
응답을 확인할 수 있어요.

## 아무것도 나타나지 않는다면

- 시뮬레이터 앱은 Mac에서 `lsof -nP -iTCP:9979-9986 -sTCP:LISTEN`으로
  SDK의 기본 포트 범위를 확인해요. 시작 포트를 바꿨다면 해당 범위를 검사하세요.
- USB 실기기의 수신 소켓은 이 Mac 명령으로 볼 수 없어요. Xcode가 기기를 인식하는지,
  앱이 실행 중이고 SDK를 시작했는지 확인하세요. 개발용 빌드를 설치할 때는 Xcode나
  iOS가 안내하는 기기 신뢰·개발자 모드 설정을 완료해야 해요. 설치나 실행이 실패하면
  Xcode의 Signing & Capabilities를 확인하세요. SDK 연결보다 앞선 단계의 문제예요.
- 실기기에서 `connectionRefused`가 나오면 터널은 기기까지 연결됐지만 앱이
  수신 대기 중이지 않다는 뜻이에요. 앱이 실행 중이 아닐 때의 정상 응답이에요.
- 전체 체크리스트는 [verification.md](verification.md)에 있어요.

## 다음 단계

- [튜토리얼 1부](tutorial-desktop.md)에서 웹 파일 폴더 하나로 데스크톱 플러그인을 만들어 보세요.
