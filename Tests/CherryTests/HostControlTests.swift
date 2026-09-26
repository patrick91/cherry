import Combine
import Darwin
import Foundation
import Testing
@testable import Cherry

@MainActor
private final class EventRecorder {
    private(set) var events: [HostSessionEvent] = []
    private var subscription: AnyCancellable?

    init(_ control: HostControl) {
        subscription = control.events.sink { [weak self] in self?.events.append($0) }
    }

    func wait(timeout: TimeInterval = 5, until condition: ([HostSessionEvent]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(events) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition(events)
    }
}

@MainActor
private func waitFor(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Test @MainActor func HostControlStartsTheHelperVerifiesTheHostSubscribesAndLists() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper(sessions: [hostedSession("s1"), hostedSession("s2", state: .exited, exitCode: 3)])
    let login = ["SSH_AUTH_SOCK": "/login/agent.sock", "PATH": "/login/bin:/usr/bin"]
    let local = makeFakeHostControl(fake, hostStore: store, loginEnvironment: login)
    defer { local.disconnect() }

    let list = try await local.list()
    #expect(list.hostID == "host-a")
    #expect(list.sessions.map(\.id) == ["s1", "s2"])
    #expect(local.state == .connected)
    #expect(local.hostID == "host-a")
    #expect(local.isSubscribed)
    #expect(local.sessions == list.sessions)
    // The helper is `cherry control`, with the login shell's variables and
    // none of a Cherry tab's identity (the test may run inside a Cherry tab).
    let launch = try #require(fake.launches.first)
    #expect(launch.executableURL.path == "/fake/bin/cherry")
    #expect(launch.arguments == ["control"])
    #expect(launch.environment["SSH_AUTH_SOCK"] == "/login/agent.sock")
    #expect(launch.environment["PATH"] == "/login/bin:/usr/bin")
    #expect(launch.environment["CHERRY_PROCESS_ID"] == nil)
    #expect(local.executableURL?.path == "/fake/bin/cherry")
    #expect(local.loginEnvironment?.environment["SSH_AUTH_SOCK"] == "/login/agent.sock")
    // Subscribe comes first, then the list the connection starts from; the
    // app never sends Hello (the helper did).
    #expect(fake.requests.map(\.op) == ["subscribe", "list", "list"])
    #expect(fake.requests.allSatisfy { $0.req != nil })
    #expect(Set(fake.requests.compactMap(\.req)).count == 3)
    // This Mac is never pinned.
    #expect(store.trustedHostID(for: .local) == nil)

    // An SSH host: `--host`, and its identity is trusted on first use.
    let devbox = try HostedSessionHost.ssh("devbox")
    let remote = makeFakeHostControl(fake, host: devbox, hostStore: store)
    defer { remote.disconnect() }
    _ = try await remote.list()
    #expect(fake.launches.last?.arguments == ["--host", "devbox", "control"])
    #expect(store.trustedHostID(for: devbox) == "host-a")
}

@Test @MainActor func HostControlMatchesRepliesToConcurrentRequests() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper(sessions: [hostedSession("s1")])
    let control = makeFakeHostControl(fake, hostStore: store)
    defer { control.disconnect() }
    try await control.connect()

    // Hold every screen request until three are in flight, then answer them
    // in reverse order.
    let held = HeldRequests()
    fake.respond = { request, connection in
        guard request.op == "screen" else { return nil }
        let ready = held.add((request, connection))
        guard ready.count == 3 else { return .silence }
        for (request, connection) in ready.reversed() {
            let id = request.string("id") ?? ""
            connection.push(.screenText(HostScreenText(
                id: id, text: "screen of \(id)", cursorRow: 0, cursorCol: 0, alternateScreen: false
            )), req: request.req)
        }
        return .silence
    }
    async let first = control.screen("a")
    async let second = control.screen("b", scrollback: true)
    async let third = control.screen("c")
    let answers = try await [first, second, third]
    #expect(answers.map(\.text) == ["screen of a", "screen of b", "screen of c"])
    // The three were in flight together (sent in any order) with distinct IDs.
    let screens = fake.requests("screen")
    #expect(Set(screens.compactMap(\.req)).count == 3)
    #expect(Dictionary(uniqueKeysWithValues: screens.map { ($0.string("id") ?? "", $0.json["scrollback"] as? Bool) })
        == ["a": false, "b": true, "c": false])
}

private final class HeldRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [(FakeControlHelper.Request, FakeControlHelper.Connection)] = []
    func add(_ request: (FakeControlHelper.Request, FakeControlHelper.Connection))
        -> [(FakeControlHelper.Request, FakeControlHelper.Connection)] {
        lock.withLock {
            held.append(request)
            return held
        }
    }
}

