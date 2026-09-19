# Necto

[English](README.md) | 한국어

Necto는 어떤 환경에서든 바로 연결되는 iOS 디버깅 플랫폼이에요.  
무엇이든 플러그인으로 만들어 내 도구로 써요. Flipper의 현대적인 대안이에요.

![Performance 플러그인에서 CPU, 메모리, 프레임률을 보여주는 Necto 화면](docs/images/necto.png)

- USB로 연결한 기기나 iOS 시뮬레이터의 앱에 연결해요. SDK가 앱 안에서 동작하기
  때문에 프록시를 설정하거나 인증서를 신뢰시킬 필요가 없어요
  ([docs/ko/setup.md](docs/ko/setup.md)).
- iOS 개발에 필요한 모든 것을 플러그인으로 만들 수 있어요. 디바이스 플러그인은 앱에
  실려서 앱이 연결되면 패널이 Necto에 표시되고, 데스크톱 플러그인은 GitHub 릴리스,
  폴더나 ZIP으로 설치해 연결된 앱 없이도 동작해요
  ([docs/ko/plugin-manifest.md](docs/ko/plugin-manifest.md)).
- Necto가 하는 모든 일을 CLI로 할 수 있어요. 플러그인을 설치·삭제하고 브리지
  오퍼레이션을 호출하며, 스킬을 설치하면 AI가 직접 앱을 디버깅해요
  ([docs/ko/control-socket.md](docs/ko/control-socket.md)).
- 기능 화면은 `manifest.json`과 웹 에셋으로 구성된 웹 플러그인이에요.
  앱과 같은 디자인 토큰을 사용해요([docs/ko/design.md](docs/ko/design.md)).
- Mac 앱과 SDK는 Swift를, 플러그인 화면은 웹 기술을 사용해요.
  Mac 앱이 연결과 실행을 담당하며 별도의 서버 프로세스는 없어요
  ([docs/ko/architecture.md](docs/ko/architecture.md)).

## 시작하기

[Releases](https://github.com/toss/necto/releases)에서 DMG를 내려받아
Necto를 응용 프로그램 폴더로 옮기세요. 체크섬 확인과 ad-hoc 서명 정책은
[설치 안내](docs/ko/install.md)에 있어요.

소스에서 빌드하려면 macOS 14 이상, Swift 6.0 이상을 지원하는 Xcode,
Node.js 22.12 이상과 Yarn 4.6.0이 필요해요. iOS SDK는 iOS 16 이상을 지원해요.

```bash
script/build   # 웹 패키지, Swift 패키지, 앱 순서로 빌드
script/test    # 단위 테스트와 정적 검사
open Build/Products/Debug/Necto.app
```

웹 패키지를 빌드한 뒤 `Necto.xcodeproj`를 열어 `Necto` 스킴을 실행해도 돼요.
`script/build`로 `ExampleApp`도 빌드하려면 스크립트 실행 전에 iOS 시뮬레이터를
켜두세요.

앱에 SDK를 연동하고 Release 빌드에서 SDK 호출을 제외하는 방법은
[docs/ko/setup.md](docs/ko/setup.md)를 참고하세요.

## 플러그인 만들기

`create-necto-plugin`과 `@necto/bridge` 배포 파일이 포함된 [공개 릴리스](https://github.com/toss/necto/releases)를
선택하세요. 아래 예제는 `0.1.0`으로 고정되어 있어요.

```bash
NECTO_VERSION=0.1.0
npx --yes \
  --package="https://github.com/toss/necto/releases/download/${NECTO_VERSION}/create-necto-plugin-${NECTO_VERSION}.tgz" \
  create-necto-plugin Uptime --type device
```

웹으로만 동작하는 플러그인은 `--type desktop`을 사용하세요. 디바이스 프로젝트에는
Swift 패키지, Xcode 프로젝트, ExampleApp과 웹 패널 소스가 들어 있어요.

## 문서

- 플러그인 만들기: [데스크톱](docs/ko/tutorial-desktop.md) · [디바이스](docs/ko/tutorial-device.md)
- 플러그인 규격: [매니페스트](docs/ko/plugin-manifest.md) · [ID와 신뢰 기준](docs/ko/plugin-manifest.md#identity-and-trust)
- 브리지 참고: [지원 오퍼레이션](docs/ko/bridges.md) · [웹 API(영문)](WebPackages/Bridge/README.md) · [셸 접근](docs/ko/bridges.md#shell-access)
- [CLI 사용법](docs/ko/control-socket.md)
- 기여자 안내: [아키텍처](docs/ko/architecture.md) · [디자인](docs/ko/design.md) · [검증](docs/ko/verification.md)

## 기여하기

이슈와 풀 리퀘스트를 환영해요.
[기여 안내](CONTRIBUTING-ko.md)([English](CONTRIBUTING.md))를 참고하세요.

## 라이선스

MIT © Viva Republica, Inc. 자세한 내용은 [LICENSE](LICENSE)를 참고하세요.
