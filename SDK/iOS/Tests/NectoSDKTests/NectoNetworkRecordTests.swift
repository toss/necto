//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Testing

@testable import NectoNetworkPlugin

@Suite("Network record")
struct NectoNetworkRecordTests {
    private let limit = NectoNetworkRecord.Body.captureLimit

    @Test("keeps the text of a body that fits")
    func keepsWholeText() {
        let body = NectoNetworkRecord.Body(data: Data(#"{"name":"네트워크"}"#.utf8), contentType: "application/json")

        #expect(body.text == #"{"name":"네트워크"}"#)
        #expect(body.isTruncated == false)
    }

    /// The cap is a byte count, and a character of two to four bytes can straddle it.
    /// The bytes left over must not cost a large response its text.
    @Test("keeps the text of a body cut inside a character", arguments: ["é", "한", "🙂"])
    func keepsTextCutInsideACharacter(character: String) throws {
        for padding in 0..<character.utf8.count {
            let content = String(repeating: "a", count: padding) + String(repeating: character, count: limit)
            let body = NectoNetworkRecord.Body(data: Data(content.utf8), contentType: "application/json")

            #expect(body.isTruncated)
            #expect(body.byteCount == content.utf8.count)
            let text = try #require(body.text)
            #expect(content.hasPrefix(text))
            #expect(text.utf8.count > limit - 4)
        }
    }

    @Test("keeps no text for a body that is not UTF-8")
    func dropsBinaryText() {
        var bytes = Data(repeating: UInt8(ascii: "a"), count: limit - 1)
        bytes.append(contentsOf: [0xFF, 0x00, 0x01])

        #expect(NectoNetworkRecord.Body(data: bytes, contentType: "text/plain").text == nil)
        #expect(NectoNetworkRecord.Body(data: Data([0xFF, 0xFE]), contentType: nil).text == nil)
        // Whole, and still ending inside a character: nothing was cut, so it is not text.
        #expect(NectoNetworkRecord.Body(data: Data([0x61, 0xED, 0x95]), contentType: "text/plain").text == nil)
    }

    @Test("reads a cut head wherever its bytes start and however few there are")
    func readsShortAndSlicedHeads() {
        #expect(String(utf8Head: Data()) == "")
        #expect(String(utf8Head: Data([0xED])) == "")
        #expect(String(utf8Head: Data([0xF0, 0x9F, 0x99])) == "")
        #expect(String(utf8Head: Data([0x61, 0xF0, 0x9F])) == "a")
        // A complete character followed by a byte that continues nothing.
        #expect(String(utf8Head: Data([0xC3, 0xA9, 0xA9])) == nil)

        let sliced = Data([0xFF, 0xFF, 0x61, 0xED, 0x95]).dropFirst(2)
        #expect(String(utf8Head: sliced) == "a")
    }
}