@Test @MainActor func HostControlRepublishesEveryEventAndKeepsTheListCurrent() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper(sessions: [hostedSession("s1")])
    let control = makeFakeHostControl(fake, hostStore: store)
    defer { control.disconnect() }
    let recorder = EventRecorder(control)
    let stream = control.eventStream()
    try await control.connect()
    let connection = try #require(fake.connections.last)

    let added = hostedSession("s2", name: "Build")
    let titled = hostedSession("s1", title: "vim")
    let sent: [HostSessionEvent] = [
        .added(added),
        .changed(titled),
        .bell(id: "s1"),
        .notification(id: "s1", title: "Build", body: "finished"),
        .progress(id: "s1", state: .set, value: 40),
        .progress(id: "s1", state: .indeterminate, value: nil),
        .exited(id: "s2", exitCode: 1, signal: nil),
        .removed(id: "s2"),
    ]
    for event in sent { connection.push(.event(event)) }
    // Unknown kinds are skipped.
    connection.write(try HostFrame.frame(body: Data(#"{"type":"event","event":{"kind":"sparkles","id":"s1"}}"#.utf8)))
    connection.push(.event(.bell(id: "last")))

    #expect(await recorder.wait { $0.count == sent.count + 1 })
    #expect(recorder.events == sent + [.bell(id: "last")])
    var streamed: [HostSessionEvent] = []
    for await event in stream {
        streamed.append(event)
        if streamed.count == sent.count + 1 { break }
    }
    #expect(streamed == recorder.events)
    // added → listed, changed → replaced, exited → exited, removed → gone.
    #expect(control.sessions == [titled])

    connection.push(.event(.exited(id: "s1", exitCode: 130, signal: 2)))
    #expect(await waitFor { control.sessions.first?.state == .exited })
    #expect(control.sessions.first?.exitCode == 130)
    #expect(control.sessions.first?.exitSignal == 2)
    #expect(control.sessions.first?.title == "vim")
}

@Test @MainActor func HostControlSkipsBinaryFramesAndKeepsTheConnection() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper(sessions: [hostedSession("s1")])
    let control = makeFakeHostControl(fake, hostStore: store)
    defer { control.disconnect() }
    let recorder = EventRecorder(control)
    try await control.connect()

    // A control connection never attaches, so no binary frame is for it.
    // Any that arrive (every kind, one this version does not know, a
    // malformed one, a large one) are skipped, even when their bytes look
    // like the reply a request waits for, and the connection carries on.
    fake.respond = { request, connection in
        guard request.op == "screen", let req = request.req else { return nil }
        let impostor = Data(#"{"type":"screen_text","id":"s1","text":"impostor","cursor_row":0,"cursor_col":0,"alternate_screen":false,"req":\#(req)}"#.utf8)
        connection.push(.output(offset: 0, data: impostor))
        connection.push(.query(impostor))
        connection.push(.input(impostor))
        connection.push(.attached(header: Data(#"{"offset":0,"reason":"attach","req":\#(req)}"#.utf8), snapshot: impostor))
        connection.push(.output(offset: 1 << 40, data: Data(repeating: 0x61, count: 4 * 1_024 * 1_024)))
        connection.write(try! HostFrame.frame(body: Data([99]) + impostor))
        connection.write(try! HostFrame.frame(body: Data([1, 0, 0])))
        connection.write(try! HostFrame.frame(body: Data([4, 0xFF, 0, 0, 0]) + impostor))
        // Only a leading `{` marks JSON. JSONDecoder would accept these
        // whitespace-led replies to the pending request (protocol 5 read
        // them as its answer); they are binary frames of unknown kinds.
        let failure = Data(#"{"type":"error","code":"request_failed","message":"impostor","req":\#(req)}"#.utf8)
        connection.write(try! HostFrame.frame(body: Data([0x20]) + failure))
        connection.write(try! HostFrame.frame(body: Data([0x0A]) + impostor))
        connection.write(try! HostFrame.frame(body: Data([0x09]) + failure))
        connection.write(try! HostFrame.frame(body: Data([0x0D, 0x0A]) + impostor))
        connection.push(.event(.bell(id: "s1")))
        return nil
    }
    let screen = try await control.screen("s1")
    #expect(screen.text == "fake screen")
    #expect(await recorder.wait { $0 == [.bell(id: "s1")] })
    #expect(control.state == .connected)
    #expect(fake.launches.count == 1)
    fake.respond = nil
    #expect(try await control.list().sessions.map(\.id) == ["s1"])
    #expect(fake.launches.count == 1)
}

@Test @MainActor func HostControlReconnectsAfterALostConnectionAndRelistsWhatChanged() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper(sessions: [hostedSession("keep"), hostedSession("ends"), hostedSession("gone")])
    let control = makeFakeHostControl(fake, hostStore: store)
    defer { control.disconnect() }
    let recorder = EventRecorder(control)
    let lease = control.retain()
    defer { lease.release() }
    #expect(await waitFor { control.state == .connected })
    #expect(fake.launches.count == 1)

    // A request in flight when the connection drops may or may not have
    // happened: it fails as a transport failure.
    fake.respond = { request, _ in request.op == "update" ? .silence : nil }
    let update = Task { try await control.update("keep", name: "Renamed") }
    #expect(await fake.wait { fake.requests("update").count == 1 })
    // Meanwhile on the host: one session ended, one was removed, one was created.
    fake.sessions = [
        hostedSession("keep"), hostedSession("ends", state: .exited, exitCode: 0), hostedSession("new"),
    ]
    fake.respond = nil
    fake.dropAll(stderr: "cherry: connection to devbox closed")
    let failure = await #expect(throws: HostedSessionError.self) { try await update.value }
    #expect(failure?.isTransportFailure == true)
    #expect(failure?.localizedDescription.contains("connection to devbox closed") == true)

    // Leased: it reconnects on its own, lists again and reports the difference.
    #expect(await waitFor { control.state == .connected && fake.launches.count == 2 })
    #expect(await recorder.wait { $0.last == .resync })
    #expect(control.sessions.map(\.id) == ["keep", "ends", "new"])
    #expect(recorder.events.contains(.removed(id: "gone")))
    #expect(recorder.events.contains(.added(hostedSession("new"))))
    #expect(recorder.events.contains(.changed(hostedSession("ends", state: .exited, exitCode: 0))))
    #expect(recorder.events.contains(.exited(id: "ends", exitCode: 0, signal: nil)))
    #expect(!recorder.events.contains { $0.sessionID == "keep" })
    #expect(fake.requests.suffix(2).map(\.op) == ["subscribe", "list"])

    // Helpers that fail to start are retried with backoff while leased.
    fake.launchFailure = "helper missing"
    fake.dropAll()
    #expect(await waitFor { fake.launches.count >= 5 })
    guard case .waitingToReconnect(let error) = control.state else {
        Issue.record("Expected a reconnect wait, got \(control.state)")
        return
    }
    #expect(error.isUnavailable)
    fake.launchFailure = nil
    #expect(await waitFor { control.state == .connected })

    // Without a lease, a lost connection is not reopened until it is used.
    lease.release()
    try await Task.sleep(for: .milliseconds(20))
    let launches = fake.launches.count
    fake.dropAll()
    #expect(await waitFor { control.state == .idle })
    try await Task.sleep(for: .milliseconds(100))
    #expect(fake.launches.count == launches)
    _ = try await control.list()
    #expect(fake.launches.count == launches + 1)
}

@Test @MainActor func HostControlRelistsWhenTheHostSaysItFellBehind() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper(sessions: [hostedSession("s1")])
    let control = makeFakeHostControl(fake, hostStore: store)
    defer { control.disconnect() }
    let recorder = EventRecorder(control)
    try await control.connect()
    let lists = fake.requests("list").count

    fake.sessions = [hostedSession("s1", title: "missed title"), hostedSession("s2")]
    try #require(fake.connections.last).push(.event(.resync))
    #expect(await recorder.wait { $0.last == .resync })
    #expect(fake.requests("list").count == lists + 1)
    #expect(recorder.events == [
        .changed(hostedSession("s1", title: "missed title")), .added(hostedSession("s2")), .resync,
    ])
    #expect(control.sessions.map(\.title) == ["missed title", nil])
}

@Test @MainActor func HostControlRefusesAnUntrustedIdentityUntilTheUserTrustsIt() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let devbox = try store.add("devbox")
    store.trust("host-a", for: devbox)
    let fake = FakeControlHelper(sessions: [hostedSession("s1")])
    fake.hostID = "host-b"
    let control = makeFakeHostControl(fake, host: devbox, hostStore: store)
    defer { control.disconnect() }
    let lease = control.retain()
    defer { lease.release() }

    let failure = await #expect(throws: HostedSessionError.self) { try await control.list() }
    #expect(failure?.isIdentityMismatch == true)
    #expect(failure?.localizedDescription == "Expected host identity host-a, received host-b.")
    // Nothing reached the untrusted host, and nothing retries on its own.
    #expect(fake.requests.isEmpty)
    #expect(control.hostID == nil)
    #expect(control.sessions.isEmpty)
    guard case .failed(let error) = control.state, error.isIdentityMismatch else {
        Issue.record("Expected an identity failure, got \(control.state)")
        return
    }
    let launches = fake.launches.count
    try await Task.sleep(for: .milliseconds(150))
    #expect(fake.launches.count == launches)
    #expect(store.trustedHostID(for: devbox) == "host-a")
    await #expect(throws: HostedSessionError.self) { try await control.terminate("s1") }
    #expect(fake.requests.isEmpty)

    try await control.trustNewIdentity()
    #expect(store.trustedHostID(for: devbox) == "host-b")
    #expect(control.hostID == "host-b")
    #expect(try await control.list().sessions.map(\.id) == ["s1"])

    // A tab pinned to the old identity is refused before anything is sent.
    let updates = fake.requests("update").count
    let pinned = await #expect(throws: HostedSessionError.self) {
        try await control.update("s1", name: "x", expectedHostID: "host-a")
    }
    #expect(pinned?.isIdentityMismatch == true)
    #expect(fake.requests("update").count == updates)
}

