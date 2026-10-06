import Foundation
import Testing
@testable import CherryMobileKit

/// A `SessionInfo` exactly as a protocol 7 host prints it (`cherry new`).
let sessionJSON = #"""
{"id":"ef217d71-e7dc-43a0-8a6c-fd40f7fc1d08","name":"probe","cwd":"/","command":["/bin/cat"],"cols":120,"rows":32,"state":"running","pid":31832,"exit_code":null,"attached":false,"exit_signal":null,"title":null,"pwd":null,"foreground":{"pid":31832,"name":"cat"},"clients":0,"owner":null,"tags":{"cherry.agent":"claude","cherry.kind":"agent","cherry.tab":"7F0C1E52-3B47-4E2B-9C1A-2D3E4F5A6B7C"},"created_at":1791245014295,"alternate_screen":false,"kitty_keyboard_flags":0,"application_cursor_keys":false,"bracketed_paste":false,"modify_other_keys":false,"request_id":"a0e968c8-8a89-44b1-acae-d7927f0378ea","holder_build":"dev-20261005175728.9eaeafc"}
"""#

private func body(_ json: String) -> Data { Data(json.utf8) }

@Test func aFrameIsItsBigEndianLengthThenItsBody() throws {
    let frame = try HostWire.frame(body: body(#"{"type":"ok"}"#))
    #expect(Array(frame.prefix(4)) == [0, 0, 0, 13])
    #expect(frame.dropFirst(4) == body(#"{"type":"ok"}"#))
    #expect(throws: HostWireError.tooLarge(0)) { try HostWire.frame(body: Data()) }
}

@Test func framesSplitAnywhereComeBackWhole() throws {
    let stream = try HostWire.frame(body: body(#"{"type":"ok"}"#)) + HostWire.frame(body: body(#"{"type":"pong","req":2}"#))
    var decoder = HostWireFrameDecoder()
    var bodies: [Data] = []
    for byte in stream {
        decoder.append(Data([byte]))
        while let frame = try decoder.nextFrame() { bodies.append(frame) }
    }
    #expect(bodies == [body(#"{"type":"ok"}"#), body(#"{"type":"pong","req":2}"#)])
    #expect(decoder.bufferedByteCount == 0)
}

@Test func aLengthOfZeroOrOverTheLimitIsNotTheProtocol() {
    var decoder = HostWireFrameDecoder()
    decoder.append(Data([0, 0, 0, 0]))
    #expect(throws: HostWireError.invalidLength(0)) { try decoder.nextFrame() }
    var big = HostWireFrameDecoder()
    big.append(Data([0x01, 0x00, 0x00, 0x01]))
    #expect(throws: HostWireError.invalidLength(16_777_217)) { try big.nextFrame() }
}

@Test func requestsAreTheProtocolsShapes() throws {
    func json(_ request: HostWireRequest) throws -> String {
        String(decoding: try HostWire.encoder.encode(request), as: UTF8.self)
    }
    // The shapes cherry-protocol's tests decode (keys sorted here).
    #expect(try json(.init(req: nil, message: .sendInput(id: "s", data: Data("foobar".utf8))))
        == #"{"data":"Zm9vYmFy","id":"s","op":"send_input"}"#)
    #expect(try json(.init(req: 7, message: .list)) == #"{"op":"list","req":7}"#)
    #expect(try json(.init(req: 1, message: .subscribe)) == #"{"op":"subscribe","req":1}"#)
    #expect(try json(.init(req: 2, message: .ping)) == #"{"op":"ping","req":2}"#)
    #expect(try json(.init(req: 3, message: .screen(id: "s", scrollback: false, maxLines: nil)))
        == #"{"id":"s","op":"screen","req":3,"scrollback":false}"#)
    #expect(try json(.init(req: 4, message: .screen(id: "s", scrollback: true, maxLines: 0)))
        == #"{"id":"s","max_lines":1,"op":"screen","req":4,"scrollback":true}"#)
}

@Test func aWelcomeAndARealSessionListDecode() throws {
    let welcome = try HostWireResponse.decode(frameBody: body(
        #"{"type":"welcome","version":7,"host_id":"2c2bf623-be0c-4320-9d26-a514fedb9d89","build":"dev-1.abc"}"#
    ))
    #expect(welcome == HostWireResponse(req: nil, reply: .welcome(version: 7, hostID: "2c2bf623-be0c-4320-9d26-a514fedb9d89")))

    let list = try HostWireResponse.decode(frameBody: body(
        #"{"type":"sessions","req":9,"host_id":"h","pending_holders":0,"sessions":[\#(sessionJSON)]}"#
    ))
    #expect(list.req == 9)
    guard case .sessions(let sessions) = list.reply else {
        Issue.record("not a session list: \(list)")
        return
    }
    #expect(sessions.hostID == "h")
    let session = try #require(sessions.sessions.first)
    #expect(session.id == "ef217d71-e7dc-43a0-8a6c-fd40f7fc1d08")
    #expect(session.cols == 120 && session.rows == 32)
    #expect(session.isRunning)
    #expect(session.foreground == .init(pid: 31832, name: "cat"))
    #expect(session.tags["cherry.kind"] == "agent")
}

@Test func screensErrorsAndEventsDecode() throws {
    let screen = try HostWireResponse.decode(frameBody: body(
        #"{"type":"screen_text","req":3,"id":"s","text":"hello\nworld\n\n","cursor_row":1,"cursor_col":5,"alternate_screen":false}"#
    ))
    guard case .screenText(let text) = screen.reply else {
        Issue.record("not a screen: \(screen)")
        return
    }
    #expect(SessionMapping.lines(of: text) == ["hello", "world"])

    #expect(try HostWireResponse.decode(frameBody: body(#"{"type":"error","req":4,"code":"unknown_session","message":"no session s"}"#))
        == HostWireResponse(req: 4, reply: .error(code: "unknown_session", message: "no session s")))

    let changed = try HostWireResponse.decode(frameBody: body(#"{"type":"event","event":{"kind":"changed","session":\#(sessionJSON)}}"#))
    guard case .event(.changed(let session)) = changed.reply else {
        Issue.record("not a changed event: \(changed)")
        return
    }
    #expect(session.name == "probe")
    #expect(try HostWireResponse.decode(frameBody: body(#"{"type":"event","event":{"kind":"exited","id":"s","exit_code":130,"signal":2}}"#)).reply
        == .event(.exited(id: "s", exitCode: 130, signal: 2)))
    #expect(try HostWireResponse.decode(frameBody: body(#"{"type":"event","event":{"kind":"resync"}}"#)).reply == .event(.resync))
    #expect(try HostWireResponse.decode(frameBody: body(#"{"type":"event","event":{"kind":"a_later_kind","id":"s"}}"#)).reply
        == .event(.unknown(kind: "a_later_kind")))
}

@Test func attachmentTrafficIsSkippedAndAnUnreadableReplyStillNamesItsRequest() throws {
    // A binary Output frame: kind 1, an 8-byte offset, bytes.
    let output = Data([1, 0, 0, 0, 0, 0, 0, 0, 0]) + Data("x".utf8)
    #expect(try HostWireResponse.decode(frameBody: output) == HostWireResponse(req: nil, reply: .other(type: "binary 1")))
    #expect(try HostWireResponse.decode(frameBody: body(#"{"type":"a_later_type","req":5}"#)).reply == .other(type: "a_later_type"))
    #expect(HostWireResponse.requestID(inUndecodable: body(#"{"type":"sessions","req":6,"sessions":"nope"}"#)) == 6)
    #expect(HostWireResponse.requestID(inUndecodable: output) == nil)
}
