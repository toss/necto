//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { createTranslator } from "@necto/bridge";

export const t = createTranslator({
  ko: {
    "Desktop Shell Demo": "데스크톱 셸 데모",
    Waiting: "대기 중",
    Connected: "연결됨",
    "Exact command": "정확한 명령어",
    "Command approval compares this exact string. Change one character to make it a different command.": "명령별 승인은 이 문자열 전체를 비교합니다. 한 글자만 달라져도 다른 명령어입니다.",
    "Request approval": "승인 요청",
    "Request Full Access": "전체 허용 요청",
    "Allow every Shell Demo command?": "Shell Demo의 모든 명령을 허용할까요?",
    "Full Access lets this plugin run any shell command without asking again. Use it only to verify the broad permission flow.": "전체 허용은 이 플러그인이 다시 묻지 않고 모든 셸 명령어를 실행할 수 있게 합니다. 넓은 권한 흐름을 검증할 때만 사용하세요.",
    "All commands": "모든 명령어",
    "Allow the Shell Demo greeting?": "Shell Demo 인사 명령을 허용할까요?",
    "The demo uses printf to prove an approved command reaches Bash and returns stdout.": "이 데모는 printf 명령으로 승인된 명령어가 Bash까지 전달되고 stdout이 돌아오는지 확인합니다.",
    "Run command": "명령 실행",
    "Try unapproved command": "미승인 명령 실행",
    "Last result": "최근 결과",
    "Not run yet": "아직 실행하지 않았습니다",
    "Verification flow": "검증 순서",
    "Run first to see PERMISSION_DENIED in Protected mode.": "먼저 실행해 보호 모드의 PERMISSION_DENIED를 확인합니다.",
    "Request approval and accept the native Necto dialog.": "승인을 요청하고 Necto 네이티브 다이얼로그에서 허용합니다.",
    "Run again to see stdout and exitCode 0.": "다시 실행해 stdout과 exitCode 0을 확인합니다.",
    "Try the unapproved command to prove exact matching.": "미승인 명령을 실행해 정확한 문자열 비교를 확인합니다.",
    Notice: "알림",
    "This plugin only works inside Necto": "이 플러그인은 Necto 안에서만 동작합니다.",
  },
});
