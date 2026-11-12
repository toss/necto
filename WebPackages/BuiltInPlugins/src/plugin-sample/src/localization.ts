//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { createTranslator } from "@necto/bridge";

export const t = createTranslator({
  ko: {
    Bridge: "브리지",
    States: "상태",
    Context: "컨텍스트",
    "Loading…": "불러오는 중…",
    "Query · host.info": "쿼리 · host.info",
    Run: "실행",
    "Not run yet": "아직 실행하지 않았어요",
    "Stream · host.ticks": "스트림 · host.ticks",
    Start: "시작",
    Stop: "중지",
    "0 events": "이벤트 0개",
    "Not started": "시작하지 않았어요",
    "Make it fail": "실패 상태 만들기",
    "Every refusal below is real: the call is made and Necto turns it down. This is what a plugin's error handling has to survive.": "실제로 요청을 보내고 거절된 결과를 표시해요. 플러그인의 오류 처리를 확인해 주세요.",
    "Unknown operation": "알 수 없는 오퍼레이션",
    "Bad input": "잘못된 입력",
    Empty: "비어 있음",
    "Nothing to show": "표시할 내용이 없어요",
    "What a plugin looks like before its first result.": "플러그인이 첫 결과를 받기 전의 모습이에요.",
    failed: "실패",
    "{count} event": "이벤트 {count}개",
    "{count} events": "이벤트 {count}개",
    "Necto allowed it. That is itself worth knowing.": "Necto가 요청을 허용했어요.",
    Notice: "알림",
    "This plugin only works inside Necto": "이 플러그인은 Necto 안에서만 동작해요.",
    "none selected": "선택되지 않음",
  },
});