@Test @MainActor func HostControlReportsStructuredErrors() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper(sessions: [hostedSession("s1")])

    // A disk image copy never starts a local helper.
    let diskImage = makeFakeHostControl(fake, hostStore: store, localHostUnavailableReason: "Move Cherry to Applications first.")
    let unavailable = await #expect(throws: HostedSessionError.self) { try await diskImage.list() }
    #expect(unavailable == .unavailable("Move Cherry to Applications first."))
    #expect(fake.launches.isEmpty)

    // The helper explains why it could not connect (ssh's own message).
    fake.exitBeforeWelcome = "ssh: connect to host devbox port 22: Connection refused\n"
    let refused = makeFakeHostControl(fake, host: try .ssh("devbox"), hostStore: store)
    let connectFailure = await #expect(throws: HostedSessionError.self) { try await refused.list() }
    #expect(connectFailure?.isUnavailable == true)
    #expect(connectFailure?.localizedDescription == "ssh: connect to host devbox port 22: Connection refused")
    fake.exitBeforeWelcome = nil

    // A helper that cannot start at all.
    fake.launchFailure = "No such file"
    let missing = makeFakeHostControl(fake, hostStore: store)
    let launchFailure = await #expect(throws: HostedSessionError.self) { try await missing.list() }
    #expect(launchFailure?.isUnavailable == true)
    #expect(launchFailure?.localizedDescription.contains("No such file") == true)
    fake.launchFailure = nil

    // A missing helper in the app is a definite local failure.
    let noHelper = HostControl(
        host: .local, clientProvider: { throw HostedSessionError.message("The cherry session client is missing.") },
        hostStore: store, masters: disabledSSHMasters, launcher: fake.launcher, localHostUnavailableReason: nil,
        configuration: .fastTests
    )
    #expect(await #expect(throws: HostedSessionError.self) { try await noHelper.list() }
        == .message("The cherry session client is missing."))

    // Failing while setting up (after the Welcome) sent nothing the caller asked for.
    fake.respond = { request, _ in request.op == "subscribe" ? .exit(stderr: "cherry: the host went away") : nil }
    let setup = makeFakeHostControl(fake, hostStore: store)
    let setupFailure = await #expect(throws: HostedSessionError.self) { try await setup.list() }
    #expect(setupFailure == .unavailable("cherry: the host went away"))
    fake.respond = nil

    // Another protocol version is reported, not spoken.
    fake.version = HostProtocol.version + 1
    let newer = makeFakeHostControl(fake, hostStore: store)
    let versionFailure = await #expect(throws: HostedSessionError.self) { try await newer.list() }
    #expect(versionFailure?.localizedDescription.contains("protocol \(HostProtocol.version + 1)") == true)
    fake.version = HostProtocol.version

    let control = makeFakeHostControl(fake, hostStore: store)
    defer { control.disconnect() }
    try await control.connect()
    // The host's own answer keeps its code.
    fake.respond = { request, _ in
        switch request.op {
        case "send_input": .answer(.error(code: "not_running", message: "session s1 has exited"))
        case "remove": .answer(.created(hostedSession("odd")))
        case "kill": .answer(.ok)
        case "screen": .silence
        default: nil
        }
    }
    let rejected = await #expect(throws: HostedSessionError.self) { try await control.sendInput("s1", Data("x".utf8)) }
    #expect(rejected == .rejected(code: "not_running", message: "session s1 has exited"))
    #expect(rejected?.hostErrorCode == "not_running")
    #expect(await #expect(throws: HostedSessionError.self) { try await control.remove("s1") }?.localizedDescription
        .contains("unexpected answer") == true)
    // A reply this version cannot read fails its own request only.
    fake.respond = { request, connection in
        guard request.op == "list" else { return nil }
        connection.write(try! HostFrame.frame(body: Data(#"{"type":"sessions","host_id":1,"req":\#(request.req!)}"#.utf8)))
        return .silence
    }
    let unreadable = await #expect(throws: HostedSessionError.self) { try await control.list() }
    #expect(unreadable?.localizedDescription.contains("cannot read") == true)
    #expect(control.state == .connected)
    fake.respond = nil

    // No answer in time: it may or may not have happened.
    var impatient = HostControl.Configuration.fastTests
    impatient.requestTimeout = .milliseconds(100)
    let slow = makeFakeHostControl(fake, hostStore: store, configuration: impatient)
    defer { slow.disconnect() }
    try await slow.connect()
    fake.respond = { request, _ in request.op == "screen" ? .silence : nil }
    let timedOut = await #expect(throws: HostedSessionError.self) { try await slow.screen("s1") }
    #expect(timedOut?.isTransportFailure == true)
    #expect(timedOut?.localizedDescription.contains("did not answer") == true)
    fake.respond = nil
    // A slow request does not end a live connection.
    #expect(slow.state == .connected)
    try await slow.terminate("s1")

    // Invalid input never leaves the app.
    let creates = fake.requests("create").count
    for bad in [
        HostCreateRequest(requestID: UUID(), name: "x", cwd: "relative/dir"),
        HostCreateRequest(requestID: UUID(), name: "x", cwd: "/", cols: 1),
        HostCreateRequest(requestID: UUID(), name: "x", cwd: "/", owner: String(repeating: "o", count: 257)),
        HostCreateRequest(requestID: UUID(), name: "x", cwd: "/", tags: ["": "empty key"]),
    ] {
        await #expect(throws: HostedSessionError.self) { try await control.create(bad) }
    }
    #expect(fake.requests("create").count == creates)
}

@Test @MainActor func HostControlCreatesOnceWhenItsAnswerIsLost() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper()
    let control = makeFakeHostControl(fake, hostStore: store)
    defer { control.disconnect() }
    try await control.connect()

    // The first Create is lost with its connection; the second, on a new
    // connection, carries the same request ID.
    let dropped = HostControlFlag()
    fake.respond = { request, _ in
        guard request.op == "create", !dropped.value else { return nil }
        dropped.set()
        return .exit(stderr: "cherry: connection lost")
    }
    let requestID = UUID()
    let session = try await control.create(
        name: "-dev", cwd: "~/code", command: ["/bin/zsh", "-l"], environment: ["TERM": "xterm-ghostty"],
        owner: "Cherry", tags: ["cherry.tab": "T1"], cols: 132, rows: 43, requestID: requestID
    )
    let creates = fake.requests("create")
    #expect(creates.count == 2)
    #expect(Set(creates.compactMap { $0.string("request_id") }) == [requestID.uuidString.lowercased()])
    #expect(fake.launches.count == 2)
    #expect(session.id == "session-\(requestID.uuidString.lowercased())")
    let sent = try #require(creates.last).json
    #expect(sent["name"] as? String == "-dev")
    #expect(sent["cwd"] as? String == "~/code")
    #expect(sent["command"] as? [String] == ["/bin/zsh", "-l"])
    #expect(sent["env"] as? [String: String] == ["TERM": "xterm-ghostty"])
    #expect(sent["owner"] as? String == "Cherry")
    #expect(sent["tags"] as? [String: String] == ["cherry.tab": "T1"])
    #expect(sent["cols"] as? Int == 132)
    #expect(sent["rows"] as? Int == 43)
    #expect(control.sessions.contains(session))

    // Lost twice: the caller learns it may have been created.
    fake.respond = { request, _ in request.op == "create" ? .exit(stderr: nil) : nil }
    let lost = await #expect(throws: HostedSessionError.self) {
        try await control.create(name: "again", cwd: "", requestID: UUID())
    }
    #expect(lost?.isTransportFailure == true)
    #expect(fake.requests("create").count == 4)
    // Lost, and the retry cannot even connect: still "may have happened".
    fake.respond = { [weak fake] request, _ in
        guard request.op == "create", let fake else { return nil }
        fake.launchFailure = "helper gone"
        return .exit(stderr: "cherry: connection lost")
    }
    let unreachable = await #expect(throws: HostedSessionError.self) {
        try await control.create(name: "unreachable", cwd: "")
    }
    #expect(unreachable == .transport("cherry: connection lost"))
    fake.launchFailure = nil
    fake.respond = nil
    let beforeRejection = fake.requests("create").count
    // A definite answer is never retried.
    fake.respond = { request, _ in
        request.op == "create" ? .answer(.error(code: "request_failed", message: "working directory does not exist")) : nil
    }
    let rejected = await #expect(throws: HostedSessionError.self) {
        try await control.create(name: "rejected", cwd: "/missing")
    }
    #expect(rejected == .rejected(code: "request_failed", message: "working directory does not exist"))
    #expect(fake.requests("create").count == beforeRejection + 1)
}

