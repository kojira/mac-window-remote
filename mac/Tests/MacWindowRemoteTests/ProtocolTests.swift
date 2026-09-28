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

    @Test func decodesMessages() throws {
        #expect(try decode(#"{"t":"windows.list"}"#) == .windowsList)
        #expect(try decode(#"{"t":"view.start","windowId":1234}"#) == .viewStart(windowId: 1234))
        #expect(try decode(#"{"t":"frame.ack","frameId":57}"#) == .frameAck(frameId: 57))
        #expect(try decode(#"{"t":"text","text":"日本語"}"#) == .text("日本語"))
        #expect(try decode(#"{"t":"key","key":"Backspace"}"#) == .key(name: "Backspace"))
    }

    /// D28 input messages.
    @Test func decodesTrackpadInput() throws {
        #expect(try decode(#"{"t":"move","seq":812,"dx":0.0123,"dy":-0.004}"#) == .move(seq: 812, dx: 0.0123, dy: -0.004))
        #expect(try decode(#"{"t":"scroll","du":0.0,"dv":-0.03}"#) == .scroll(du: 0, dv: -0.03))
        #expect(try decode(#"{"t":"click"}"#) == .click)
        #expect(try decode(#"{"t":"rightClick"}"#) == .rightClick)
        #expect(try decode(#"{"t":"drag","state":"start"}"#) == .drag(start: true))
        #expect(try decode(#"{"t":"drag","state":"end"}"#) == .drag(start: false))
        #expect(try decode(#"{"t":"move","seq":0,"dx":1,"dy":-1}"#) == .move(seq: 0, dx: 1, dy: -1))
    }

    @Test func rejectsInvalidMessages() {
        #expect(throws: ProtocolError.malformed) { try decode("not json") }
        #expect(throws: ProtocolError.unknownType("nope")) { try decode(#"{"t":"nope"}"#) }
        #expect(throws: ProtocolError.unknownType("pointer")) { try decode(#"{"t":"pointer","action":"click","u":0.5,"v":0.1}"#) }
        #expect(throws: ProtocolError.invalidValue("key")) { try decode(#"{"t":"key","key":"Launch"}"#) }
        #expect(throws: ProtocolError.invalidValue("windowId")) { try decode(#"{"t":"view.start"}"#) }
        #expect(throws: ProtocolError.invalidValue("state")) { try decode(#"{"t":"drag","state":"middle"}"#) }
        #expect(throws: ProtocolError.invalidValue("state")) { try decode(#"{"t":"drag"}"#) }
    }

    /// D28: deltas must be finite and within [-1, 1]; seq is a non-negative integer.
    @Test func rejectsOutOfRangeDeltas() {
        #expect(throws: ProtocolError.invalidValue("dx")) { try decode(#"{"t":"move","seq":1,"dx":1.5,"dy":0}"#) }
        #expect(throws: ProtocolError.invalidValue("dy")) { try decode(#"{"t":"move","seq":1,"dx":0,"dy":-1.01}"#) }
        #expect(throws: ProtocolError.invalidValue("dx")) { try decode(#"{"t":"move","seq":1,"dy":0}"#) }
        #expect(throws: ProtocolError.invalidValue("seq")) { try decode(#"{"t":"move","seq":-1,"dx":0,"dy":0}"#) }
        #expect(throws: ProtocolError.malformed) { try decode(#"{"t":"move","seq":1.5,"dx":0,"dy":0}"#) }
        #expect(throws: ProtocolError.invalidValue("du")) { try decode(#"{"t":"scroll","du":2,"dv":0}"#) }
        #expect(throws: ProtocolError.invalidValue("dv")) { try decode(#"{"t":"scroll","du":0,"dv":-3}"#) }
        // JSON has no NaN/Infinity literal; a huge exponent overflows to a non-finite or is rejected.
        #expect(throws: (any Error).self) { try decode(#"{"t":"scroll","du":1e400,"dv":0}"#) }
    }

    @Test func motionMessagesAreRecognizedForSilentDrop() {
        #expect(ClientMessage.isMotion(Data(#"{"t":"move","seq":1,"dx":9,"dy":0}"#.utf8)))
        #expect(ClientMessage.isMotion(Data(#"{"t":"scroll"}"#.utf8)))
        #expect(!ClientMessage.isMotion(Data(#"{"t":"click"}"#.utf8)))
        #expect(!ClientMessage.isMotion(Data("junk".utf8)))
    }
}
