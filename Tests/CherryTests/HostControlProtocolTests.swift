import Foundation
import Testing
@testable import Cherry

private func json(_ data: Data) throws -> NSDictionary {
    try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
}

private func json(_ text: String) throws -> NSDictionary {
    try json(Data(text.utf8))
}

/// The JSON body of an encoded request frame, after checking its prefix.
private func body(of request: HostRequest) throws -> NSDictionary {
    let frame = try HostFrame.encode(request)
    let length = frame.prefix(4).reduce(0) { $0 << 8 | Int($1) }
    #expect(length == frame.count - 4)
    // The host reads a body that starts with anything else as binary.
    #expect(frame.dropFirst(4).first == UInt8(ascii: "{"))
    #expect(HostFrame.isJSON(frame.dropFirst(4)))
    return try json(frame.dropFirst(4))
}

private func decode(_ text: String) throws -> HostResponse {
    try JSONDecoder().decode(HostResponse.self, from: Data(text.utf8))
}

@Test func HostControlVersionMatchesTheHostProtocolCrate() throws {
    let source = try String(
        contentsOf: HostedSessionClient.developmentSourceRoot
            .appendingPathComponent("Host/crates/cherry-protocol/src/lib.rs"),
        encoding: .utf8
    )
    #expect(source.contains("pub const PROTOCOL_VERSION: u32 = \(HostProtocol.version);"))
    #expect(source.contains("pub const MAX_INPUT_BYTES: usize = 64 * 1024;"))
    #expect(source.contains("pub const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;"))
    #expect(source.contains("pub const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(15);"))
    #expect(source.contains("pub const OUTPUT: u8 = \(HostBinaryFrame.Kind.output);"))
    #expect(source.contains("pub const INPUT: u8 = \(HostBinaryFrame.Kind.input);"))
    #expect(source.contains("pub const QUERY: u8 = \(HostBinaryFrame.Kind.query);"))
    #expect(source.contains("pub const ATTACHED: u8 = \(HostBinaryFrame.Kind.attached);"))
}

