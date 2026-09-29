import Foundation
import Testing
@testable import MacWindowRemote

@Suite struct ProtocolTests {
    func decode(_ json: String) throws -> ClientMessage {
        try ClientMessage.decode(Data(json.utf8))
    }

    @Test func decodesMessages() throws {
        #expect(try decode(#"{"t":"windows.list"}"#) == .windowsList)
        #expect(try decode(#"{"t":"view.start","windowId":1234}"#) == .viewStart(windowId: 1234))
        #expect(try decode(#"{"t":"text","text":"日本語"}"#) == .text("日本語"))
        #expect(try decode(#"{"t":"key","key":"Backspace"}"#) == .key(name: "Backspace", mods: []))
    }

    /// D34: `key` with optional `mods`, normalized to cmd, ctrl, opt, shift order.
    @Test func decodesKeyWithMods() throws {
        #expect(try decode(#"{"t":"key","key":"c","mods":["cmd"]}"#) == .key(name: "c", mods: [.cmd]))
        #expect(try decode(#"{"t":"key","key":"z","mods":["shift","cmd"]}"#) == .key(name: "z", mods: [.cmd, .shift]))
        #expect(try decode(#"{"t":"key","key":"F5","mods":[]}"#) == .key(name: "F5", mods: []))
        #expect(try decode(#"{"t":"key","key":"ArrowLeft","mods":["opt","ctrl"]}"#) == .key(name: "ArrowLeft", mods: [.ctrl, .opt]))
        #expect(throws: ProtocolError.invalidValue("mods")) { try decode(#"{"t":"key","key":"c","mods":["meta"]}"#) }
        #expect(throws: ProtocolError.invalidValue("mods")) { try decode(#"{"t":"key","key":"c","mods":["cmd","cmd"]}"#) }
        #expect(throws: ProtocolError.malformed) { try decode(#"{"t":"key","key":"c","mods":"cmd"}"#) }
        #expect(throws: ProtocolError.invalidValue("key")) { try decode(#"{"t":"key","key":"C","mods":["cmd"]}"#) }
        #expect(throws: ProtocolError.wrongChannel("key")) {
            try ClientMessage.decode(Data(#"{"t":"key","key":"c","mods":["cmd"]}"#.utf8), on: .socket)
        }
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

    /// D22/D28 signaling on the WebSocket.
    @Test func decodesSignaling() throws {
        #expect(try decode(#"{"t":"rtc.offer","pc":1,"sdp":"v=0"}"#) == .rtcOffer(pc: 1, sdp: "v=0"))
        #expect(try decode(#"{"t":"rtc.ice","pc":2,"candidate":"candidate:1 1 udp 1 host 9 typ host","sdpMid":"0","sdpMLineIndex":0}"#)
                == .rtcIce(pc: 2, candidate: RemoteCandidate(sdp: "candidate:1 1 udp 1 host 9 typ host", sdpMid: "0", sdpMLineIndex: 0)))
        #expect(try decode(#"{"t":"rtc.ice","pc":2,"candidate":null}"#) == .rtcIce(pc: 2, candidate: nil))
        #expect(throws: ProtocolError.invalidValue("sdp")) { try decode(#"{"t":"rtc.offer","pc":1}"#) }
        #expect(throws: ProtocolError.invalidValue("pc")) { try decode(#"{"t":"rtc.offer","sdp":"v=0"}"#) }
        #expect(throws: ProtocolError.invalidValue("pc")) { try decode(#"{"t":"rtc.ice","pc":-1,"candidate":null}"#) }
        #expect(throws: ProtocolError.unknownType("frame.ack")) { try decode(#"{"t":"frame.ack","frameId":57}"#) }
    }

    /// D35: fit-to-phone on `control`; aspect finite and within [0.2, 5].
    @Test func decodesWindowFit() throws {
        #expect(try decode(#"{"t":"window.fitPhone","aspect":0.4615}"#) == .windowFitPhone(aspect: 0.4615))
        #expect(try decode(#"{"t":"window.fitPhone","aspect":0.2}"#) == .windowFitPhone(aspect: 0.2))
        #expect(try decode(#"{"t":"window.fitPhone","aspect":5}"#) == .windowFitPhone(aspect: 5))
        #expect(try decode(#"{"t":"window.restore"}"#) == .windowRestore)
        #expect(throws: ProtocolError.invalidValue("aspect")) { try decode(#"{"t":"window.fitPhone"}"#) }
        #expect(throws: ProtocolError.invalidValue("aspect")) { try decode(#"{"t":"window.fitPhone","aspect":0.19}"#) }
        #expect(throws: ProtocolError.invalidValue("aspect")) { try decode(#"{"t":"window.fitPhone","aspect":5.01}"#) }
        #expect(throws: ProtocolError.invalidValue("aspect")) { try decode(#"{"t":"window.fitPhone","aspect":-1}"#) }
        #expect(throws: ProtocolError.malformed) { try decode(#"{"t":"window.fitPhone","aspect":"wide"}"#) }
        #expect(throws: ProtocolError.wrongChannel("window.restore")) {
            try ClientMessage.decode(Data(#"{"t":"window.restore"}"#.utf8), on: .socket)
        }
        let fit = try JSONSerialization.jsonObject(
            with: Data(ServerMessage.windowFit(windowId: 7, state: .fitted, clamped: true).jsonString().utf8)) as! [String: Any]
        #expect(fit["t"] as? String == "window.fit" && fit["windowId"] as? Int == 7)
        #expect(fit["state"] as? String == "fitted" && fit["clamped"] as? Bool == true)
    }

    /// D39: the audio mode on `control`, and its echo.
    @Test func decodesAudioMode() throws {
        #expect(try decode(#"{"t":"audio","mode":"off"}"#) == .audio(mode: .off))
        #expect(try decode(#"{"t":"audio","mode":"app"}"#) == .audio(mode: .app))
        #expect(try decode(#"{"t":"audio","mode":"all"}"#) == .audio(mode: .all))
        #expect(throws: ProtocolError.invalidValue("mode")) { try decode(#"{"t":"audio"}"#) }
        #expect(throws: ProtocolError.invalidValue("mode")) { try decode(#"{"t":"audio","mode":"mac"}"#) }
        #expect(throws: ProtocolError.malformed) { try decode(#"{"t":"audio","mode":1}"#) }
        #expect(throws: ProtocolError.wrongChannel("audio")) {
            try ClientMessage.decode(Data(#"{"t":"audio","mode":"all"}"#.utf8), on: .socket)
        }
        let state = try JSONSerialization.jsonObject(
            with: Data(ServerMessage.audioState(mode: .app).jsonString().utf8)) as! [String: Any]
        #expect(state["t"] as? String == "audio.state" && state["mode"] as? String == "app")
    }

    /// D33: thumbnail requests carry at most three window ids.
    @Test func decodesThumbnailRequests() throws {
        #expect(try decode(#"{"t":"thumbs.request","windowIds":[1,2,3]}"#) == .thumbsRequest(windowIds: [1, 2, 3]))
        #expect(try decode(#"{"t":"thumbs.request","windowIds":[]}"#) == .thumbsRequest(windowIds: []))
        #expect(throws: ProtocolError.invalidValue("windowIds")) { try decode(#"{"t":"thumbs.request","windowIds":[1,2,3,4]}"#) }
        #expect(throws: ProtocolError.invalidValue("windowIds")) { try decode(#"{"t":"thumbs.request"}"#) }
        #expect(throws: ProtocolError.wrongChannel("thumbs.request")) {
            try ClientMessage.decode(Data(#"{"t":"thumbs.request","windowIds":[1]}"#.utf8), on: .control)
        }
    }

    @Test func encodesThumbnails() throws {
        func object(_ m: ServerMessage) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(m.jsonString().utf8)) as! [String: Any]
        }
        let thumb = try object(.thumb(windowId: 9, jpeg: Data([0xFF, 0xD8, 0xFF])))
        #expect(thumb["t"] as? String == "thumb" && thumb["windowId"] as? Int == 9)
        #expect(thumb["jpeg"] as? String == "/9j/")
        #expect(thumb["missing"] == nil)
        let missing = try object(.thumb(windowId: 9, jpeg: nil))
        #expect(missing["missing"] as? Bool == true && missing["jpeg"] == nil)
    }

    /// D22: each message type is accepted only on the channel that carries it.
    @Test func messagesAreAcceptedOnlyOnTheirChannel() throws {
        func on(_ channel: MessageChannel, _ json: String) throws -> ClientMessage {
            try ClientMessage.decode(Data(json.utf8), on: channel)
        }
        #expect(try on(.motion, #"{"t":"move","seq":1,"dx":0.1,"dy":0}"#) == .move(seq: 1, dx: 0.1, dy: 0))
        #expect(try on(.motion, #"{"t":"scroll","du":0,"dv":0.1}"#) == .scroll(du: 0, dv: 0.1))
        #expect(try on(.control, #"{"t":"click"}"#) == .click)
        #expect(try on(.control, #"{"t":"text","text":"a"}"#) == .text("a"))
        #expect(try on(.socket, #"{"t":"view.start","windowId":3}"#) == .viewStart(windowId: 3))
        #expect(throws: ProtocolError.wrongChannel("click")) { try on(.socket, #"{"t":"click"}"#) }
        #expect(throws: ProtocolError.wrongChannel("move")) { try on(.control, #"{"t":"move","seq":1,"dx":0,"dy":0}"#) }
        #expect(throws: ProtocolError.wrongChannel("click")) { try on(.motion, #"{"t":"click"}"#) }
        #expect(throws: ProtocolError.wrongChannel("rtc.offer")) { try on(.control, #"{"t":"rtc.offer","pc":1,"sdp":"v=0"}"#) }
        #expect(throws: ProtocolError.wrongChannel("windows.list")) { try on(.control, #"{"t":"windows.list"}"#) }
    }

    @Test func encodesLocalCandidates() throws {
        func object(_ m: ServerMessage) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(m.jsonString().utf8)) as! [String: Any]
        }
        let c = try object(.rtcIce(pc: 3, candidate: LocalCandidate(sdp: "candidate:x", sdpMid: "0", sdpMLineIndex: 0)))
        #expect(c["t"] as? String == "rtc.ice")
        #expect(c["pc"] as? Int == 3)
        #expect(c["candidate"] as? String == "candidate:x")
        #expect(c["sdpMid"] as? String == "0")
        #expect(c["sdpMLineIndex"] as? Int == 0)
        let end = try object(.rtcIce(pc: 3, candidate: nil))
        #expect(end["candidate"] is NSNull)
        let answer = try object(.rtcAnswer(pc: 3, sdp: "v=0"))
        #expect(answer["t"] as? String == "rtc.answer" && answer["sdp"] as? String == "v=0")
    }

    /// D21: the encoder runs at level 5.2 with the negotiated profile.
    @Test func encoderLevelIsRaisedTo52() {
        #expect(ScreenH264EncoderFactory.level52("42e01f") == "42e034")
        #expect(ScreenH264EncoderFactory.level52("640c1f") == "640c34")
        #expect(ScreenH264EncoderFactory.level52("42e0") == "42e0")
    }
}
