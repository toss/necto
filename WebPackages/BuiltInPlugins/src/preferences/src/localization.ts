//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { createTranslator } from "@necto/bridge";

export const t = createTranslator({
  ko: {
    "Filter keys": "키 필터",
    "{shown} of {total}": "{total}개 중 {shown}개",
    "Nothing matches": "일치하는 항목이 없습니다",
    "Nothing stored": "저장된 값이 없습니다",
    "No key contains that text.": "해당 텍스트를 포함하는 키가 없습니다.",
    "Keys the app stores appear here.": "앱이 저장한 키가 여기에 표시됩니다.",
    Key: "키",
    Type: "타입",
    Value: "값",
    "Resize the detail pane": "상세 패널 크기 조절",
    "Close details": "상세 닫기",
    "Loading…": "불러오는 중…",
    Delete: "삭제",
    "Really delete?": "정말 삭제할까요?",
    Copy: "복사",
    Copied: "복사됨",
    Failed: "실패",
    "Not a valid {type}": "올바른 {type} 값이 아닙니다",
    "Item {index}": "항목 {index}",
    "Remove item": "항목 삭제",
    "+ Add item": "+ 항목 추가",
    "Remove pair": "키-값 삭제",
    "+ Add pair": "+ 키-값 추가",
    "A pair is missing its key": "키가 비어 있는 항목이 있습니다",
    "Duplicate key '{key}'": "중복된 키 '{key}'",
    "{value} — not editable from here": "{value} — 여기서는 편집할 수 없습니다",
    Suite: "저장소",
    Save: "저장",
    "This plugin only works inside Necto": "이 플러그인은 Necto 안에서만 동작합니다.",
  },
});