@Test @MainActor func HostControlSendsInputInOrderAndReadsScreens() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper(sessions: [hostedSession("s1")])
    let control = makeFakeHostControl(fake, hostStore: store)
    defer { control.disconnect() }

    let input = Data((0..<(2 * HostProtocol.maxInputBytes + 10)).map { UInt8(truncatingIfNeeded: $0 * 7) })
    try await control.sendInput("s1", input, expectedHostID: "host-a")
    let chunks = fake.requests("send_input")
    #expect(chunks.count == 3)
    #expect(chunks.allSatisfy { $0.string("id") == "s1" })
    let decoded = chunks.compactMap { $0.string("data").flatMap { Data(base64Encoded: $0) } }
    #expect(decoded.map(\.count) == [HostProtocol.maxInputBytes, HostProtocol.maxInputBytes, 10])
    #expect(decoded.reduce(Data(), +) == input)
    try await control.sendInput("s1", Data())
    #expect(fake.requests("send_input").count == 4)

    let screen = try await control.screen("s1", scrollback: true)
    #expect(screen == HostScreenText(id: "s1", text: "fake screen", cursorRow: 1, cursorCol: 2, alternateScreen: false))
    try await control.update("s1", name: "Renamed")
    try await control.update("s1", tags: ["cherry.kind": "agent"])
    let updates = fake.requests("update").map(\.json)
    #expect(updates[0]["name"] as? String == "Renamed")
    #expect(updates[0]["tags"] == nil)
    #expect(updates[1]["name"] == nil)
    #expect(updates[1]["tags"] as? [String: String] == ["cherry.kind": "agent"])
    try await control.terminate("s1")
    #expect(await waitFor { control.sessions.first?.isRunning == false })
    try await control.remove("s1")
    #expect(control.sessions.isEmpty)
}

@Test @MainActor func HostControlPingsAndReplacesAConnectionThatStoppedAnswering() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper()
    var configuration = HostControl.Configuration.fastTests
    configuration.heartbeatInterval = .milliseconds(30)
    configuration.pingTimeout = .milliseconds(150)
    let control = makeFakeHostControl(fake, hostStore: store, configuration: configuration)
    defer { control.disconnect() }
    let lease = control.retain()
    defer { lease.release() }
    #expect(await waitFor { control.state == .connected })
    #expect(await fake.wait { fake.requests("ping").count >= 3 })
    #expect(fake.launches.count == 1)

    // The host (or the network) stops answering: the ping times out, the
    // connection is closed, and a new one is made.
    let silenced = HostControlFlag()
    silenced.set()
    fake.respond = { request, connection in
        guard request.op == "ping", silenced.value, connection.number == 0 else { return nil }
        return .silence
    }
    #expect(await waitFor { fake.launches.count == 2 && control.state == .connected })
    #expect(fake.connections.first?.isClosed == true)

    // Without events the idle limit applies, so pings come more often than
    // the heartbeat interval.
    #expect(HostProtocol.idleTimeout / 2 < HostProtocol.heartbeatInterval)
}

