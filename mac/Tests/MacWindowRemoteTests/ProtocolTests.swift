import Foundation
import Testing
@testable import MacWindowRemote

@Suite struct ProtocolTests {
    @Test func binaryFramingRoundTrip() throws {
        let header = FrameHeader(
            frameId: 57, windowId: 1234, width: 2560, height: 1600,
            content: Rect(x: 0, y: 0, w: 2560, h: 1600), window: Rect(x: 100, y: 80, w: 1280, h: 800))
        let headerData = try JSONEncoder().encode(header)
        let payload = Data([0xFF, 0xD8, 0x00, 0x01, 0xFF, 0xD9])
        let message = BinaryFraming.encode(header: headerData, payload: payload)
        #expect(Array(message.prefix(4)) == [0, 0, UInt8(headerData.count >> 8), UInt8(headerData.count & 0xFF)])
        let decoded = try BinaryFraming.decode(message)
        #expect(try JSONDecoder().decode(FrameHeader.self, from: decoded.header) == header)
        #expect(decoded.payload == payload)
        // Works on a slice whose indices do not start at 0.
        let sliced = (Data([9, 9]) + message).dropFirst(2)
        #expect(try BinaryFraming.decode(sliced).payload == payload)
    }

    @Test func binaryFramingRejectsTruncated() {
        #expect(throws: ProtocolError.malformed) { try BinaryFraming.decode(Data([0, 0])) }
        #expect(throws: ProtocolError.malformed) { try BinaryFraming.decode(Data([0, 0, 0, 10, 1, 2])) }
    }

    func decode(_ json: String) throws -> ClientMessage {
        try ClientMessage.decode(Data(json.utf8))
    }

    @Test func decodesSliceOneMessages() throws {
        #expect(try decode(#"{"t":"auth","secret":"abc","client":"web/0.1"}"#) == .auth(secret: "abc"))
        #expect(try decode(#"{"t":"windows.list"}"#) == .windowsList)
        #expect(try decode(#"{"t":"view.start","windowId":1234}"#) == .viewStart(windowId: 1234))
        #expect(try decode(#"{"t":"frame.ack","frameId":57}"#) == .frameAck(frameId: 57))
        #expect(try decode(#"{"t":"pointer","action":"doubleClick","u":0.42,"v":0.13,"frameId":57}"#)
                == .pointer(action: .doubleClick, u: 0.42, v: 0.13, frameId: 57))
        #expect(try decode(#"{"t":"scroll","u":0.5,"v":0.5,"du":0.0,"dv":-0.03,"frameId":57}"#)
                == .scroll(u: 0.5, v: 0.5, du: 0, dv: -0.03, frameId: 57))
        #expect(try decode(#"{"t":"text","text":"日本語"}"#) == .text("日本語"))
        #expect(try decode(#"{"t":"key","key":"Backspace"}"#) == .key(name: "Backspace"))
    }

    @Test func rejectsInvalidMessages() {
        #expect(throws: ProtocolError.malformed) { try decode("not json") }
        #expect(throws: ProtocolError.unknownType("nope")) { try decode(#"{"t":"nope"}"#) }
        #expect(throws: ProtocolError.invalidValue("u")) { try decode(#"{"t":"pointer","action":"click","u":1.5,"v":0.1}"#) }
        #expect(throws: ProtocolError.invalidValue("action")) { try decode(#"{"t":"pointer","action":"hover","u":0.5,"v":0.1}"#) }
        #expect(throws: ProtocolError.invalidValue("key")) { try decode(#"{"t":"key","key":"Launch"}"#) }
        #expect(throws: ProtocolError.invalidValue("windowId")) { try decode(#"{"t":"view.start"}"#) }
    }
}
