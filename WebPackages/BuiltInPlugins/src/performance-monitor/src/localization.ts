//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { createTranslator } from "@necto/bridge";

export const t = createTranslator({
  ko: {
    "1 m": "1분",
    "5 m": "5분",
    "1 h": "1시간",
    "Live while this panel is open": "패널이 열려 있는 동안 실시간으로 측정해요",
    "not enough readings yet": "아직 측정값이 부족해요",
    steady: "변화 없음",
    "{direction} {value} {unit} in {minutes} m": "{minutes}분 동안 {direction} {value} {unit}",
    "Nothing measured yet": "아직 측정된 항목이 없어요",
    "The connected app decides which metrics and sampler to provide.": "연결된 앱이 제공할 측정 항목과 수집 방식을 결정해요.",
    "▼ under {budget} {unit}": "▼ {budget} {unit} 미만",
    "▲ over {budget} {unit}": "▲ {budget} {unit} 초과",
    Memory: "메모리",
    "{footprint} MB footprint · {resident} MB resident": "footprint {footprint} MB · 상주 {resident} MB",
    "Memory detail unavailable": "메모리 상세 정보를 사용할 수 없어요",
    "This plugin only works inside Necto": "이 플러그인은 Necto 안에서만 동작해요.",
    CPU: "CPU",
    "Frame rate": "프레임률",
    "Frame time": "프레임 시간",
    "App hangs": "앱 멈춤",
  },
});
