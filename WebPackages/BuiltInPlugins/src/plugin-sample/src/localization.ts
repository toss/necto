//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { createTranslator } from "@necto/bridge";

export const t = createTranslator({
  ko: {
    Bridge: "브릿지",
    States: "상태",
    Context: "컨텍스트",
    "Loading…": "불러오는 중…",
    "Query · host.info": "쿼리 · host.info",
    Run: "실행",
    "Not run yet": "아직 실행하지 않았습니다",
    "Stream · host.ticks": "스트림 · host.ticks",
    Start: "시작",
    Stop: "중지",
    "0 events": "이벤트 0개",
    "Not started": "시작하지 않았습니다",
    "Make it fail": "실패 상태 만들기",
    "Every refusal below is real: the call is made and Necto turns it down. This is what a plugin's error handling has to survive.": "아래 거절은 모두 실제 호출 결과입니다. Necto가 요청을 거절할 때 플러그인의 오류 처리가 견뎌야 하는 상태를 보여줍니다.",
    "Unknown operation": "알 수 없는 오퍼레이션",
    "Bad input": "잘못된 입력",
    Empty: "비어 있음",
    "Nothing to show": "표시할 내용이 없습니다",
    "What a plugin looks like before its first result.": "플러그인이 첫 결과를 받기 전의 모습입니다.",
    failed: "실패",
    "{count} event": "이벤트 {count}개",
    "{count} events": "이벤트 {count}개",
    "Necto allowed it. That is itself worth knowing.": "Necto가 요청을 허용했습니다. 이것도 확인할 가치가 있습니다.",
    Notice: "알림",
    "This plugin only works inside Necto": "이 플러그인은 Necto 안에서만 동작합니다.",
    "none selected": "선택되지 않음",
  },
});
