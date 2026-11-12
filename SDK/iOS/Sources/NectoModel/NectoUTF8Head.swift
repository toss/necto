//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

extension String {
    /// Reads the head of UTF-8 text that was cut at a byte count.
    ///
    /// A character takes up to four bytes, so a cut can land inside one and leave up
    /// to three bytes that are valid as far as they go but decode as nothing. Those are
    /// dropped. Anything else that is not UTF-8 still reads as no text at all.
    package init?(utf8Head head: Data) {
        if let text = String(data: head, encoding: .utf8) {
            self = text
            return
        }
        for length in 1...3 where length <= head.count {
            let byte = head[head.endIndex - length]
            // A continuation byte belongs to a character that started earlier.
            if byte & 0b1100_0000 == 0b1000_0000 { continue }
            // The first byte of a character says how long it is: the leading ones of
            // `110`, `1110` and `11110` count its two, three or four bytes. It was cut
            // only if that is more than the bytes that are here.
            guard (0xC2...0xF4).contains(byte), (~byte).leadingZeroBitCount > length,
                  let text = String(data: head.dropLast(length), encoding: .utf8) else { return nil }
            self = text
            return
        }
        return nil
    }
}