@Test @MainActor func HostControlWithoutEventsPollsForASessionToEnd() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper(sessions: [hostedSession("s1")])
    fake.supportsSubscribe = false
    let control = makeFakeHostControl(fake, hostStore: store)
    defer { control.disconnect() }
    try await control.connect()
    #expect(!control.isSubscribed)
    #expect(control.state == .connected)

    fake.sessions = [hostedSession("s1", state: .exited, exitCode: 0)]
    let lists = fake.requests("list").count
    #expect(try await control.waitForSession("s1", timeout: .seconds(5)) { $0?.isRunning == false })
    #expect(fake.requests("list").count > lists)
    #expect(try await !control.waitForSession("s1", timeout: .milliseconds(80)) { $0 == nil })
}

@Test @MainActor func HostControlWaitingForEventsFallsBackToPollingWhenTheConnectionDrops() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper(sessions: [hostedSession("s1")])
    let control = makeFakeHostControl(fake, hostStore: store)
    defer { control.disconnect() }
    try await control.connect()
    #expect(control.isSubscribed)

    let waiting = Task { try await control.waitForSession("s1", timeout: .seconds(5)) { $0?.isRunning == false } }
    try await Task.sleep(for: .milliseconds(50))
    // The session ends while the connection is lost: no event reports it.
    fake.sessions = [hostedSession("s1", state: .exited, exitCode: 0)]
    fake.dropAll()
    #expect(try await waiting.value)
    #expect(fake.launches.count == 2)
}

@Test @MainActor func HostControlClosesAnUnusedConnection() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper()
    var configuration = HostControl.Configuration.fastTests
    configuration.idleDisconnectDelay = .milliseconds(100)
    let control = makeFakeHostControl(fake, hostStore: store, configuration: configuration)
    _ = try await control.list()
    // The helper sees the end of its input and exits.
    #expect(await waitFor { control.state == .idle })
    #expect(await fake.wait { fake.connections.first?.isClosed == true })

    // A lease keeps it open.
    let lease = control.retain()
    #expect(await waitFor { control.state == .connected })
    try await Task.sleep(for: .milliseconds(250))
    #expect(control.state == .connected)
    lease.release()
    #expect(await waitFor { control.state == .idle })
    #expect(await fake.wait { fake.connections.allSatisfy { $0.isClosed } })
}

@Test @MainActor func HostControlClosesAnUnusedConnectionDespiteItsHeartbeat() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper()
    var configuration = HostControl.Configuration.fastTests
    // As in production (15 s and 60 s), pings come several times per idle period.
    configuration.heartbeatInterval = .milliseconds(30)
    configuration.idleDisconnectDelay = .milliseconds(400)
    let control = makeFakeHostControl(fake, hostStore: store, configuration: configuration)
    defer { control.disconnect() }
    _ = try await control.list()

    // Pings keep a connection alive; they do not use it.
    #expect(await waitFor { control.state == .idle })
    #expect(fake.requests("ping").count >= 2)
    #expect(await fake.wait { fake.connections.first?.isClosed == true })
    #expect(fake.launches.count == 1)

    // A request someone makes restarts the countdown; the next heartbeat does not.
    _ = try await control.list()
    #expect(fake.launches.count == 2)
    #expect(await waitFor { control.state == .idle })
}

@Test @MainActor func HostControlRetriesACreateThatWentUnansweredOnANewConnection() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper()
    var configuration = HostControl.Configuration.fastTests
    configuration.requestTimeout = .milliseconds(150)
    let control = makeFakeHostControl(fake, hostStore: store, configuration: configuration)
    defer { control.disconnect() }
    try await control.connect()

    // The connection stays up but the first Create is never answered: the
    // retry does not wait on that connection again.
    let unanswered = FakeCountdown(1)
    fake.respond = { request, _ in request.op == "create" && unanswered.take() ? .silence : nil }
    let requestID = UUID()
    let session = try await control.create(name: "x", cwd: "/tmp", requestID: requestID)
    #expect(session.id == "session-\(requestID.uuidString.lowercased())")
    let creates = fake.requests("create")
    #expect(creates.count == 2)
    #expect(Set(creates.compactMap { $0.string("request_id") }) == [requestID.uuidString.lowercased()])
    #expect(fake.launches.count == 2)
    #expect(await fake.wait { fake.connections.first?.isClosed == true })
    #expect(control.state == .connected)
    #expect(control.sessions.contains(session))
}

@Test @MainActor func HostControlHasTheHelperRefuseAnUntrustedHostBeforeUsingIt() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let devbox = try store.add("devbox")
    // Hosts' identities are UUIDs; the helper accepts only those.
    let trusted = UUID().uuidString.lowercased()
    let other = UUID().uuidString.lowercased()
    store.trust(trusted, for: devbox)
    let fake = FakeControlHelper(sessions: [hostedSession("s1")])
    fake.hostID = trusted
    let control = makeFakeHostControl(fake, host: devbox, hostStore: store)
    defer { control.disconnect() }
    _ = try await control.list()
    #expect(fake.launches.last?.arguments == ["--host", "devbox", "--expected-host-id", trusted, "control"])

    // Another host answers for the destination. The helper refuses it before
    // using it (or replacing an older one), and the app reports a mismatch,
    // not an unreachable host.
    control.disconnect()
    fake.hostID = other
    let requests = fake.requests.count
    let failure = await #expect(throws: HostedSessionError.self) { try await control.list() }
    #expect(failure == .identityMismatch("Expected host identity \(trusted), received \(other)."))
    #expect(fake.requests.count == requests)
    guard case .failed(let error) = control.state, error.isIdentityMismatch else {
        Issue.record("Expected an identity failure, got \(control.state)")
        return
    }
    // The trusted host's last known sessions stay; the other host's are never listed.
    #expect(control.sessions.map(\.id) == ["s1"])
    #expect(control.hostID == nil)
    #expect(store.trustedHostID(for: devbox) == trusted)

    // Trusting the new identity is the user's decision: that helper expects none.
    try await control.trustNewIdentity()
    #expect(fake.launches.last?.arguments == ["--host", "devbox", "control"])
    #expect(store.trustedHostID(for: devbox) == other)
    control.disconnect()
    _ = try await control.list()
    #expect(fake.launches.last?.arguments == ["--host", "devbox", "--expected-host-id", other, "control"])

    // Identities the helper would not accept are left to the app's own check.
    #expect(HostControl.expectedHostIDArguments("host-a").isEmpty)
    #expect(HostControl.expectedHostIDArguments(nil).isEmpty)
    #expect(HostControl.failureBeforeWelcome("cherry: ssh: connect to host devbox port 22: Connection refused")
        == .unavailable("cherry: ssh: connect to host devbox port 22: Connection refused"))
    #expect(HostControl.failureBeforeWelcome("cherry: host identity changed (garbled").isIdentityMismatch)
}

