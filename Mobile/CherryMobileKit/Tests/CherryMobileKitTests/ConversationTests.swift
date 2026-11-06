import Foundation
import Testing
@testable import CherryMobileKit

/// What `cherry host transcript` prints (Host/README.md), a newer kind
/// included.
private let firstRead = Data(#"""
{"agent":"claude","session_id":"abc","path":"/Users/me/.claude/projects/-work/abc.jsonl","title":"Fix the key tests",
 "cursor":"v1:file:1:2:300","reset":true,"more_before":true,"entries":[
  {"kind":"user","id":"u1","time":"2026-11-04T10:00:00Z","text":"Fix the tests"},
  {"kind":"assistant","id":"a1","text":"I'll run them."},
  {"kind":"tool","id":"t1","name":"Bash","summary":"swift test","status":"running"},
  {"kind":"diagram","id":"d1"},
  {"kind":"note","id":"n1","text":"Conversation compacted"}]}
"""#.utf8)

private let nextRead = Data(#"""
{"agent":"claude","session_id":"abc","path":null,"title":null,"cursor":"v1:file:1:2:420","reset":false,"more_before":false,"entries":[
  {"kind":"tool_result","id":"t1","result":"47 tests passed","status":"ok"},
  {"kind":"assistant","id":"a2","text":"All green."}]}
"""#.utf8)

@Test func aReadDecodesAndANewerKindIsLeftOut() throws {
    let read = try JSONDecoder().decode(AgentTranscript.self, from: firstRead)
    #expect(read.agent == "claude")
    #expect(read.sessionID == "abc")
    #expect(read.moreBefore)
    #expect(read.entries.map(\.kind) == [.user, .assistant, .tool, .unknown, .note])
    #expect(read.entries[2].status == .running)

    var conversation = Conversation()
    conversation.apply(read)
    #expect(conversation.entries.map(\.id) == ["u1", "a1", "t1", "n1"])
    #expect(conversation.title == "Fix the key tests")
    #expect(conversation.cursor == "v1:file:1:2:300")
}

@Test func aLaterReadFinishesToolsAndAppends() throws {
    var conversation = Conversation()
    conversation.apply(try JSONDecoder().decode(AgentTranscript.self, from: firstRead))
    conversation.apply(try JSONDecoder().decode(AgentTranscript.self, from: nextRead))
    #expect(conversation.entries.map(\.id) == ["u1", "a1", "t1", "n1", "a2"])
    let tool = try #require(conversation.entries.first { $0.id == "t1" })
    #expect(tool.status == .ok)
    #expect(tool.result == "47 tests passed")
    #expect(conversation.title == "Fix the key tests")
    #expect(conversation.cursor == "v1:file:1:2:420")
    #expect(conversation.moreBefore)

    // An entry with an id it has replaces it; a reset starts over.
    conversation.apply(AgentTranscript(agent: "claude", cursor: "c3", reset: false, entries: [
        TranscriptEntry(id: "a2", kind: .assistant, text: "All green, committed."),
    ]))
    #expect(conversation.entries.last?.text == "All green, committed.")
    #expect(conversation.entries.count == 5)
    conversation.apply(AgentTranscript(agent: "claude", cursor: "c4", reset: true, entries: [
        TranscriptEntry(id: "z", kind: .user, text: "New session"),
    ]))
    #expect(conversation.entries.map(\.id) == ["z"])
    #expect(!conversation.moreBefore)
}

@Test func aConversationKeepsItsLatestEntries() {
    var conversation = Conversation(capacity: 3)
    conversation.apply(AgentTranscript(agent: "pi", cursor: "c", reset: true, entries: (1...5).map {
        TranscriptEntry(id: "e\($0)", kind: .assistant, text: "\($0)")
    }))
    #expect(conversation.entries.map(\.id) == ["e3", "e4", "e5"])
    #expect(conversation.moreBefore)
}

@Test func transcriptFailuresSayWhatToDo() {
    #expect(SSHMacConnection.transcriptError("error: unrecognized subcommand 'transcript'", sessionID: "s") == .transcriptUnsupported)
    #expect(SSHMacConnection.transcriptError("cherry: no Claude Code, Codex, Pi or Amp conversation found for session s", sessionID: "s") == .noConversation)
    #expect(SSHMacConnection.transcriptError("cherry: no session s", sessionID: "s") == .sessionGone("s"))
    #expect(SSHMacConnection.transcriptError("cherry: exporting Amp thread T-1: timed out", sessionID: "s") == .failed("exporting Amp thread T-1: timed out"))
}

@Test func theDemoAgentsConversationFollowsAnApprovedTurn() async throws {
    let connection = try await DemoMac(turnDuration: .milliseconds(30)).connect(to: DemoMac.endpoint)
    var conversation = Conversation()
    conversation.apply(try await connection.transcript(of: "demo-claude", after: nil, limit: 100))
    #expect(conversation.entries.last?.status == .running)
    await #expect(throws: MacConnectionError.noConversation) {
        _ = try await connection.transcript(of: "demo-zsh", after: nil, limit: 100)
    }

    try await connection.send([.text("1")], to: "demo-claude")
    try await Task.sleep(for: .milliseconds(200))
    let next = try await connection.transcript(of: "demo-claude", after: conversation.cursor, limit: 100)
    #expect(!next.reset)
    conversation.apply(next)
    #expect(conversation.entries.first { $0.id == "c5" }?.status == .ok)
    #expect(conversation.entries.last?.kind == .assistant)
    #expect(conversation.entries.last?.text?.contains("16 key encoder tests passed") == true)
}
