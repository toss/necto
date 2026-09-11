# 데스크톱 플러그인 배포하기

`manifest.json`과 웹 에셋이 루트에 있는 ZIP을 GitHub 릴리스에 첨부해요.
빌드와 패키징은 macOS가 아닌 환경에서도 할 수 있어요.

설치하는 사람은 Necto의 Settings → Desktop Plugins에 저장소 주소를 붙여넣어요.

디바이스 플러그인은 이렇게 배포하지 않아요. 태그에 달린 Swift 패키지로 앱에
들어가니까, 이쪽은 태그가 곧 릴리스예요.

## 태그로 배포하기

`create-necto-plugin`이 새 데스크톱 프로젝트에 `.github/workflows/release.yml`을
만들어 줘요. `public/manifest.json`에 새 버전을 적고 태그를 푸쉬하면 돼요.

```bash
git tag v0.1.1 && git push --tags
```

워크플로가 플러그인을 빌드하고 태그와 manifest를 대조한 뒤 `dist/`를 zip으로 묶어
릴리스를 만들어요. GitHub이 제공하는 토큰을 사용하며 러너에 `zip`, `jq`, `gh`가
설치되어 있어 추가 설정은 필요 없어요.

태그는 manifest 버전과 같아야 하며 다르면 워크플로가 멈춰요.
Necto는 manifest 버전으로 업데이트를 확인하므로 태그만 바꿔서는
업데이트로 표시되지 않아요.

## 직접 배포하기

```bash
npm run build
cd dist && zip -r ../my-plugin.zip . && cd ..
gh release create v0.1.1 my-plugin.zip
```

아카이브 이름은 상관없어요. `manifest.json`이 루트에 있고, 그 안의 버전이
올라갔으면 돼요.

Necto가 설치돼 있다면 `necto-cli`가 배포 전에 플러그인을 검사해 줘요. 앱이 설치할 때
쓰는 manifest 타입을 그대로 사용해요.

```bash
necto-cli plugin pack dist
```

`necto.device.*`에 바인딩하는 패널은 거부해요. `pack`은 데스크탑 플러그인만
다루며 디바이스 플러그인은 앱의 Swift 패키지로 배포해요.
검사를 통과하면 다음에 실행할 `gh` 명령어를 출력해요.

배포 전에 설치를 시험하려면 Necto를 실행한 상태에서 로컬 폴더나 ZIP을 전달하세요.

```bash
necto install dist --local --json
necto install ./my-plugin.zip --local
```

Necto 승인 창에서 출처와 브리지를 확인하면 설치 완료 후 결과를 반환해요.
`--json`은 도구가 읽을 수 있는 결과를 출력해요. 실행 중인 앱과 CLI 모두 이 명령을
지원하는 버전이어야 해요.

같은 명령으로 GitHub 저장소에서도 설치할 수 있어요.

```bash
necto install owner/plugins --json
necto install https://github.com/owner/plugins --remote
necto install https://github.com/owner/plugins/releases/tag/v1.2.0
```

앱이 릴리스를 조회하고 플러그인 아카이브를 내려받아요. 여러 플러그인이 있으면
Necto에서 하나를 선택해 승인해요. 업데이트를 위해 저장소 출처를 기록하고,
CLI는 선택한 플러그인의 설치가 끝날 때까지 기다려요.
비공개·Enterprise 저장소는 기존 GUI 릴리스 설치와 같은 인증 조건을 적용해요.

기본값은 원격 설치이며 `--remote`는 생략할 수 있어요. `--local`과 함께 사용할 수는 없어요.
Settings → About의 명령을 복사해 실행하면 `necto`와 호환 이름인 `necto-cli`를
`PATH`에 등록해요. 앱 업데이트 후 기존 이름만 있다면 해당 명령을 다시 실행하세요.

시험 설치를 제거하려면 `necto plugin list --desktop`에서 ID를 확인한 뒤
`necto delete <pluginID> --json`을 실행하세요. 설치 폴더를 휴지통으로 옮기고 등록을
해제하며 권한을 회수해요. 설치 원본 폴더나 저장소는 제거하지 않아요.
별칭, 응답, 취소 동작은 [CLI 가이드](control-socket.md)를 참고하세요.

## 저장소 하나에서 여러 개 배포하기

플러그인마다 아카이브를 하나씩 붙이면 돼요. Necto가 릴리스에 무엇이 있는지 보여 주고
어느 것을 설치할지 물어봐요.

내려받기 전에 목록에 내용이 나오게 하려면, 각 플러그인의 `manifest.json`을 아카이브
이름에 맞춰 함께 붙이세요.

```
my-plugin-0.2.0.zip
my-plugin-0.2.0.manifest.json
other-plugin-0.2.0.zip
other-plugin-0.2.0.manifest.json
```

manifest 파일을 별도로 첨부하지 않아도 설치할 수 있어요. 목록에는 파일 이름을
표시하고 승인 화면에서 플러그인 정보를 보여 줘요. 다만 Necto는 첨부된 manifest의
버전을 비교하므로 이 파일이 없으면 업데이트를 확인할 수 없어요.

## 설치하는 사람이 보는 것

Necto는 플러그인의 출처와 바인딩한 브리지를 한 줄씩 표시해요.
브리지 설명은 Necto가 제공하며 새 브리지를 추가하는 업데이트는 다시 승인을 받아요.
설치를 승인하면 표시된 브리지 접근에 동의한 것으로 봐요.

권한은 정규화한 저장소 출처와 플러그인 ID를 함께 기준으로 삼아요.
같은 저장소의 서로 다른 ID는 권한을 공유하지 않고, 다른 저장소의 같은 ID도 구분해요.
로컬 폴더나 ZIP은 Necto가 만든 설치 UUID와 플러그인 ID를 사용해요.
출처가 바뀌면 권한 주체도 바뀌며 이전 출처의 권한을 이어받지 않아요.

## 사람들이 찾게 하기

중앙 레지스트리는 없고 만들 계획도 없어요. 저장소에 `necto-plugin` 토픽을 달아 두면
그 토픽에서 찾을 수 있어요. README에는 설치 방법을 적어 두세요.

```
Settings → Desktop Plugins → Install from GitHub → your-name/your-plugin
```