@Test @MainActor func HostControlStopsWaitingForASessionWhenAnotherHostAnswers() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let devbox = try store.add("devbox")
    store.trust("host-a", for: devbox)
    let fake = FakeControlHelper(sessions: [hostedSession("s1")])
    let control = makeFakeHostControl(fake, host: devbox, hostStore: store)
    defer { control.disconnect() }
    let lease = control.retain()
    defer { lease.release() }
    #expect(await waitFor { control.state == .connected && control.sessions.count == 1 })

    let waiting = Task { try await control.waitForSession("s1", timeout: .seconds(10)) { $0?.isRunning != true } }
    try await Task.sleep(for: .milliseconds(50))
    // The connection drops and another host (without that session) answers.
    fake.hostID = "host-b"
    fake.sessions = []
    let launches = fake.launches.count
    let dropped = ContinuousClock.now
    fake.dropAll()

    // Not "gone": that host says nothing about this session. It ends then,
    // not when the timeout passes.
    #expect(try await !waiting.value)
    #expect(ContinuousClock.now - dropped < .seconds(8))
    guard case .failed(let error) = control.state, error.isIdentityMismatch else {
        Issue.record("Expected an identity failure, got \(control.state)")
        return
    }
    #expect(control.sessions.map(\.id) == ["s1"])
    #expect(try await !control.waitForSession("s1", timeout: .seconds(10)) { $0 == nil })
    // Nothing keeps connecting to the other host.
    try await Task.sleep(for: .milliseconds(150))
    #expect(fake.launches.count == launches + 1)
}

@Test @MainActor func HostControlRegistryHasOneControlPerHost() throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let registry = makeFakeHostControlRegistry(FakeControlHelper(), hostStore: store)
    let devbox = try HostedSessionHost.ssh("devbox")
    #expect(registry.control(for: .local) === registry.control(for: .local))
    #expect(registry.control(for: devbox) === registry.control(for: try .ssh(" devbox ")))
    #expect(registry.control(for: devbox) !== registry.control(for: .local))
    #expect(registry.all.count == 2)
}

/// The real process path: `HostControlChannel.process` runs a helper script
/// that records how it was started and relays its standard input and output
/// to a fake host on a Unix socket, as `cherry control` relays the daemon's.
@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/nc")))
@MainActor func HostControlRunsTheHelperProcessWithTheLoginEnvironment() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ch-ctl-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let socketPath = root.appendingPathComponent("h.sock").path
    let server = try FakeHostSocketServer(path: socketPath, hostID: "host-real")
    defer { server.stop() }
    let helper = root.appendingPathComponent("cherry")
    try """
    #!/bin/sh
    printf '%s\\n' "$@" > '\(root.path)/arguments'
    printf '%s' "${SSH_AUTH_SOCK-}" > '\(root.path)/agent'
    printf '%s' "${CHERRY_PROCESS_ID-unset}" > '\(root.path)/tab'
    printf '%s' "$$" > '\(root.path)/pid'
    exec /usr/bin/nc -U '\(socketPath)'
    """.write(to: helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

    let control = HostControl(
        host: .local,
        clientProvider: {
            HostedSessionClient(
                executableURL: helper,
                loginEnvironment: { _ in .init(environment: ["SSH_AUTH_SOCK": "/login/agent.sock"]) }
            )
        },
        hostStore: store, masters: disabledSSHMasters, localHostUnavailableReason: nil, configuration: .fastTests
    )
    let list = try await control.list()
    #expect(list.hostID == "host-real")
    #expect(list.sessions.map(\.id) == ["real-1"])
    func read(_ name: String) -> String? { try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
    #expect(read("arguments") == "control\n")
    #expect(read("agent") == "/login/agent.sock")
    #expect(read("tab") == "unset")
    try await control.sendInput("real-1", Data("hi".utf8))
    #expect(server.received.map(\.op) == ["subscribe", "list", "list", "send_input"])

    // Disconnecting closes the helper's input; one that lingers is ended.
    let pid = try #require(pid_t(read("pid") ?? ""))
    control.disconnect()
    let deadline = Date().addingTimeInterval(5)
    while kill(pid, 0) == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(kill(pid, 0) != 0)
}

/// Serves protocol 6 on a Unix socket, one client at a time: Welcome, then
/// answers (subscribe, list, send_input, ping).
private final class FakeHostSocketServer: @unchecked Sendable {
    private let listener: Int32
    private let hostID: String
    private let lock = NSLock()
    private var requests: [FakeControlHelper.Request] = []
    private var stopped = false

    var received: [FakeControlHelper.Request] { lock.withLock { requests } }

    init(path: String, hostID: String) throws {
        self.hostID = hostID
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: Array(path.utf8) + [0])
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 4) == 0 else { throw HostedSessionError.message("bind failed") }
        Thread { [self] in acceptLoop() }.start()
    }

    func stop() {
        lock.withLock { stopped = true }
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    private func acceptLoop() {
        while !lock.withLock({ stopped }) {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            Thread { [self] in serve(client) }.start()
        }
    }

    private func send(_ response: HostResponse, to client: Int32) {
        guard let frame = try? HostFrame.encode(response) else { return }
        frame.withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        send(HostResponse(req: nil, message: .welcome(version: HostProtocol.version, hostID: hostID)), to: client)
        var decoder = HostFrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            buffer.withUnsafeBytes { decoder.append(UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            while let body = try? decoder.nextFrame() {
                guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                      let op = json["op"] as? String
                else { continue }
                let req = (json["req"] as? NSNumber)?.uint64Value
                lock.withLock { requests.append(.init(op: op, req: req, json: json, body: body)) }
                let message: HostServerMessage = switch op {
                case "list": .sessions(HostedSessionList(hostID: hostID, sessions: [hostedSession("real-1")]))
                case "ping": .pong
                default: .ok
                }
                send(HostResponse(req: req, message: message), to: client)
            }
        }
    }
}

@Test @MainActor func HostControlKeepsSessionsARestartedDaemonHasNotListedYetAndListsUntilItHas() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper(sessions: [hostedSession("early"), hostedSession("late"), hostedSession("gone")])
    fake.pendingHolders = 0
    var configuration = HostControl.Configuration.fastTests
    configuration.pendingHolderRelistInterval = .milliseconds(50)
    let control = makeFakeHostControl(fake, hostStore: store, configuration: configuration)
    defer { control.disconnect() }
    let recorder = EventRecorder(control)
    let lease = control.retain()
    defer { lease.release() }
    #expect(await waitFor { control.state == .connected && control.sessions.count == 3 })

    // The daemon restarted: only one holder registered again so far, and
    // it still expects others. The sessions it lacks keep their state
    // (nothing is reported removed), and it is listed again.
    fake.sessions = [hostedSession("early")]
    fake.pendingHolders = 2
    let lists = fake.requests("list").count
    fake.dropAll()
    #expect(await recorder.wait { $0.last == .resync })
    #expect(control.sessions.map(\.id).sorted() == ["early", "gone", "late"])
    #expect(!recorder.events.contains { if case .removed = $0 { true } else { false } })
    #expect(await fake.wait { fake.requests("list").count >= lists + 3 })

    // Complete: what is still missing is gone.
    fake.sessions = [hostedSession("early"), hostedSession("late")]
    fake.pendingHolders = 0
    #expect(await recorder.wait { $0.contains(.removed(id: "gone")) })
    #expect(control.sessions.map(\.id) == ["early", "late"])
    #expect(!recorder.events.contains(.removed(id: "late")))
    // And it stops listing.
    let settled = fake.requests("list").count
    try await Task.sleep(for: .milliseconds(300))
    #expect(fake.requests("list").count == settled)

    // Waiting for the holders: listed until none is pending, within the bound.
    fake.pendingHolders = 1
    let bounded = try await control.listUntilHoldersRegistered(timeout: .milliseconds(200), pollInterval: .milliseconds(20))
    #expect(bounded.pendingHolders == 1)
    fake.respond = { [fake] request, _ in
        guard request.op == "list" else { return nil }
        fake.pendingHolders = 0
        return nil
    }
    let complete = try await control.listUntilHoldersRegistered(
        after: bounded, timeout: .seconds(5), pollInterval: .milliseconds(20)
    )
    #expect(complete.isComplete)
}

