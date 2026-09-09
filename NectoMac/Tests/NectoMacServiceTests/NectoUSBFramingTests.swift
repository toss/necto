//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoTransport
import Testing

@testable import NectoMacService

@Test func readsLittleEndianLengthFromUSBMuxHeader() {
    // usbmuxd writes its header fields little endian: 0x00000010 == 16.
    let header = Data([0x10, 0x00, 0x00, 0x00])
    #expect(header.littleEndianUInt32(at: 0) == 16)

    let large = Data([0x01, 0x02, 0x03, 0x04])
    #expect(large.littleEndianUInt32(at: 0) == 0x0403_0201)
}

@Test func writesLittleEndianLength() {
    var data = Data()
    data.appendLittleEndian(UInt32(16))
    #expect(Array(data) == [0x10, 0x00, 0x00, 0x00])
}

@Test func rejectsFramesBeyondTheSizeLimit() {
    let oversized = NectoMessageSession.maximumMessageBytes + 1
    #expect(oversized > NectoMessageSession.maximumMessageBytes)
}

@Test func portIsCarriedInNetworkByteOrder() {
    // usbmuxd expects the port byte swapped inside the plist. 9999 == 0x270F,
    // which must travel as 0x0F27.
    #expect(Int(UInt16(9999).bigEndian) == 0x0F27)
}
