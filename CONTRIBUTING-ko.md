# Necto에 기여하기

[English](CONTRIBUTING.md) | 한국어

Necto에 관심을 가져 주셔서 감사해요. 이슈와 풀 리퀘스트를 작성하는 방법을 안내해요.

## 참고 문서

- 아키텍처와 모듈 경계 — [docs/ko/architecture.md](docs/ko/architecture.md)
- 변경이 지켜야 할 규칙 — [docs/ko/harness.md](docs/ko/harness.md)
- 변경을 검증하는 방법 — [docs/ko/verification.md](docs/ko/verification.md)
- 플러그인 매니페스트와 브리지 계약 — [docs/ko/plugin-manifest.md](docs/ko/plugin-manifest.md)
- 플러그인이 Necto에 요청할 수 있는 것 — [docs/ko/bridges.md](docs/ko/bridges.md)
- 디자인 토큰, 다크 모드, 접근성 — [docs/ko/design.md](docs/ko/design.md)

## 영어로 작성하기

코드, 주석, 문서, 커밋 메시지는 영어로 작성해요. 문서는 필요하면 한국어 번역을 함께 둘 수 있어요.

## 이슈

버그 신고나 기능 제안은 이슈로 남겨 주세요.
보안 취약점은 [보안 정책](SECURITY.md)에 따라 악용 방법이나 민감한 데이터를 공개하지 않고 문의해 주세요.
버그 리포트에는 Necto 버전, macOS 버전, 타깃 연결 방식(USB 실기기 또는 시뮬레이터), 재현 방법이 필요해요.

Necto의 기능 화면은 웹 플러그인이에요. 새 기능을 제안할 때는 셸·SDK·런타임 변경에
앞서 플러그인으로 구현할 수 있는지 검토해 주세요.

## 풀 리퀘스트

1. 저장소를 포크한 뒤 포크한 저장소를 로컬에 클론해요.

2. `main`에서 브랜치를 만들어요. 브랜치 이름은 `feature/<topic>`,
   `fix/<topic>`, `docs/<topic>`처럼 의도가 드러나게 지어요.

3. 코드를 수정하고 범위에 맞는 검증을 실행해요. 어떤 변경에 어떤 검증이
   필요한지는 [docs/ko/verification.md](docs/ko/verification.md)에 있어요.

4. 브랜치를 포크에 푸시하고 이 저장소의 `main`을 대상으로 풀 리퀘스트를
   열어요. 템플릿의 Test Plan 섹션을 채워 주세요.

### 큰 변경은 이슈에서 먼저 논의해요

다음 변경은 이슈에서 메인테이너와 방향을 합의한 뒤 작업해 주세요.

- 새 내장 플러그인을 추가하거나, 기존 플러그인의 매니페스트에 새 오퍼레이션을
  추가하는 변경

- 와이어 프로토콜, 컨트롤 소켓, SDK의 공개 API처럼 연결된 앱이나 CLI가
  의존하는 인터페이스를 바꾸는 변경

- [docs/ko/bridges.md](docs/ko/bridges.md) 기준으로 브리지를 추가하거나 브리지
  계약을 바꾸는 변경

- 토큰, `WebPackages/Bridge/*.css`, 갤러리처럼 모든 플러그인에 영향을 주는 디자인
  시스템 변경

- [docs/ko/architecture.md](docs/ko/architecture.md)에 그려진 모듈 경계를 넘어
  코드를 옮기는 변경

이슈에는 해결하려는 문제, 수정 방향, 변경할 영역(디바이스 플러그인, 데스크톱 플러그인, 코어)을 적어 주세요.

재현 방법이 있는 버그 수정, 문서 수정, 테스트 추가, 한 모듈 안의 작은 개선처럼 그 밖의 변경은 이슈 없이 바로 풀 리퀘스트를 열어 주세요.

## 라이선스

Necto에 기여하는 것은 기여한 내용을 [MIT 라이선스](LICENSE)로 배포하는 데 동의한다는 뜻이에요.