@Test @MainActor func HostControlGoesOnListingUntilAHolderThatNeverCameBackIsNoLongerExpected() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper(sessions: [hostedSession("early"), hostedSession("stuck")])
    fake.pendingHolders = 0
    var configuration = HostControl.Configuration.fastTests
    configuration.pendingHolderRelistInterval = .milliseconds(20)
    configuration.pendingHolderRelists = 3
    configuration.pendingHolderSlowRelistInterval = .milliseconds(250)
    let control = makeFakeHostControl(fake, hostStore: store, configuration: configuration)
    defer { control.disconnect() }
    let recorder = EventRecorder(control)
    let lease = control.retain()
    defer { lease.release() }
    #expect(await waitFor { control.state == .connected && control.sessions.count == 2 })
    #expect(!control.expectsHolders)
    // Known as current only from the host it names, while connected.
    #expect(control.currentSession("stuck", hostID: "host-a")?.id == "stuck")
    #expect(control.currentSession("stuck", hostID: "host-b") == nil)

    // The daemon restarted; one holder has not registered again (it is
    // stopped, say) well past the quick re-lists.
    fake.sessions = [hostedSession("early")]
    fake.pendingHolders = 1
    fake.dropAll()
    #expect(await recorder.wait { $0.last == .resync })
    #expect(control.expectsHolders)
    let registered = Recorder(0)
    let subscription = control.holdersRegistered().sink { registered.value += 1 }
    defer { subscription.cancel() }
    let lists = fake.requests("list").count
    // It goes on listing past the quick re-lists, less often, and keeps
    // the session meanwhile.
    #expect(await fake.wait { fake.requests("list").count >= lists + 5 })
    #expect(control.sessions.map(\.id).sorted() == ["early", "stuck"])
    #expect(!recorder.events.contains(.removed(id: "stuck")))
    #expect(registered.value == 0)

    // Its holder is gone, so the host no longer expects it: the next list
    // is complete, the session is removed, and the wait for the holders
    // ends (once).
    fake.pendingHolders = 0
    #expect(await recorder.wait { $0.contains(.removed(id: "stuck")) })
    #expect(!control.expectsHolders)
    #expect(await fake.wait { registered.value == 1 })
    #expect(control.sessions.map(\.id) == ["early"])
    // And it stops listing.
    let settled = fake.requests("list").count
    try await Task.sleep(for: .milliseconds(600))
    #expect(fake.requests("list").count == settled)
    #expect(registered.value == 1)

    // Not known as current once the connection is gone.
    control.disconnect()
    #expect(control.currentSession("early", hostID: "host-a") == nil)
}

// MARK: - Replies overtaken by events

@Test @MainActor func HostControlKeepsAnExitThatOvertookTheCreatedReply() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper()
    let control = makeFakeHostControl(fake, hostStore: store)
    defer { control.disconnect() }
    try await control.connect()
    let recorder = EventRecorder(control)

    // The host takes the Created snapshot while the program runs, the
    // program exits at once, and its events reach the app before the reply.
    fake.respond = { [weak fake] request, connection in
        guard request.op == "create", let fake,
              case .answer(.created(let session)) = fake.defaultReply(to: request, on: connection)
        else { return nil }
        let exited = session.exited(code: 1, signal: nil)
        fake.sessions = [exited]
        connection.push(.event(.added(session)))
        connection.push(.event(.exited(id: session.id, exitCode: 1, signal: nil)))
        connection.push(.event(.changed(exited)))
        return .answer(.created(session))
    }
    let created = try await control.create(name: "fails at once", cwd: "/tmp")
    #expect(created.isRunning)
    #expect(control.sessions.first { $0.id == created.id }?.isRunning == false)
    #expect(control.currentSession(created.id, hostID: "host-a")?.exitCode == 1)

    // A list whose snapshot was taken before that exit (a stale running
    // entry) never brings the program back either.
    fake.respond = { [weak fake] request, connection in
        guard request.op == "list", let fake else { return nil }
        return .answer(.sessions(HostedSessionList(hostID: fake.hostID, sessions: runningCopies(of: fake.sessions))))
    }
    _ = try await control.list()
    #expect(control.sessions.first { $0.id == created.id }?.isRunning == false)
    #expect(!recorder.events.contains { event in
        if case .changed(let info) = event { return info.id == created.id && info.isRunning }
        return false
    })

    // Kill of an exited session is not needed: a close ends at once.
    fake.respond = nil
    #expect(try await control.waitForSession(created.id, timeout: .milliseconds(50)) { $0?.isRunning == false })
}