@Test func HostControlEncodesEveryRequestAsTheHostExpects() throws {
    #expect(try body(of: HostRequest(req: 7, message: .list)) == (try json(#"{"op":"list","req":7}"#)))
    #expect(try body(of: HostRequest(req: nil, message: .hello(version: 4)))
        == (try json(#"{"op":"hello","version":4}"#)))
    // Frozen shapes are byte-exact.
    let hello = try HostFrame.encode(HostRequest(req: nil, message: .hello(version: 4)))
    #expect(hello == Data([0, 0, 0, 26]) + Data(#"{"op":"hello","version":4}"#.utf8))
    #expect(try body(of: HostRequest(req: 1, message: .replace)) == (try json(#"{"op":"replace","req":1}"#)))
    #expect(try body(of: HostRequest(req: 2, message: .subscribe)) == (try json(#"{"op":"subscribe","req":2}"#)))
    #expect(try body(of: HostRequest(req: 3, message: .ping)) == (try json(#"{"op":"ping","req":3}"#)))
    #expect(try body(of: HostRequest(req: UInt64.max, message: .kill(id: "s"))) == (try json(
        #"{"op":"kill","req":18446744073709551615,"id":"s"}"#
    )))
    #expect(try body(of: HostRequest(req: 0, message: .remove(id: "s"))) == (try json(#"{"op":"remove","req":0,"id":"s"}"#)))
    #expect(try body(of: HostRequest(req: 4, message: .sendInput(id: "s", data: Data([0, 255, 27]))))
        == (try json(#"{"op":"send_input","req":4,"id":"s","data":"AP8b"}"#)))
    #expect(try body(of: HostRequest(req: 5, message: .screen(id: "s", scrollback: true)))
        == (try json(#"{"op":"screen","req":5,"id":"s","scrollback":true}"#)))
    // A field left out is kept by the host; tags replace the whole map.
    #expect(try body(of: HostRequest(req: 6, message: .update(id: "s", name: nil, tags: nil)))
        == (try json(#"{"op":"update","req":6,"id":"s"}"#)))
    #expect(try body(of: HostRequest(req: 6, message: .update(id: "s", name: "Editor", tags: ["tab": "1"])))
        == (try json(#"{"op":"update","req":6,"id":"s","name":"Editor","tags":{"tab":"1"}}"#)))

    let requestID = try #require(UUID(uuidString: "6F1A2B3C-4D5E-4F60-8172-8394A5B6C7D8"))
    let create = HostCreateRequest(
        requestID: requestID, name: "Editor", cwd: "~/code", command: ["/bin/zsh", "-l"],
        environment: ["TERM": "xterm-ghostty"], cols: 100, rows: 30, owner: "Cherry", tags: ["kind": "terminal"]
    )
    #expect(try body(of: HostRequest(req: 8, message: .create(create))) == (try json("""
    {"op":"create","req":8,"request_id":"6f1a2b3c-4d5e-4f60-8172-8394a5b6c7d8","name":"Editor","cwd":"~/code",
     "command":["/bin/zsh","-l"],"env":{"TERM":"xterm-ghostty"},"cols":100,"rows":30,"owner":"Cherry",
     "tags":{"kind":"terminal"}}
    """)))
    // No owner: left out (the host defaults it to none); tags are always sent.
    var anonymous = create
    anonymous.owner = nil
    anonymous.tags = [:]
    let anonymousBody = try body(of: HostRequest(req: nil, message: .create(anonymous)))
    #expect(anonymousBody["owner"] == nil)
    #expect(anonymousBody["tags"] as? NSDictionary == [:])
    #expect(anonymousBody["req"] == nil)
}

@Test func HostControlEncodesProtocol7Requests() throws {
    #expect(HostProtocol.version == 7)
    #expect(try body(of: HostRequest(req: 9, message: .clearHistory(id: "s")))
        == (try json(#"{"op":"clear_history","req":9,"id":"s"}"#)))
    // A Create carries the colours its terminal reports, as #rrggbb.
    let colors = try #require(HostTerminalColors(foreground: "#1F2328", background: "fff", dark: false))
    var create = HostCreateRequest(requestID: UUID(), name: "n", cwd: "/", owner: nil, tags: [:])
    create.colors = colors
    let sent = try body(of: HostRequest(req: 1, message: .create(create)))
    #expect(sent["colors"] as? NSDictionary == ["foreground": "#1f2328", "background": "#ffffff", "dark": false])
    let withCursor = try #require(HostTerminalColors(foreground: "#e5e5e5", background: "#000000", cursor: "#FF8800", dark: true))
    create.colors = withCursor
    let cursorSent = try body(of: HostRequest(req: 1, message: .create(create)))
    #expect((cursorSent["colors"] as? NSDictionary)?["cursor"] as? String == "#ff8800")
    // Without them the field is left out.
    create.colors = nil
    #expect(try body(of: HostRequest(req: 1, message: .create(create)))["colors"] == nil)
    // Colours the host would refuse are not sent at all.
    #expect(HostTerminalColors(foreground: "rgb(1,2,3)", background: "#000000", dark: true) == nil)
    #expect(HostTerminalColors(foreground: "#000000", background: "#00000", dark: true) == nil)
    #expect(HostTerminalColors(foreground: "#000000", background: "#000000", cursor: "blue", dark: true) == nil)
    // Fullwidth digits and letters are hex digits to Swift, not to the host.
    #expect(HostTerminalColors(foreground: "#１２３４５６", background: "#000000", dark: true) == nil)
    #expect(HostTerminalColors(foreground: "#ａｂｃ", background: "#000000", dark: true) == nil)
}

@Test func HostControlDecodesTheProgramsBracketedPasteMode() throws {
    let on = try decode("""
    {"type":"event","event":{"kind":"changed","session":{"id":"s1","name":"n","cwd":"/","command":[],"cols":80,"rows":24,
     "state":"running","pid":9,"bracketed_paste":true}}}
    """)
    guard case .event(.changed(let info)) = on.message else {
        Issue.record("Expected a changed event, got \(on.message)")
        return
    }
    #expect(info.bracketedPaste == true)
    // A host or holder that does not report it: unknown, not off.
    let older = try decode("""
    {"type":"sessions","host_id":"h","sessions":[
     {"id":"s1","name":"n","cwd":"/","command":[],"cols":80,"rows":24,"state":"running"}]}
    """)
    guard case .sessions(let list) = older.message else { return }
    #expect(list.sessions.first?.bracketedPaste == nil)
    let reported = HostedSessionInfo(id: "s", name: "n", cwd: "/", bracketedPaste: false)
    #expect(try json(JSONEncoder().encode(reported))["bracketed_paste"] as? Bool == false)
    #expect(try json(JSONEncoder().encode(HostedSessionInfo(id: "s", name: "n", cwd: "/")))["bracketed_paste"] == nil)
    #expect(reported.exited(code: 0, signal: nil).bracketedPaste == false)
}

@Test func HostControlBase64MatchesTheHostsStandardPaddedAlphabet() throws {
    // Vectors from the host's base64_bytes (standard alphabet, padded).
    let vectors: [(bytes: [UInt8], text: String)] = [
        ([], ""), ([0], "AA=="), ([0, 255], "AP8="), ([0, 255, 27], "AP8b"),
        (Array("hello world".utf8), "aGVsbG8gd29ybGQ="), ([251, 255, 191], "+/+/"),
    ]
    for vector in vectors {
        let frame = try body(of: HostRequest(req: nil, message: .sendInput(id: "s", data: Data(vector.bytes))))
        #expect(frame["data"] as? String == vector.text)
        #expect(Data(base64Encoded: vector.text) == Data(vector.bytes))
    }
    // The largest input one request carries fits in a frame.
    let input = Data((0..<HostProtocol.maxInputBytes).map { UInt8(truncatingIfNeeded: $0) })
    let frame = try body(of: HostRequest(req: 1, message: .sendInput(id: "s", data: input)))
    #expect(Data(base64Encoded: try #require(frame["data"] as? String)) == input)
}

@Test func HostControlFrameDecoderReassemblesSplitFramesAndRejectsBadLengths() throws {
    let first = try HostFrame.encode(HostResponse(req: 1, message: .ok))
    // Binary frames share the length prefix; their bytes are raw.
    let binary = try HostFrame.encode(HostBinaryFrame.output(offset: 1, data: Data([0, 0, 0, 0, 0x7B, 0xFF])))
    let second = try HostFrame.encode(HostResponse(req: nil, message: .event(.bell(id: "s"))))
    let stream = first + binary + second
    // Every split point, including inside a length prefix.
    for split in 0...stream.count {
        var decoder = HostFrameDecoder()
        var bodies: [Data] = []
        decoder.append(stream.prefix(split))
        while let body = try decoder.nextFrame() { bodies.append(body) }
        decoder.append(stream.dropFirst(split))
        while let body = try decoder.nextFrame() { bodies.append(body) }
        #expect(bodies == [first.dropFirst(4), binary.dropFirst(4), second.dropFirst(4)].map { Data($0) })
        #expect(decoder.bufferedByteCount == 0)
    }
    // One byte at a time.
    var trickle = HostFrameDecoder()
    var count = 0
    for byte in stream {
        trickle.append(Data([byte]))
        while try trickle.nextFrame() != nil { count += 1 }
    }
    #expect(count == 3)

    var empty = HostFrameDecoder()
    empty.append(Data([0, 0, 0, 0]))
    #expect(throws: HostFrameError.invalidLength(0)) { try empty.nextFrame() }
    var huge = HostFrameDecoder()
    huge.append(Data([0x01, 0x00, 0x00, 0x01]))
    #expect(throws: HostFrameError.invalidLength(HostProtocol.maxFrameBytes + 1)) { try huge.nextFrame() }
    var partial = HostFrameDecoder()
    partial.append(Data([0, 0, 0, 5, 123]))
    #expect(try partial.nextFrame() == nil)
    #expect(throws: HostFrameError.self) { try HostFrame.frame(body: Data()) }
}

@Test func HostControlDecodesEveryReplyTheControlPlaneReads() throws {
    let session = #"{"id":"s1","name":"Editor","cwd":"/work","command":["/bin/zsh"],"cols":80,"rows":24,"state":"running","pid":7,"exit_code":null,"attached":false,"exit_signal":null}"#
    #expect(try decode(#"{"type":"welcome","version":4,"host_id":"host-a"}"#)
        == HostResponse(req: nil, message: .welcome(version: 4, hostID: "host-a")))
    // Welcome answers every Hello whatever its version; req is echoed.
    #expect(try decode(#"{"type":"welcome","version":3,"host_id":"h","req":9}"#)
        == HostResponse(req: 9, message: .welcome(version: 3, hostID: "h")))
    let sessions = try decode(#"{"type":"sessions","host_id":"host-a","sessions":[\#(session)],"req":2}"#)
    guard case .sessions(let list) = sessions.message else {
        Issue.record("Expected sessions, got \(sessions)")
        return
    }
    #expect(sessions.req == 2)
    #expect(list.hostID == "host-a")
    #expect(list.sessions.map(\.id) == ["s1"])
    guard case .created(let created) = try decode(#"{"type":"created","session":\#(session),"req":3}"#).message else {
        Issue.record("Expected created")
        return
    }
    #expect(created.pid == 7)
    #expect(try decode(#"{"type":"pong","req":4}"#) == HostResponse(req: 4, message: .pong))
    #expect(try decode(#"{"type":"ok"}"#) == HostResponse(req: nil, message: .ok))
    #expect(try decode(#"{"type":"error","code":"not_running","message":"session exited","req":5}"#)
        == HostResponse(req: 5, message: .error(code: "not_running", message: "session exited")))
    #expect(try decode(#"{"type":"screen_text","id":"s1","text":"a\nb","cursor_row":1,"cursor_col":3,"alternate_screen":true,"req":6}"#)
        == HostResponse(req: 6, message: .screenText(HostScreenText(
            id: "s1", text: "a\nb", cursorRow: 1, cursorCol: 3, alternateScreen: true
        ))))
    // Unknown fields are ignored; messages a control connection does not
    // use (or does not know) still decode.
    #expect(try decode(#"{"type":"ok","req":1,"future":{"x":1}}"#) == HostResponse(req: 1, message: .ok))
    #expect(try decode(#"{"type":"exit","id":"s1","exit_code":0,"signal":null}"#).message == .other(type: "exit"))
    #expect(try decode(#"{"type":"resized","offset":0,"cols":80,"rows":24}"#).message == .other(type: "resized"))
    #expect(try decode(#"{"type":"from_the_future"}"#).message == .other(type: "from_the_future"))
    // An unreadable reply still names its request.
    #expect(HostResponse.requestID(inUndecodable: Data(#"{"type":"created","session":{},"req":11}"#.utf8)) == 11)
    #expect(throws: DecodingError.self) { try decode(#"{"type":"created","session":{},"req":11}"#) }
}

@Test func HostControlBinaryFramesHaveTheHostsLayout() throws {
    // The kind, then big-endian integers, then raw bytes.
    let output = HostBinaryFrame.output(offset: 0x0102_0304_0506_0708, data: Data([0, 0x7B, 0xFF]))
    #expect(output.body == Data([1, 1, 2, 3, 4, 5, 6, 7, 8, 0, 0x7B, 0xFF]))
    #expect(try HostFrame.encode(output) == Data([0, 0, 0, 12]) + output.body)
    #expect(HostBinaryFrame.input(Data("ls\r".utf8)).body == Data([2]) + Data("ls\r".utf8))
    #expect(HostBinaryFrame.query(Data([0x1B, 0x5B, 0x36, 0x6E])).body == Data([3, 0x1B, 0x5B, 0x36, 0x6E]))
    let header = Data(#"{"offset":7,"reason":"attach","session":{"id":"s1"}}"#.utf8)
    let attached = HostBinaryFrame.attached(header: header, snapshot: Data("snap".utf8))
    #expect(attached.body == Data([4, 0, 0, 0, UInt8(header.count)]) + header + Data("snap".utf8))
    #expect(try JSONSerialization.jsonObject(with: header) is NSDictionary)
    #expect([output, .input(Data()), .query(Data()), attached].map(\.kind) == [1, 2, 3, 4])

    // Round trips, with empty payloads and payloads that look like JSON.
    let frames: [HostBinaryFrame] = [
        output, .output(offset: 0, data: Data()), .output(offset: .max, data: Data(#"{"type":"ok"}"#.utf8)),
        .input(Data()), .input(Data([0x7B])), .query(Data([0])), attached,
        .attached(header: Data("{}".utf8), snapshot: Data()), .attached(header: Data("{}".utf8), snapshot: Data("{x".utf8)),
    ]
    for frame in frames {
        #expect(!HostFrame.isJSON(frame.body))
        #expect(try HostBinaryFrame(body: frame.body) == frame)
        // A slice of a larger buffer (not indexed from zero) decodes the same.
        #expect(try HostBinaryFrame(body: (Data([9, 9]) + frame.body).dropFirst(2)) == frame)
    }

    // Too short for its kind, or an Attached header that does not fit or is
    // no JSON object.
    let malformed: [Data] = [
        Data([1]), Data([1, 0, 0, 0, 0, 0, 0, 0]), Data([4]), Data([4, 0, 0, 0]),
        Data([4, 0, 0, 0, 0]), Data([4, 0, 0, 0, 1, 0x7B]), Data([4, 0, 0, 0, 3, 0x7B, 0x7D]),
        Data([4, 0xFF, 0xFF, 0xFF, 0xFF, 0x7B, 0x7D]), Data([4, 0, 0, 0, 2]) + Data("[]".utf8),
    ]
    for body in malformed {
        #expect(throws: HostBinaryFrameError.malformed(kind: body[0], length: body.count)) {
            try HostBinaryFrame(body: body)
        }
    }
    #expect(throws: HostBinaryFrameError.unknownKind(9)) { try HostBinaryFrame(body: Data([9, 1, 2])) }
    #expect(throws: HostBinaryFrameError.unknownKind(0)) { try HostBinaryFrame(body: Data([0])) }
    // A JSON body is not a binary frame.
    #expect(throws: HostBinaryFrameError.self) { try HostBinaryFrame(body: Data(#"{"type":"ok"}"#.utf8)) }
}

@Test func HostControlReadsBinaryFramesAsAttachmentTrafficThatAnswersNoRequest() throws {
    let decoder = JSONDecoder()
    func read(_ body: Data) throws -> HostResponse { try HostResponse.decode(frameBody: body, using: decoder) }
    // JSON decodes as before.
    #expect(try read(Data(#"{"type":"pong","req":4}"#.utf8)) == HostResponse(req: 4, message: .pong))
    #expect(throws: DecodingError.self) { try read(Data(#"{"type":"created","session":{},"req":11}"#.utf8)) }
    // A binary frame never answers a request, whatever its bytes look like,
    // and is named after the message it replaced.
    let reply = Data(#"{"type":"pong","req":4}"#.utf8)
    let header = Data(#"{"offset":0,"reason":"attach","req":4}"#.utf8)
    #expect(try read(HostBinaryFrame.output(offset: 3, data: reply).body)
        == HostResponse(req: nil, message: .other(type: "output")))
    #expect(try read(HostBinaryFrame.input(reply).body) == HostResponse(req: nil, message: .other(type: "input")))
    #expect(try read(HostBinaryFrame.query(reply).body) == HostResponse(req: nil, message: .other(type: "query")))
    #expect(try read(HostBinaryFrame.attached(header: header, snapshot: reply).body)
        == HostResponse(req: nil, message: .other(type: "attached")))
    // A kind from a newer host is skipped like an unknown `type`; only `{`
    // marks JSON.
    #expect(try read(Data([200, 1, 2])) == HostResponse(req: nil, message: .other(type: "binary 200")))
    #expect(try read(Data(#" {"type":"ok"}"#.utf8)) == HostResponse(req: nil, message: .other(type: "binary 32")))
    // Even when JSONDecoder would accept it (leading whitespace) and it
    // carries a `req`: it answers nothing, and as unreadable names nothing.
    for space: UInt8 in [0x20, 0x09, 0x0A, 0x0D] {
        let body = Data([space]) + reply
        #expect(try JSONDecoder().decode(HostResponse.self, from: body) == HostResponse(req: 4, message: .pong))
        #expect(try read(body) == HostResponse(req: nil, message: .other(type: "binary \(space)")))
        #expect(HostResponse.requestID(inUndecodable: body) == nil)
        #expect(HostResponse.requestID(inUndecodable: Data([space]) + Data(#"{"req":1}"#.utf8)) == nil)
    }
    // A malformed one is unreadable and names no request.
    #expect(throws: HostBinaryFrameError.malformed(kind: 1, length: 3)) { try read(Data([1, 0, 0])) }
    #expect(HostResponse.requestID(inUndecodable: Data([1, 0, 0])) == nil)
    #expect(HostResponse.requestID(inUndecodable: Data([4, 0, 0, 0, 9]) + Data(#"{"req":1}"#.utf8)) == nil)
}

@Test func HostControlDecodesEveryEventKind() throws {
    let session = #"{"id":"s1","name":"Editor","cwd":"/work","command":[],"cols":80,"rows":24,"state":"running","pid":7,"exit_code":null,"attached":true,"exit_signal":null,"title":"vim","clients":1}"#
    func event(_ text: String) throws -> HostServerMessage {
        let response = try decode(#"{"type":"event","event":\#(text)}"#)
        #expect(response.req == nil)
        return response.message
    }
    guard case .event(.added(let added)) = try event(#"{"kind":"added","session":\#(session)}"#) else {
        Issue.record("Expected added")
        return
    }
    #expect(added.title == "vim")
    guard case .event(.changed(let changed)) = try event(#"{"kind":"changed","session":\#(session)}"#) else {
        Issue.record("Expected changed")
        return
    }
    #expect(changed.clients == 1)
    #expect(try event(#"{"kind":"removed","id":"s1"}"#) == .event(.removed(id: "s1")))
    #expect(try event(#"{"kind":"bell","id":"s1"}"#) == .event(.bell(id: "s1")))
    #expect(try event(#"{"kind":"notification","id":"s1","title":"Build","body":"done"}"#)
        == .event(.notification(id: "s1", title: "Build", body: "done")))
    #expect(try event(#"{"kind":"notification","id":"s1","title":"","body":"done"}"#)
        == .event(.notification(id: "s1", title: "", body: "done")))
    for state in ["remove", "set", "error", "indeterminate", "pause"] {
        #expect(try event(#"{"kind":"progress","id":"s1","state":"\#(state)","value":42}"#)
            == .event(.progress(id: "s1", state: try #require(HostProgressState(rawValue: state)), value: 42)))
    }
    #expect(try event(#"{"kind":"progress","id":"s1","state":"indeterminate","value":null}"#)
        == .event(.progress(id: "s1", state: .indeterminate, value: nil)))
    #expect(try event(#"{"kind":"exited","id":"s1","exit_code":137,"signal":9}"#)
        == .event(.exited(id: "s1", exitCode: 137, signal: 9)))
    #expect(try event(#"{"kind":"exited","id":"s1","exit_code":3,"signal":null}"#)
        == .event(.exited(id: "s1", exitCode: 3, signal: nil)))
    #expect(try event(#"{"kind":"resync"}"#) == .event(.resync))
    // Kinds (and progress states) from a newer host are skipped, not fatal.
    #expect(try event(#"{"kind":"window_moved","id":"s1"}"#) == .unknownEvent(kind: "window_moved"))
    #expect(try event(#"{"kind":"progress","id":"s1","state":"sparkle","value":1}"#) == .unknownEvent(kind: "progress"))

    // Every event survives the app's own encoding (the fake host uses it).
    let events: [HostSessionEvent] = [
        .added(added), .changed(changed), .removed(id: "a"), .bell(id: "b"),
        .notification(id: "c", title: "t", body: "b"), .progress(id: "d", state: .set, value: 5),
        .progress(id: "d", state: .pause, value: nil), .exited(id: "e", exitCode: 1, signal: nil), .resync,
    ]
    for original in events {
        let data = try HostFrame.encoder.encode(HostResponse(req: nil, message: .event(original)))
        #expect(try JSONDecoder().decode(HostResponse.self, from: data).message == .event(original))
    }
    #expect(HostSessionEvent.exited(id: "e", exitCode: 1, signal: nil).sessionID == "e")
    #expect(HostSessionEvent.resync.sessionID == nil)
}

@Test func HostedSessionInfoDecodesProtocolFourFields() throws {
    let full = """
    {"id":"s1","name":"Editor","cwd":"/work","command":["/bin/zsh"],"cols":120,"rows":40,"state":"running",
     "pid":500,"exit_code":null,"attached":true,"exit_signal":null,"title":"nvim README.md",
     "pwd":"file://my-mac.local/Users/me/My%20Project","foreground":{"pid":612,"name":"nvim"},"clients":2,
     "owner":"Cherry","tags":{"cherry.tab":"A1","cherry.kind":"terminal"},"created_at":1727190000123}
    """
    let session = try JSONDecoder().decode(HostedSessionInfo.self, from: Data(full.utf8))
    #expect(session.title == "nvim README.md")
    #expect(session.pwd == "file://my-mac.local/Users/me/My%20Project")
    #expect(session.reportedDirectory == HostedReportedDirectory(machine: "my-mac.local", path: "/Users/me/My Project"))
    #expect(session.workingDirectory(onMachineNamed: ["My-Mac"]) == "/Users/me/My Project")
    #expect(session.workingDirectory(onMachineNamed: ["devbox"]) == nil)
    #expect(session.foreground == HostedSessionForeground(pid: 612, name: "nvim"))
    #expect(session.isBusy)
    #expect(session.clients == 2)
    #expect(session.attached)
    #expect(session.owner == "Cherry")
    #expect(session.tags == ["cherry.tab": "A1", "cherry.kind": "terminal"])
    #expect(session.createdAt == 1_727_190_000_123)
    #expect(session.createdDate == Date(timeIntervalSince1970: 1_727_190_000.123))
    // The app's encoding is the host's shape and reads back the same.
    #expect(try JSONDecoder().decode(HostedSessionInfo.self, from: JSONEncoder().encode(session)) == session)

    // Everything added in protocol 4 has a default, and null is absent.
    let minimal = #"{"id":"s2","name":"","cwd":"/","command":[],"cols":80,"rows":24,"state":"exited","pid":null,"exit_code":0,"attached":false,"exit_signal":null,"title":null,"pwd":null,"foreground":null,"owner":null}"#
    let exited = try JSONDecoder().decode(HostedSessionInfo.self, from: Data(minimal.utf8))
    #expect(exited.title == nil)
    #expect(exited.reportedDirectory == nil)
    #expect(exited.localWorkingDirectory == nil)
    #expect(exited.foreground == nil)
    #expect(exited.clients == 0)
    #expect(exited.owner == nil)
    #expect(exited.tags.isEmpty)
    #expect(exited.createdAt == 0)
    #expect(exited.createdDate == nil)
    #expect(!exited.isBusy)
    #expect(exited.displayName == "s2")

    // The shell itself in the foreground is not busy.
    let idle = HostedSessionInfo(id: "s3", name: "", cwd: "/", pid: 9, foreground: .init(pid: 9, name: "zsh"))
    #expect(!idle.isBusy)
    #expect(idle.exited(code: 130, signal: 2).state == .exited)
    #expect(idle.exited(code: 130, signal: 2).exitSignal == 2)
    #expect(idle.exited(code: 130, signal: 2).foreground == nil)

    // Reported directories: OSC 7 URIs, plain paths (OSC 9;9 / 1337) and kitty's form.
    func reported(_ text: String) -> HostedReportedDirectory? { HostedReportedDirectory(reported: text) }
    #expect(reported("/plain/path with space") == .init(machine: nil, path: "/plain/path with space"))
    #expect(reported("file:///tmp/a%25b") == .init(machine: nil, path: "/tmp/a%b"))
    #expect(reported("FILE://Host/x") == .init(machine: "host", path: "/x"))
    #expect(reported("file://localhost/x") == .init(machine: nil, path: "/x"))
    #expect(reported("kitty-shell-cwd://host/raw dir") == .init(machine: "host", path: "/raw dir"))
    // Some shells leave spaces (and stray percent signs) unencoded.
    #expect(reported("file://mac/Users/me/My Project") == .init(machine: "mac", path: "/Users/me/My Project"))
    #expect(reported("file://mac/tmp/100%") == .init(machine: "mac", path: "/tmp/100%"))
    #expect(reported("file://host") == nil)
    #expect(reported("http://host/x") == nil)
    #expect(reported("relative") == nil)

    // A local session's shell that ran `ssh devbox` reports devbox's
    // directory: it is not a directory on This Mac.
    let thisMac = try #require(HostedReportedDirectory.thisMacNames().first)
    func local(_ pwd: String) -> String? {
        HostedSessionInfo(id: "l", name: "", cwd: "/", pwd: pwd).localWorkingDirectory
    }
    #expect(local("file://\(thisMac)/Users/me") == "/Users/me")
    #expect(local("file://\(thisMac.uppercased())./Users/me") == "/Users/me")
    #expect(local("file:///Users/me") == "/Users/me")
    #expect(local("/Users/me") == "/Users/me")
    #expect(local("file://not-\(thisMac)/home/me") == nil)
    #expect(HostedReportedDirectory(machine: "mac.local", path: "/").isOnMachine(namedAnyOf: ["MAC"]))
    #expect(HostedReportedDirectory(machine: "mac", path: "/").isOnMachine(namedAnyOf: ["mac.local"]))
    #expect(!HostedReportedDirectory(machine: "mac", path: "/").isOnMachine(namedAnyOf: []))
}

@Test func HostControlChecksTagsAndSizesLikeTheHost() {
    #expect(HostProtocol.tagProblem([:]) == nil)
    #expect(HostProtocol.tagProblem(["": "x"]) != nil)
    #expect(HostProtocol.tagProblem([String(repeating: "k", count: 129): "x"]) != nil)
    #expect(HostProtocol.tagProblem([String(repeating: "k", count: 128): "x"]) == nil)
    #expect(HostProtocol.tagProblem(Dictionary(uniqueKeysWithValues: (0..<65).map { ("k\($0)", "") })) != nil)
    #expect(HostProtocol.tagProblem(["k": String(repeating: "v", count: 16 * 1_024)]) != nil)
    #expect(HostProtocol.isValidSize(cols: 2, rows: 1))
    #expect(HostProtocol.isValidSize(cols: 500, rows: 200))
    #expect(!HostProtocol.isValidSize(cols: 1, rows: 24))
    #expect(!HostProtocol.isValidSize(cols: 80, rows: 201))
}

// MARK: - Modes, request ids, pending holders, max_lines

@Test func HostControlDecodesTheSessionsModesRequestIDAndPendingHolders() throws {
    let current = try decode("""
    {"type":"sessions","host_id":"h","pending_holders":2,"sessions":[
     {"id":"s1","name":"n","cwd":"/","command":[],"cols":80,"rows":24,"state":"running","pid":9,
      "alternate_screen":true,"kitty_keyboard_flags":31,"request_id":"6f1a2b3c-4d5e-4f60-8172-8394a5b6c7d8"}]}
    """)
    guard case .sessions(let list) = current.message else {
        Issue.record("Expected sessions, got \(current.message)")
        return
    }
    #expect(list.pendingHolders == 2)
    #expect(list.awaitsHolders)
    #expect(!list.isComplete)
    let session = try #require(list.sessions.first)
    #expect(session.alternateScreen == true)
    #expect(session.kittyKeyboardFlags == 31)
    #expect(session.requestID == "6f1a2b3c-4d5e-4f60-8172-8394a5b6c7d8")

    // A host from before these fields: unknown, not false or 0.
    let older = try decode("""
    {"type":"sessions","host_id":"h","sessions":[
     {"id":"s1","name":"n","cwd":"/","command":[],"cols":80,"rows":24,"state":"running","pid":9}]}
    """)
    guard case .sessions(let olderList) = older.message else {
        Issue.record("Expected sessions, got \(older.message)")
        return
    }
    #expect(olderList.pendingHolders == nil)
    #expect(!olderList.awaitsHolders)
    #expect(!olderList.isComplete)
    let olderSession = try #require(olderList.sessions.first)
    #expect(olderSession.alternateScreen == nil)
    #expect(olderSession.kittyKeyboardFlags == nil)
    #expect(olderSession.requestID == nil)

    // A complete list.
    let complete = try decode(#"{"type":"sessions","host_id":"h","pending_holders":0,"sessions":[]}"#)
    guard case .sessions(let completeList) = complete.message else { return }
    #expect(completeList.isComplete)

    // Round trips keep them, and leave out what is unknown.
    let info = HostedSessionInfo(
        id: "s", name: "n", cwd: "/", alternateScreen: false, kittyKeyboardFlags: 0, requestID: "r"
    )
    let encoded = try json(JSONEncoder().encode(info))
    #expect(encoded["alternate_screen"] as? Bool == false)
    #expect(encoded["kitty_keyboard_flags"] as? Int == 0)
    #expect(encoded["request_id"] as? String == "r")
    let bare = try json(JSONEncoder().encode(HostedSessionInfo(id: "s", name: "n", cwd: "/")))
    #expect(bare["alternate_screen"] == nil)
    #expect(bare["kitty_keyboard_flags"] == nil)
    #expect(bare["request_id"] == nil)
    let response = HostResponse(req: 3, message: .sessions(HostedSessionList(hostID: "h", sessions: [info], pendingHolders: 1)))
    #expect(try decode(String(decoding: JSONEncoder().encode(response), as: UTF8.self)) == response)
    let unreported = HostResponse(req: 3, message: .sessions(HostedSessionList(hostID: "h", sessions: [])))
    #expect(try json(JSONEncoder().encode(unreported))["pending_holders"] == nil)
    #expect(try json(JSONEncoder().encode(unreported))["lost_sessions"] == nil)
    // An exit keeps what identifies the session.
    #expect(info.exited(code: 1, signal: nil).requestID == "r")
}

@Test func HostControlDecodesTheSessionsWhoseHoldersTheHostFoundKilled() throws {
    let lost = try decode(#"{"type":"sessions","host_id":"h","sessions":[],"pending_holders":0,"lost_sessions":["s1","s2"]}"#)
    guard case .sessions(let list) = lost.message else {
        Issue.record("Expected sessions, got \(lost.message)")
        return
    }
    #expect(list.lostSessionIDs == ["s1", "s2"])
    #expect(list.isComplete)
    // Left out by a host with none, and by an older one.
    let none = try decode(#"{"type":"sessions","host_id":"h","sessions":[],"pending_holders":0}"#)
    guard case .sessions(let noneList) = none.message else { return }
    #expect(noneList.lostSessionIDs.isEmpty)
    let response = HostResponse(req: 4, message: .sessions(list))
    #expect(try decode(String(decoding: JSONEncoder().encode(response), as: UTF8.self)) == response)
    #expect(try json(JSONEncoder().encode(response))["lost_sessions"] as? [String] == ["s1", "s2"])
}

@Test func HostControlDecodesTheProgramsApplicationCursorKeysMode() throws {
    // A changed event from a host that reports DECCKM (`less` turned it on).
    let on = try decode("""
    {"type":"event","event":{"kind":"changed","session":{"id":"s1","name":"n","cwd":"/","command":[],"cols":80,"rows":24,
     "state":"running","pid":9,"alternate_screen":true,"kitty_keyboard_flags":0,"application_cursor_keys":true}}}
    """)
    guard case .event(.changed(let info)) = on.message else {
        Issue.record("Expected a changed event, got \(on.message)")
        return
    }
    #expect(info.applicationCursorKeys == true)
    let off = try decode("""
    {"type":"sessions","host_id":"h","sessions":[
     {"id":"s1","name":"n","cwd":"/","command":[],"cols":80,"rows":24,"state":"running","application_cursor_keys":false}]}
    """)
    guard case .sessions(let list) = off.message else {
        Issue.record("Expected sessions, got \(off.message)")
        return
    }
    #expect(list.sessions.first?.applicationCursorKeys == false)

    // A host from before it: unknown, not off.
    let older = try decode("""
    {"type":"sessions","host_id":"h","sessions":[
     {"id":"s1","name":"n","cwd":"/","command":[],"cols":80,"rows":24,"state":"running"}]}
    """)
    guard case .sessions(let olderList) = older.message else { return }
    #expect(olderList.sessions.first?.applicationCursorKeys == nil)

    // Round trips keep it, and leave it out when unknown; an exit keeps it.
    let reported = HostedSessionInfo(id: "s", name: "n", cwd: "/", applicationCursorKeys: true)
    #expect(try json(JSONEncoder().encode(reported))["application_cursor_keys"] as? Bool == true)
    #expect(try json(JSONEncoder().encode(HostedSessionInfo(id: "s", name: "n", cwd: "/")))["application_cursor_keys"] == nil)
    let response = HostResponse(req: 1, message: .sessions(HostedSessionList(hostID: "h", sessions: [reported])))
    #expect(try decode(String(decoding: JSONEncoder().encode(response), as: UTF8.self)) == response)
    #expect(reported.exited(code: 0, signal: nil).applicationCursorKeys == true)
}

@Test func HostControlAsksForTheLastLinesOfAScreenOnlyWhenLimited() throws {
    #expect(try body(of: HostRequest(req: 5, message: .screen(id: "s", scrollback: true, maxLines: 600)))
        == (try json(#"{"op":"screen","req":5,"id":"s","scrollback":true,"max_lines":600}"#)))
    #expect(try body(of: HostRequest(req: 5, message: .screen(id: "s", scrollback: false, maxLines: nil)))
        == (try json(#"{"op":"screen","req":5,"id":"s","scrollback":false}"#)))
    // Never 0 or negative: the host takes at least one line.
    #expect(try body(of: HostRequest(req: 5, message: .screen(id: "s", scrollback: false, maxLines: 0)))["max_lines"] as? Int == 1)
}