@Test @MainActor func HostControlNeverBringsBackASessionRemovedWhileAListWasAnswered() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper(sessions: [hostedSession("s1"), hostedSession("s2")])
    let control = makeFakeHostControl(fake, hostStore: store)
    defer { control.disconnect() }
    _ = try await control.list()
    #expect(control.sessions.map(\.id) == ["s1", "s2"])

    // The list's snapshot still has s1; its removal (and s3's arrival)
    // reach the app first.
    fake.respond = { [weak fake] request, connection in
        guard request.op == "list", let fake else { return nil }
        let snapshot = fake.sessions
        fake.sessions = [hostedSession("s2"), hostedSession("s3")]
        connection.push(.event(.removed(id: "s1")))
        connection.push(.event(.added(hostedSession("s3"))))
        return .answer(.sessions(HostedSessionList(hostID: fake.hostID, sessions: snapshot)))
    }
    _ = try await control.list()
    #expect(control.sessions.map(\.id).sorted() == ["s2", "s3"])

    // A list asked for after those events is the host's word again.
    fake.respond = nil
    fake.sessions = [hostedSession("s2", title: "renamed")]
    _ = try await control.list()
    #expect(control.sessions.map(\.id) == ["s2"])
    #expect(control.sessions.first?.title == "renamed")

    // The app's own Remove: a list answered afterwards with an older
    // snapshot does not bring it back.
    fake.sessions = [hostedSession("s2", state: .exited, exitCode: 0)]
    _ = try await control.list()
    let held = FakeHeldRequest()
    fake.respond = { request, connection in
        request.op == "list" ? held.hold(request, on: connection) : nil
    }
    let staleList = Task { try await control.list() }
    #expect(await fake.wait { held.isHeld })
    fake.respond = nil
    try await control.remove("s2")
    #expect(control.sessions.isEmpty)
    held.answer(.sessions(HostedSessionList(hostID: "host-a", sessions: [hostedSession("s2", state: .exited, exitCode: 0)])))
    _ = try await staleList.value
    #expect(control.sessions.isEmpty)
}

@Test @MainActor func HostControlReportsACreateWhoseRetryFailedAsMaybeCreated() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper()
    let control = makeFakeHostControl(fake, hostStore: store)
    defer { control.disconnect() }
    try await control.connect()

    // The first answer is lost (the host did create it), and the retry is
    // refused because the daemon is shutting down: still "may have happened".
    let first = FakeCountdown(1)
    fake.respond = { [weak fake] request, connection in
        guard request.op == "create", let fake else { return nil }
        if first.take() {
            _ = fake.defaultReply(to: request, on: connection)
            return .exit(stderr: "cherry: connection lost")
        }
        return .answer(.error(code: "request_failed", message: "host is shutting down"))
    }
    let refused = await #expect(throws: HostedSessionError.self) {
        try await control.create(name: "x", cwd: "/tmp")
    }
    #expect(refused == .transport("cherry: connection lost"))

    // The retry reaches another identity: the same.
    first.set(1)
    fake.respond = { [weak fake] request, connection in
        guard request.op == "create", let fake, first.take() else { return nil }
        _ = fake.defaultReply(to: request, on: connection)
        fake.hostID = "host-b"
        return .exit(stderr: "cherry: connection lost")
    }
    let otherHost = await #expect(throws: HostedSessionError.self) {
        try await control.create(name: "y", cwd: "/tmp", expectedHostID: "host-a")
    }
    #expect(otherHost == .transport("cherry: connection lost"))

    // A reply this version cannot read: the same.
    fake.hostID = "host-a"
    first.set(1)
    fake.respond = { [weak fake] request, connection in
        guard request.op == "create", let fake else { return nil }
        if first.take() {
            _ = fake.defaultReply(to: request, on: connection)
            return .exit(stderr: "cherry: connection lost")
        }
        return .answer(.pong)
    }
    let unexpected = await #expect(throws: HostedSessionError.self) {
        try await control.create(name: "z", cwd: "/tmp")
    }
    #expect(unexpected == .transport("cherry: connection lost"))
}

@Test @MainActor func HostControlSaysHowMuchOfALongInputReachedTheProgram() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper(sessions: [hostedSession("s1")])
    let control = makeFakeHostControl(fake, hostStore: store)
    defer { control.disconnect() }
    _ = try await control.list()

    // The third of three parts fails: the first two were typed.
    let input = Data(repeating: 0x61, count: 2 * HostProtocol.maxInputBytes + 10)
    let parts = FakeCountdown(2)
    fake.respond = { request, _ in
        guard request.op == "send_input" else { return nil }
        return parts.take() ? nil : .answer(.error(code: "not_running", message: "session s1 is not running"))
    }
    let partial = await #expect(throws: HostInputPartiallyDelivered.self) {
        try await control.sendInput("s1", input, expectedHostID: "host-a")
    }
    #expect(partial?.deliveredBytes == 2 * HostProtocol.maxInputBytes)
    #expect(partial?.totalBytes == input.count)
    #expect(partial?.failure == .rejected(code: "not_running", message: "session s1 is not running"))
    #expect(partial?.failedPartBytes == 10)
    // The host refused the part that failed: none of it was typed.
    #expect(partial?.unconfirmedBytes == 0)
    #expect(partial?.localizedDescription.contains("Only the first \(2 * HostProtocol.maxInputBytes) of \(input.count) bytes") == true)

    // The first part fails: nothing was typed, and the error says so as before.
    fake.respond = { request, _ in
        request.op == "send_input" ? .answer(.error(code: "not_running", message: "session s1 is not running")) : nil
    }
    let none = await #expect(throws: HostedSessionError.self) {
        try await control.sendInput("s1", input, expectedHostID: "host-a")
    }
    #expect(none == .rejected(code: "not_running", message: "session s1 is not running"))

    // A lost connection after the first part: partial, as a transport failure.
    let delivered = FakeCountdown(1)
    fake.respond = { request, _ in
        guard request.op == "send_input" else { return nil }
        return delivered.take() ? nil : .exit(stderr: "cherry: connection lost")
    }
    let lost = await #expect(throws: HostInputPartiallyDelivered.self) {
        try await control.sendInput("s1", input, expectedHostID: "host-a")
    }
    #expect(lost?.deliveredBytes == HostProtocol.maxInputBytes)
    #expect(lost?.failure.isTransportFailure == true)
    // The second part was sent but its answer was lost: it may have been typed.
    #expect(lost?.failedPartBytes == HostProtocol.maxInputBytes)
    #expect(lost?.unconfirmedBytes == HostProtocol.maxInputBytes)
    #expect(lost?.localizedDescription.contains("may have too") == true)
}

/// The sessions as a snapshot taken while they still ran would show them.
/// Not isolated: the fake calls it on its own thread.
private nonisolated func runningCopies(of sessions: [HostedSessionInfo]) -> [HostedSessionInfo] {
    var copies: [HostedSessionInfo] = []
    for session in sessions {
        copies.append(HostedSessionInfo(
            id: session.id, name: session.name, cwd: session.cwd, command: session.command, pid: session.pid,
            owner: session.owner, tags: session.tags, requestID: session.requestID
        ))
    }
    return copies
}
