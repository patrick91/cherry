import AppKit
import Darwin
import Foundation

private let inputDebugEnabled = ProcessInfo.processInfo.environment["CHERRY_DEBUG_INPUT"] == "1"
private let activityDebugEnabled = ProcessInfo.processInfo.environment["CHERRY_ACTIVITY_DEBUG"] == "1"
private let ptyTraceDirectory = ProcessInfo.processInfo.environment["CHERRY_TRACE_PTY_DIR"]
private let prototypeProcessorDisabledForPerf =
    ProcessInfo.processInfo.environment["CHERRY_DISABLE_PROTOTYPE_PROCESSOR"] == "1"
private let fullPrototypeProcessorEnabled =
    ProcessInfo.processInfo.environment["CHERRY_FULL_PROTOTYPE_PROCESSOR"] == "1"

private final class TerminalTraceRecorder {
    let outputURL: URL

    private let outputHandle: FileHandle

    init?(sessionID: UUID, title: String) {
        guard let ptyTraceDirectory, !ptyTraceDirectory.isEmpty else { return nil }

        let directoryPath = NSString(string: ptyTraceDirectory).expandingTildeInPath
        let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            fputs("[pty trace] failed to create \(directoryURL.path): \(error.localizedDescription)\n", stderr)
            return nil
        }

        let filename = "\(Self.timestamp())-\(Self.safeFilename(title))-\(sessionID.uuidString.prefix(8)).pty"
        outputURL = directoryURL.appendingPathComponent(filename)

        FileManager.default.createFile(atPath: outputURL.path, contents: Data())

        do {
            outputHandle = try FileHandle(forWritingTo: outputURL)
        } catch {
            fputs("[pty trace] failed to open \(outputURL.path): \(error.localizedDescription)\n", stderr)
            return nil
        }

        fputs("[pty trace] writing raw PTY output to \(outputURL.path)\n", stderr)
    }

    deinit {
        try? outputHandle.close()
    }

    func recordOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        try? outputHandle.write(contentsOf: data)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let sanitized = value.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return sanitized.isEmpty ? "session" : sanitized
    }
}

final class TerminalProcessor: @unchecked Sendable {
    private static let changeNotificationInterval: TimeInterval = 1.0 / 30.0

    private let processingQueue = DispatchQueue(label: "Cherry.TerminalProcessor", qos: .userInitiated)
    private let lock = NSLock()
    private let notificationLock = NSLock()

    private var buffer: any TerminalBuffering
    private var viewportSize = TerminalViewportSize(columns: 120, rows: 32)
    private var activeLaunchID: UUID?
    private var outputEpoch = 0
    private var isChangeNotificationScheduled = false
    private var onDidChange: (@Sendable () -> Void)?

    init(maxScrollback: Int?, buffer: (any TerminalBuffering)? = nil) {
        self.buffer = buffer ?? PrototypeTerminalBuffer(maxScrollback: maxScrollback)
    }

    var lineCount: Int {
        locked { buffer.lineCount }
    }

    var storedLineCount: Int {
        locked { buffer.storedLineCount }
    }

    var cursorState: TerminalCursorState {
        locked { buffer.cursorState }
    }

    var usesAlternateScreen: Bool {
        locked { buffer.usesAlternateScreen }
    }

    var usesApplicationCursorKeys: Bool {
        locked { buffer.usesApplicationCursorKeys }
    }

    var usesBracketedPasteMode: Bool {
        locked { buffer.usesBracketedPasteMode }
    }

    var mouseState: TerminalMouseState {
        locked { buffer.mouseState }
    }

    func setChangeHandler(_ handler: (@Sendable () -> Void)?) {
        notificationLock.withLock {
            onDidChange = handler
        }
    }

    func beginLaunch(_ launchID: UUID) {
        locked {
            activeLaunchID = launchID
        }
    }

    func endLaunch(_ launchID: UUID?) {
        locked {
            guard launchID == nil || activeLaunchID == launchID else { return }
            activeLaunchID = nil
        }
    }

    func snapshot(range: Range<Int>) -> [String] {
        locked { buffer.snapshot(range: range) }
    }

    func styledSnapshot(range: Range<Int>) -> [TerminalRenderedLine] {
        locked { buffer.styledSnapshot(range: range) }
    }

    func lineLength(at row: Int) -> Int {
        locked { buffer.lineLength(at: row) }
    }

    func gridPoint(row: Int, column: Int) -> TerminalGridPoint {
        locked { buffer.gridPoint(row: row, column: column) }
    }

    func selectedText(in selection: TerminalSelectionRange) -> String {
        locked { buffer.selectedText(in: selection) }
    }

    func clear() {
        locked {
            buffer.clear()
        }
        scheduleChangeNotification(after: 0)
    }

    func clearScreenAndScrollbackPreservingTerminalState() {
        locked {
            buffer.clearScreenAndScrollbackPreservingState()
        }
        scheduleChangeNotification(after: 0)
    }

    func resize(to viewportSize: TerminalViewportSize) {
        locked {
            self.viewportSize = viewportSize
            buffer.resize(to: viewportSize)
        }
        scheduleChangeNotification()
    }

    func appendPlainLines(_ lines: [String]) {
        locked {
            buffer.appendPlainLines(lines)
        }
        scheduleChangeNotification(after: 0)
    }

    func ingestTestingData(_ data: Data) {
        processOutput(data, launchID: nil, responseWriter: { _ in })
    }

    func discardPendingOutput() {
        locked {
            outputEpoch &+= 1
        }
    }

    func enqueueOutput(
        _ data: Data,
        launchID: UUID?,
        responseWriter: @escaping @Sendable (Data) -> Void
    ) {
        guard !data.isEmpty else { return }

        let epoch = locked { outputEpoch }
        processingQueue.async { [self] in
            processOutput(data, launchID: launchID, expectedEpoch: epoch, responseWriter: responseWriter)
        }
    }

    func processOutput(
        _ data: Data,
        launchID: UUID?,
        responseWriter: (Data) -> Void
    ) {
        processOutput(data, launchID: launchID, expectedEpoch: nil, responseWriter: responseWriter)
    }

    private func processOutput(
        _ data: Data,
        launchID: UUID?,
        expectedEpoch: Int?,
        responseWriter: (Data) -> Void
    ) {
        guard !data.isEmpty else { return }

        let responses: [Data] = locked {
            if let expectedEpoch, outputEpoch != expectedEpoch {
                return []
            }
            if let launchID, activeLaunchID != launchID {
                return []
            }
            return buffer.ingest(data, viewportSize: viewportSize)
        }

        for response in responses {
            responseWriter(response)
        }

        scheduleChangeNotification()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.withLock(body)
    }

    private func scheduleChangeNotification(after delay: TimeInterval = TerminalProcessor.changeNotificationInterval) {
        let handler: (@Sendable () -> Void)? = notificationLock.withLock {
            guard !isChangeNotificationScheduled else { return nil }
            isChangeNotificationScheduled = true
            return onDidChange
        }
        guard let handler else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.notificationLock.withLock {
                self.isChangeNotificationScheduled = false
            }
            handler()
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

final class TerminalInputWriter: @unchecked Sendable {
    typealias WriteHandler = @Sendable (Data) -> Void
    typealias InputHandler = @MainActor @Sendable (Data) -> Void

    private let lock = NSLock()
    private weak var process: ShellProcessController?
    private let fallbackWriteHandler: WriteHandler?
    private var keyboardProtocolFlags = 0
    private var inputHandler: InputHandler?
    private var isInputHandlerScheduled = false
    private var pendingInputHandlerData = Data()

    init(writeHandler: WriteHandler? = nil) {
        self.fallbackWriteHandler = writeHandler
    }

    func set(_ process: ShellProcessController?) {
        lock.withLock {
            self.process = process
        }
    }

    func setKeyboardProtocolFlags(_ flags: Int) {
        lock.withLock {
            keyboardProtocolFlags = flags
        }
    }

    func setInputHandler(_ handler: InputHandler?) {
        lock.withLock {
            inputHandler = handler
        }
    }

    func write(_ data: Data, normalize: Bool = true, notifyInput: Bool = true) {
        let snapshot = lock.withLock {
            let writer: WriteHandler? = if let process {
                { process.write($0) }
            } else {
                fallbackWriteHandler
            }
            return (
                writer: writer,
                keyboardProtocolFlags: keyboardProtocolFlags,
                inputHandler: inputHandler
            )
        }

        guard let writer = snapshot.writer else { return }
        let outboundData = normalize
            ? TerminalInputNormalizer.normalize(
                data,
                keyboardProtocolFlags: snapshot.keyboardProtocolFlags
            )
            : data
        guard !outboundData.isEmpty else { return }

        writer(outboundData)
        if notifyInput {
            scheduleInputHandler(snapshot.inputHandler, data: outboundData)
        }
    }

    private func scheduleInputHandler(_ handler: InputHandler?, data: Data) {
        guard let handler else { return }

        let shouldSchedule = lock.withLock {
            pendingInputHandlerData.append(data)
            guard !isInputHandlerScheduled else { return false }
            isInputHandlerScheduled = true
            return true
        }
        guard shouldSchedule else { return }

        Task { @MainActor [weak self] in
            while let data = self?.takePendingInputHandlerDataOrFinish() {
                handler(data)
            }
        }
    }

    private func takePendingInputHandlerDataOrFinish() -> Data? {
        lock.withLock {
            guard !pendingInputHandlerData.isEmpty else {
                isInputHandlerScheduled = false
                return nil
            }
            let data = pendingInputHandlerData
            pendingInputHandlerData.removeAll(keepingCapacity: true)
            return data
        }
    }
}

private struct SummaryTranscript {
    let text: String
    let inputLineCount: Int
    let filteredLineCount: Int

    static let empty = SummaryTranscript(text: "", inputLineCount: 0, filteredLineCount: 0)
}

private final class TerminalRawOutputStore: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private let trimThresholdBytes: Int
    private var chunks: [Data] = []
    private var byteCount = 0
    private var observers: [UUID: @Sendable (Data) -> Void] = [:]

    init(maximumBytes: Int = 1_048_576) {
        self.maximumBytes = maximumBytes
        self.trimThresholdBytes = maximumBytes + max(maximumBytes / 4, 64 * 1024)
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }

        let currentObservers: [@Sendable (Data) -> Void] = lock.withLock {
            appendLocked(chunk)
            return Array(observers.values)
        }

        for observer in currentObservers {
            observer(chunk)
        }
    }

    func observe(replayExistingOutput: Bool, _ observer: @escaping @Sendable (Data) -> Void) -> UUID {
        let id = UUID()
        lock.withLock {
            if replayExistingOutput, byteCount > 0 {
                observer(snapshotLocked(maxBytes: maximumBytes).data)
            }
            observers[id] = observer
        }
        return id
    }

    func removeObserver(id: UUID) {
        _ = lock.withLock {
            observers.removeValue(forKey: id)
        }
    }

    var observerCount: Int {
        lock.withLock {
            observers.count
        }
    }

    func snapshot(maxBytes requestedMaxBytes: Int) -> (data: Data, truncated: Bool) {
        lock.withLock {
            let maxBytes = max(0, min(requestedMaxBytes, maximumBytes))
            return snapshotLocked(maxBytes: maxBytes)
        }
    }

    func clear() {
        lock.withLock {
            chunks.removeAll(keepingCapacity: false)
            byteCount = 0
        }
    }

    private func appendLocked(_ chunk: Data) {
        var retainedChunk = Data()
        if chunk.count > maximumBytes {
            retainedChunk.reserveCapacity(maximumBytes)
            retainedChunk.append(chunk.suffix(maximumBytes))
        } else {
            retainedChunk.reserveCapacity(chunk.count)
            retainedChunk.append(chunk)
        }
        chunks.append(retainedChunk)
        byteCount += retainedChunk.count

        guard byteCount > trimThresholdBytes else { return }
        trimLocked(to: maximumBytes)
    }

    private func trimLocked(to targetBytes: Int) {
        var excessBytes = max(0, byteCount - targetBytes)

        var removeCount = 0
        while excessBytes > 0, removeCount < chunks.count {
            let first = chunks[removeCount]
            if first.count <= excessBytes {
                byteCount -= first.count
                excessBytes -= first.count
                removeCount += 1
            } else {
                break
            }
        }

        if removeCount > 0 {
            chunks.removeFirst(removeCount)
        }

        if excessBytes > 0, let first = chunks.first {
            chunks[0] = Data(first.dropFirst(excessBytes))
            byteCount -= excessBytes
        }

        if chunks.isEmpty {
            byteCount = 0
        }
    }

    private func snapshotLocked(maxBytes: Int) -> (data: Data, truncated: Bool) {
        guard maxBytes > 0, byteCount > 0 else {
            return (Data(), byteCount > 0)
        }

        let outputByteCount = min(maxBytes, byteCount)
        var remainingBytes = outputByteCount
        var slices: [Data.SubSequence] = []

        for chunk in chunks.reversed() {
            guard remainingBytes > 0 else { break }
            if chunk.count <= remainingBytes {
                slices.append(chunk[chunk.startIndex..<chunk.endIndex])
                remainingBytes -= chunk.count
            } else {
                slices.append(chunk.suffix(remainingBytes))
                remainingBytes = 0
            }
        }

        var output = Data()
        output.reserveCapacity(outputByteCount)
        for slice in slices.reversed() {
            output.append(slice)
        }
        return (output, byteCount > maxBytes)
    }
}

private enum TerminalMetadataEvent: Equatable {
    case title(String)
    case workingDirectory(String)
    case notification(TerminalNotificationRequest)
    case nixShell(NixShellMetadataEvent)
    case keyboardProtocolPush(Int)
    case keyboardProtocolPop(Int)
    case keyboardProtocolSet(flags: Int, mode: Int)
}

private enum NixShellMetadataEvent: Equatable {
    case enter(NixShellEnvironment)
    case exit
}

struct TerminalNotificationRequest: Equatable {
    enum Source: Equatable {
        case bel
        case osc9
        case osc777
    }

    let title: String?
    let body: String
    let source: Source
}

private final class TerminalMetadataParser {
    private enum ParserState {
        case ground
        case afterEscape
        case csi
        case osc
        case oscAfterEscape
    }

    private static let maximumOSCBytes = 8_192
    private static let maximumCSIBytes = 256

    private var state = ParserState.ground
    private var controlBuffer = [UInt8]()

    func parse(_ data: Data) -> [TerminalMetadataEvent] {
        if isGround, !Self.containsEscape(in: data) {
            return []
        }

        var events: [TerminalMetadataEvent] = []

        for byte in data {
            switch state {
            case .ground:
                if byte == 0x1B {
                    state = .afterEscape
                }

            case .afterEscape:
                if byte == UInt8(ascii: "]") {
                    controlBuffer.removeAll(keepingCapacity: true)
                    state = .osc
                } else if byte == UInt8(ascii: "[") {
                    controlBuffer.removeAll(keepingCapacity: true)
                    state = .csi
                } else {
                    state = byte == 0x1B ? .afterEscape : .ground
                }

            case .csi:
                if (0x40...0x7E).contains(byte) {
                    finishCSI(finalByte: byte, events: &events)
                } else {
                    appendCSIByte(byte)
                }

            case .osc:
                if byte == 0x07 {
                    finishOSC(events: &events)
                } else if byte == 0x1B {
                    state = .oscAfterEscape
                } else {
                    appendOSCByte(byte)
                }

            case .oscAfterEscape:
                if byte == UInt8(ascii: "\\") {
                    finishOSC(events: &events)
                } else {
                    appendOSCByte(0x1B)
                    appendOSCByte(byte)
                    state = .osc
                }
            }
        }

        return events
    }

    private static func containsEscape(in data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress, rawBuffer.count > 0 else {
                return false
            }
            return memchr(baseAddress, 0x1B, rawBuffer.count) != nil
        }
    }

    private var isGround: Bool {
        if case .ground = state {
            return true
        }
        return false
    }

    private func appendOSCByte(_ byte: UInt8) {
        guard controlBuffer.count < Self.maximumOSCBytes else { return }
        controlBuffer.append(byte)
    }

    private func appendCSIByte(_ byte: UInt8) {
        guard controlBuffer.count < Self.maximumCSIBytes else { return }
        controlBuffer.append(byte)
    }

    private func finishCSI(finalByte: UInt8, events: inout [TerminalMetadataEvent]) {
        let rawPayload = String(decoding: controlBuffer, as: UTF8.self)
        if let event = Self.keyboardProtocolEvent(from: rawPayload, finalByte: finalByte) {
            events.append(event)
        }

        controlBuffer.removeAll(keepingCapacity: true)
        state = .ground
    }

    private func finishOSC(events: inout [TerminalMetadataEvent]) {
        let rawPayload = String(decoding: controlBuffer, as: UTF8.self)
        if let event = Self.metadataEvent(from: rawPayload) {
            events.append(event)
        }

        controlBuffer.removeAll(keepingCapacity: true)
        state = .ground
    }

    private static func metadataEvent(from rawPayload: String) -> TerminalMetadataEvent? {
        let parts = rawPayload.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        let code = String(parts[0])
        let value = sanitized(String(parts[1]))
        guard !value.isEmpty else { return nil }

        switch code {
        case "0", "1", "2":
            return .title(value)
        case "7":
            return workingDirectoryEvent(from: value)
        case "9":
            return .notification(TerminalNotificationRequest(
                title: nil,
                body: value,
                source: .osc9
            ))
        case "777":
            if let event = cherryNixShellEvent(from: value) {
                return event
            }
            return osc777NotificationEvent(from: value)
        default:
            return nil
        }
    }

    private static func cherryNixShellEvent(from value: String) -> TerminalMetadataEvent? {
        let prefix = "cherry-nix;"
        guard value.hasPrefix(prefix) else { return nil }

        let payload = value.dropFirst(prefix.count)
        if payload == "exit" || payload.hasPrefix("exit;") {
            return .nixShell(.exit)
        }

        let enterPrefix = "enter;"
        guard payload.hasPrefix(enterPrefix) else { return nil }
        let command = String(payload.dropFirst(enterPrefix.count))
        guard let environment = NixShellCommandParser.environment(from: command) else { return nil }
        return .nixShell(.enter(environment))
    }

    private static func osc777NotificationEvent(from value: String) -> TerminalMetadataEvent? {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == "notify" else { return nil }

        let title = sanitized(parts[1]).nilIfEmpty
        let body = sanitized(parts.dropFirst(2).joined(separator: ";"))
        guard !body.isEmpty else { return nil }

        return .notification(TerminalNotificationRequest(
            title: title,
            body: body,
            source: .osc777
        ))
    }

    private static func workingDirectoryEvent(from value: String) -> TerminalMetadataEvent? {
        // Follow Ghostty's OSC 7 model: accept file:// and kitty-shell-cwd://
        // cwd reports only when their host resolves to this machine.
        if value.hasPrefix("kitty-shell-cwd://") {
            return kittyShellWorkingDirectoryEvent(from: value)
        }

        if value.hasPrefix("file://"),
           let url = URL(string: value),
           url.isFileURL,
           let host = url.host(percentEncoded: false),
           isLocalHost(host) {
            let path = url.path.removingPercentEncoding ?? url.path
            return path.isEmpty ? nil : .workingDirectory(path)
        }

        return nil
    }

    private static func kittyShellWorkingDirectoryEvent(from value: String) -> TerminalMetadataEvent? {
        let prefix = "kitty-shell-cwd://"
        let remainder = value.dropFirst(prefix.count)
        guard let pathStart = remainder.firstIndex(of: "/") else { return nil }

        let host = String(remainder[..<pathStart])
        let path = String(remainder[pathStart...])
        guard isLocalHost(host), !path.isEmpty else { return nil }

        return .workingDirectory(path)
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        guard !normalizedHost.isEmpty else { return false }

        if normalizedHost == "localhost"
            || normalizedHost == "127.0.0.1"
            || normalizedHost == "::1" {
            return true
        }

        return localHostnames().contains(normalizedHost)
    }

    private static func localHostnames() -> Set<String> {
        cachedLocalHostnames
    }

    private static let cachedLocalHostnames: Set<String> = {
        var names = Set<String>()

        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if gethostname(&buffer, buffer.count) == 0 {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let hostname = String(decoding: bytes, as: UTF8.self).lowercased()
            if !hostname.isEmpty {
                names.insert(hostname)
                if let shortName = hostname.split(separator: ".").first {
                    names.insert(String(shortName))
                }
            }
        }

        if let localizedName = Host.current().localizedName?.lowercased(), !localizedName.isEmpty {
            names.insert(localizedName)
            if let shortName = localizedName.split(separator: ".").first {
                names.insert(String(shortName))
            }
        }

        return names
    }()

    private static func keyboardProtocolEvent(from rawPayload: String, finalByte: UInt8) -> TerminalMetadataEvent? {
        guard finalByte == UInt8(ascii: "u"), let prefix = rawPayload.first else { return nil }

        switch prefix {
        case ">":
            return .keyboardProtocolPush(keyboardProtocolParameters(from: rawPayload).first ?? 0)
        case "<":
            let count = keyboardProtocolParameters(from: rawPayload).first ?? 1
            return .keyboardProtocolPop(max(1, count))
        case "=":
            let parameters = keyboardProtocolParameters(from: rawPayload)
            return .keyboardProtocolSet(flags: parameters.first ?? 0, mode: parameters.dropFirst().first ?? 1)
        default:
            return nil
        }
    }

    private static func keyboardProtocolParameters(from rawPayload: String) -> [Int] {
        rawPayload
            .dropFirst()
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0.filter(\.isNumber)) ?? 0 }
    }

    private static func sanitized(_ value: String) -> String {
        value
            .filter { !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TerminalInputNormalizer {
    private static let reportAllKeysAsEscapeCodesFlag = 0b1000

    static func normalize(_ data: Data, keyboardProtocolFlags: Int) -> Data {
        guard keyboardProtocolFlags & reportAllKeysAsEscapeCodesFlag != 0,
              data == Data([0x09])
        else {
            return data
        }

        return Data("\u{1B}[9u".utf8)
    }
}

struct AgentSessionTreeItem: Identifiable {
    let session: TerminalSession
    let depth: Int

    var id: UUID { session.id }
}

@MainActor
final class TerminalWorkspace: ObservableObject {
    @Published private(set) var sessions: [TerminalSession]
    @Published var selectedSessionID: UUID? {
        didSet {
            clearUnreadNotificationForSelectedSession()
        }
    }
    let projectRoot: String?

    init(projectRoot: String? = nil) {
        self.projectRoot = projectRoot.map(Self.resolvedWorkingDirectory)
        let firstSession = Self.makeSession(index: 1, workingDirectory: self.projectRoot, projectRoot: self.projectRoot)
        sessions = [firstSession]
        selectedSessionID = firstSession.id
    }

    var selectedSession: TerminalSession? {
        guard let selectedSessionID else { return sessions.first }
        return sessions.first(where: { $0.id == selectedSessionID }) ?? sessions.first
    }

    var agentSessions: [TerminalSession] {
        sessions.filter { $0.kind == .agent }
    }

    var runningAgentSessions: [TerminalSession] {
        agentSessions.filter(\.isRunning)
    }

    var rootAgentSessions: [TerminalSession] {
        agentSessions.filter { session in
            guard let parentAgentID = session.parentAgentID else { return true }
            return !agentSessions.contains { $0.id == parentAgentID }
        }
    }

    var terminalSessions: [TerminalSession] {
        sessions.filter { $0.kind == .terminal }
    }

    var commandSessions: [TerminalSession] {
        sessions.filter { $0.kind == .command }
    }

    var sidebarOrderedSessions: [TerminalSession] {
        visibleAgentSessions() + terminalSessions + commandSessions
    }

    func sidebarOrderedSessions(visibleCommandNames: [String]) -> [TerminalSession] {
        visibleAgentSessions() + terminalSessions + commandSessions(orderedBy: visibleCommandNames)
    }

    func childAgentSessions(of parent: TerminalSession) -> [TerminalSession] {
        childAgentSessions(parentID: parent.id)
    }

    func childAgentCount(of parent: TerminalSession) -> Int {
        childAgentSessions(of: parent).count
    }

    func descendantAgentSessions(of parent: TerminalSession) -> [TerminalSession] {
        guard parent.kind == .agent else { return [] }
        return childAgentSessions(of: parent)
    }

    func visibleAgentTreeItems(collapsedIDs: Set<UUID> = []) -> [AgentSessionTreeItem] {
        var items: [AgentSessionTreeItem] = []
        for session in rootAgentSessions {
            appendAgentTreeItems(parent: session, depth: 0, collapsedIDs: collapsedIDs, to: &items)
        }
        return items
    }

    func visibleAgentSessions(collapsedIDs: Set<UUID> = []) -> [TerminalSession] {
        visibleAgentTreeItems(collapsedIDs: collapsedIDs).map(\.session)
    }

    func select(_ session: TerminalSession) {
        selectedSessionID = session.id
    }

    func moveSession(id sessionID: UUID, to targetIndex: Int) {
        guard let currentIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return }

        let clampedIndex = min(max(targetIndex, 0), sessions.count - 1)
        guard currentIndex != clampedIndex else { return }

        let session = sessions.remove(at: currentIndex)
        sessions.insert(session, at: clampedIndex)
    }

    func moveSession(id sessionID: UUID, to targetIndex: Int, within kind: TerminalSession.SessionKind) {
        let scopedSessions = sessions.filter { $0.kind == kind }
        guard let currentScopedIndex = scopedSessions.firstIndex(where: { $0.id == sessionID }) else { return }

        let clampedScopedIndex = min(max(targetIndex, 0), scopedSessions.count - 1)
        guard currentScopedIndex != clampedScopedIndex else { return }

        let session = scopedSessions[currentScopedIndex]
        let remainingScopedIDs = scopedSessions
            .filter { $0.id != sessionID }
            .map(\.id)
        var nextScopedIDs = remainingScopedIDs
        nextScopedIDs.insert(session.id, at: min(clampedScopedIndex, nextScopedIDs.count))

        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var scopedIterator = nextScopedIDs.makeIterator()
        sessions = sessions.map { existing in
            guard existing.kind == kind, let nextID = scopedIterator.next(),
                  let replacement = sessionsByID[nextID]
            else {
                return existing
            }
            return replacement
        }
    }

    @discardableResult
    func addSession(
        title: String? = nil,
        workingDirectory: String? = nil,
        command: String? = nil,
        select: Bool = true
    ) -> TerminalSession {
        // Match Ghostty's new-surface behavior: when no cwd is requested,
        // inherit the selected session's last trusted OSC 7 cwd report.
        let resolvedWorkingDirectory = workingDirectory ?? selectedSession?.workingDirectory
        let session = Self.makeSession(
            index: sessions.count + 1,
            title: title,
            workingDirectory: resolvedWorkingDirectory,
            projectRoot: projectRoot
        )
        sessions.append(session)
        if select {
            selectedSessionID = session.id
        }

        if let command, !command.isEmpty {
            session.send(text: command + "\n")
        }

        return session
    }

    @discardableResult
    func addAgentSession(
        agent: AgentToolDefinition,
        projectRoot: String,
        title: String? = nil,
        parentAgentID: UUID? = nil,
        select: Bool = true
    ) -> TerminalSession {
        let normalizedParentAgentID = normalizedParentAgentID(parentAgentID)
        let session = Self.makeAgentSession(
            index: agentSessions.count + 1,
            agent: agent,
            workingDirectory: projectRoot,
            title: title,
            parentAgentID: normalizedParentAgentID
        )
        sessions.append(session)
        if select {
            selectedSessionID = session.id
        }
        return session
    }

    @discardableResult
    func addCommandSession(
        command: ProjectCommandDefinition,
        projectRoot: String,
        select: Bool = true
    ) -> TerminalSession {
        if let session = commandSession(named: command.name) {
            if select {
                selectedSessionID = session.id
            }
            return session
        }

        let session = Self.makeCommandSession(
            index: commandSessions.count + 1,
            command: command,
            workingDirectory: command.resolvedWorkingDirectory(projectRoot: projectRoot),
            projectRoot: projectRoot
        )
        sessions.append(session)
        if select {
            selectedSessionID = session.id
        }
        return session
    }

    @discardableResult
    func installPreviewAgentTree() -> [TerminalSession] {
        guard agentSessions.isEmpty else { return [] }

        let workingDirectory = projectRoot ?? NSHomeDirectory()
        var previewSessions: [TerminalSession] = []

        func appendPreviewAgent(
            title: String,
            subtitle: String,
            agentName: String,
            parentAgentID: UUID? = nil
        ) -> TerminalSession {
            let session = Self.makePreviewAgentSession(
                index: previewSessions.count + 1,
                title: title,
                subtitle: subtitle,
                agentName: agentName,
                workingDirectory: workingDirectory,
                projectRoot: projectRoot,
                parentAgentID: parentAgentID
            )
            previewSessions.append(session)
            return session
        }

        let parent = appendPreviewAgent(
            title: "Claude",
            subtitle: "Investigate Profile Cache Loading",
            agentName: "Claude"
        )
        [
            ("Codex", "tuning sidebar UI", "Codex"),
            ("Gemini", "no agent process running", "Gemini"),
            ("Amp", "previewed empty agent tree", "Amp"),
            ("Codex Review", "check close confirmation", "Codex"),
            ("Claude Notes", "inspect sidebar spacing", "Claude"),
            ("Gemini Audit", "", "Gemini"),
            ("Amp Layout", "", "Amp"),
            ("Codex MCP", "validate parent_agent_id", "Codex"),
            ("Claude Cache", "read cached profile data", "Claude"),
            ("Gemini Trace", "measure row rhythm", "Gemini"),
            ("Amp Snapshot", "compare guide alignment", "Amp"),
            ("Codex Docs", "", "Codex")
        ].forEach { title, subtitle, agentName in
            _ = appendPreviewAgent(
                title: title,
                subtitle: subtitle,
                agentName: agentName,
                parentAgentID: parent.id
            )
        }

        let designParent = appendPreviewAgent(
            title: "Codex Design",
            subtitle: "agent tree preview visible",
            agentName: "Codex"
        )
        [
            ("Claude Close", "group close prompt", "Claude"),
            ("Gemini Commands", "shortcut numbering", "Gemini"),
            ("Amp Icons", "mixed provider logos", "Amp"),
            ("Codex Empty", "", "Codex"),
            ("Claude Labels", "longer sidebar details", "Claude")
        ].forEach { title, subtitle, agentName in
            _ = appendPreviewAgent(
                title: title,
                subtitle: subtitle,
                agentName: agentName,
                parentAgentID: designParent.id
            )
        }

        _ = appendPreviewAgent(
            title: "Claude Scratch",
            subtitle: "",
            agentName: "Claude"
        )
        sessions.append(contentsOf: previewSessions)
        selectedSessionID = parent.id
        return previewSessions
    }

    func commandSession(named name: String) -> TerminalSession? {
        let normalizedName = AgentToolDefinition.normalizedName(name)
        return commandSessions.first {
            $0.commandName.map { AgentToolDefinition.normalizedName($0) } == normalizedName
        }
    }

    func updateCommandSession(
        named originalName: String?,
        with command: ProjectCommandDefinition,
        projectRoot: String
    ) {
        let lookupName = originalName?.nilIfEmpty ?? command.name
        guard let session = commandSession(named: lookupName) else { return }
        session.updateManagedCommand(
            command,
            workingDirectory: command.resolvedWorkingDirectory(projectRoot: projectRoot)
        )
    }

    func close(_ session: TerminalSession) {
        if session.kind == .agent {
            promoteChildAgents(of: session)
        }
        closeSessions(withIDs: Set([session.id]))
    }

    func closeAgentGroup(_ session: TerminalSession) {
        let groupIDs = Set(([session] + descendantAgentSessions(of: session)).map(\.id))
        closeSessions(withIDs: groupIDs)
    }

    func closeAgentPromotingChildren(_ session: TerminalSession) {
        promoteChildAgents(of: session)
        closeSessions(withIDs: Set([session.id]))
    }

    func closeAllSessions() {
        let removedSessions = sessions
        sessions.removeAll()
        selectedSessionID = nil
        removedSessions.forEach { session in
            session.releaseGhosttyBridge()
            session.stop()
        }
    }

    func closeSelectedSession() {
        guard let selectedSession else { return }
        close(selectedSession)
    }

    func selectPreviousSession(visibleCommandNames: [String]? = nil) {
        selectSession(offset: -1, visibleCommandNames: visibleCommandNames)
    }

    func selectNextSession(visibleCommandNames: [String]? = nil) {
        selectSession(offset: 1, visibleCommandNames: visibleCommandNames)
    }


    func restartSelectedSession() {
        selectedSession?.restart()
    }

    func clearSelectedSessionScrollback() {
        selectedSession?.clearScrollback()
    }

    private func selectSession(offset: Int, visibleCommandNames: [String]?) {
        let orderedSessions = if let visibleCommandNames {
            sidebarOrderedSessions(visibleCommandNames: visibleCommandNames)
        } else {
            sidebarOrderedSessions
        }
        guard !orderedSessions.isEmpty else { return }

        let currentIndex = selectedSession
            .flatMap { selectedSession in
                orderedSessions.firstIndex(where: { $0.id == selectedSession.id })
            } ?? 0
        let nextIndex = (currentIndex + offset + orderedSessions.count) % orderedSessions.count
        selectedSessionID = orderedSessions[nextIndex].id
    }

    func clearUnreadNotificationForSelectedSession() {
        guard let selectedSessionID,
              let session = sessions.first(where: { $0.id == selectedSessionID })
        else {
            return
        }
        session.clearUnreadNotification()
    }

    private func commandSessions(orderedBy visibleCommandNames: [String]) -> [TerminalSession] {
        let visibleNames = visibleCommandNames.map(AgentToolDefinition.normalizedName)
        return visibleNames.compactMap { visibleName in
            commandSessions.first {
                $0.commandName.map { AgentToolDefinition.normalizedName($0) } == visibleName
            }
        }
    }

    func session(id terminalID: String) -> TerminalSession? {
        guard let uuid = UUID(uuidString: terminalID) else { return nil }
        return sessions.first(where: { $0.id == uuid })
    }

    private func childAgentSessions(parentID: UUID) -> [TerminalSession] {
        agentSessions.filter { $0.parentAgentID == parentID }
    }

    private func appendAgentTreeItems(
        parent: TerminalSession,
        depth: Int,
        collapsedIDs: Set<UUID>,
        to items: inout [AgentSessionTreeItem]
    ) {
        items.append(AgentSessionTreeItem(session: parent, depth: depth))
        guard !collapsedIDs.contains(parent.id) else { return }
        for child in childAgentSessions(parentID: parent.id) {
            items.append(AgentSessionTreeItem(session: child, depth: 1))
        }
    }

    private func normalizedParentAgentID(_ parentAgentID: UUID?) -> UUID? {
        guard let parentAgentID,
              let parent = agentSessions.first(where: { $0.id == parentAgentID })
        else {
            return parentAgentID
        }

        return rootAgentID(for: parent)
    }

    private func rootAgentID(for session: TerminalSession) -> UUID {
        var current = session
        var visitedIDs: Set<UUID> = [session.id]
        while let parentID = current.parentAgentID,
              !visitedIDs.contains(parentID),
              let parent = agentSessions.first(where: { $0.id == parentID }) {
            visitedIDs.insert(parentID)
            current = parent
        }
        return current.id
    }

    private func promoteChildAgents(of parent: TerminalSession) {
        for child in childAgentSessions(of: parent) {
            child.setParentAgentID(nil)
        }
    }

    private func closeSessions(withIDs removedIDs: Set<UUID>) {
        guard !removedIDs.isEmpty, sessions.count > removedIDs.count else { return }

        let removedIndex = sessions.firstIndex { removedIDs.contains($0.id) }
        let removedSessions = sessions.filter { removedIDs.contains($0.id) }
        sessions.removeAll { removedIDs.contains($0.id) }
        removedSessions.forEach { session in
            session.releaseGhosttyBridge()
            session.stop()
        }

        guard let currentSelectedSessionID = selectedSessionID,
              removedIDs.contains(currentSelectedSessionID)
        else { return }

        if let removedIndex, sessions.indices.contains(removedIndex) {
            selectedSessionID = sessions[removedIndex].id
        } else {
            selectedSessionID = sessions.last?.id
        }
    }

    private static func makeSession(
        index: Int,
        title: String? = nil,
        workingDirectory: String? = nil,
        projectRoot: String? = nil
    ) -> TerminalSession {
        let explicitTitle = title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        return TerminalSession(
            title: explicitTitle ?? "Shell \(index)",
            titleSource: explicitTitle == nil ? .system : .explicit,
            subtitle: "\(ShellProcessController.defaultShellName) login shell",
            tint: palette[(index - 1) % palette.count],
            workingDirectory: Self.resolvedWorkingDirectory(workingDirectory),
            projectRoot: projectRoot
        )
    }

    private static func makeAgentSession(
        index: Int,
        agent: AgentToolDefinition,
        workingDirectory: String,
        title requestedTitle: String?,
        parentAgentID: UUID?
    ) -> TerminalSession {
        let baseTitle = agent.name.isEmpty ? "Agent" : agent.name
        let explicitTitle = requestedTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        return TerminalSession(
            title: explicitTitle ?? baseTitle,
            titleSource: explicitTitle == nil ? .system : .explicit,
            subtitle: agent.commandLine,
            tint: palette[(index - 1) % palette.count],
            workingDirectory: Self.resolvedWorkingDirectory(workingDirectory),
            projectRoot: workingDirectory,
            kind: .agent,
            agentName: agent.name,
            parentAgentID: parentAgentID,
            launchCommand: agent.commandLine
        )
    }

    private static func makeCommandSession(
        index: Int,
        command: ProjectCommandDefinition,
        workingDirectory: String,
        projectRoot: String
    ) -> TerminalSession {
        TerminalSession(
            title: command.name.isEmpty ? "Command \(index)" : command.name,
            subtitle: command.commandLine,
            tint: palette[(index - 1) % palette.count],
            workingDirectory: Self.resolvedWorkingDirectory(workingDirectory),
            projectRoot: projectRoot,
            kind: .command,
            commandName: command.name,
            launchCommand: command.commandLine,
            launchEnvironment: command.environment,
            restartOnExit: command.autoRestart
        )
    }

    private static func makePreviewAgentSession(
        index: Int,
        title: String,
        subtitle: String,
        agentName: String,
        workingDirectory: String,
        projectRoot: String?,
        parentAgentID: UUID? = nil
    ) -> TerminalSession {
        let session = TerminalSession(
            title: title,
            subtitle: subtitle,
            tint: palette[(index - 1) % palette.count],
            workingDirectory: Self.resolvedWorkingDirectory(workingDirectory),
            projectRoot: projectRoot,
            launchShell: false,
            kind: .agent,
            agentName: agentName,
            parentAgentID: parentAgentID
        )
        return session
    }

    private static func resolvedWorkingDirectory(_ requestedWorkingDirectory: String?) -> String {
        guard let requestedWorkingDirectory, !requestedWorkingDirectory.isEmpty else {
            return NSHomeDirectory()
        }

        let expandedPath = NSString(string: requestedWorkingDirectory).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return NSHomeDirectory()
        }

        return expandedPath
    }

    private static let palette: [NSColor] = [
        NSColor(calibratedRed: 0.52, green: 0.89, blue: 0.60, alpha: 1),
        NSColor(calibratedRed: 0.99, green: 0.72, blue: 0.32, alpha: 1),
        NSColor(calibratedRed: 0.42, green: 0.73, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.93, green: 0.47, blue: 0.62, alpha: 1),
        NSColor(calibratedRed: 0.70, green: 0.63, blue: 0.97, alpha: 1)
    ]
}

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    enum SessionKind: String, Codable, Equatable {
        case terminal
        case agent
        case command
    }

    enum TitleSource: String, Codable, Equatable {
        case system
        case explicit
        case automatic
    }

    enum SessionState: Equatable {
        case launching
        case live
        case exited(Int32)
        case failed(String)

        var label: String {
            switch self {
            case .launching:
                "launching"
            case .live:
                "live"
            case .exited(let status):
                "exit \(status)"
            case .failed:
                "failed"
            }
        }

    }

    let id = UUID()
    @Published private(set) var title: String
    @Published private(set) var titleSource: TitleSource
    @Published private(set) var subtitle: String
    @Published private(set) var summary: String?
    @Published private(set) var workingDirectory: String
    @Published private(set) var state: SessionState = .launching
    @Published private(set) var hasUnreadNotification = false
    @Published private(set) var lastNotification: TerminalNotificationRequest?
    @Published private(set) var agentActivityState: AgentActivityState = .unknown
    @Published private(set) var startedAt: Date?
    @Published private(set) var exitedAt: Date?
    @Published private(set) var lastOutputAt: Date?
    @Published private(set) var outputVersion = 0
    @Published private(set) var lastInputOutputVersion: Int?
    @Published private(set) var lastContentChangeAt: Date?
    @Published private(set) var contentVersion = 0
    @Published private(set) var childProcessID: Int32?
    @Published private(set) var exitCode: Int32?
    @Published private(set) var nixShellEnvironment: NixShellEnvironment?
    private(set) var isEnhancedKeyboardProtocolActive = false
    private(set) var keyboardProtocolFlags = 0

    let projectRoot: String?
    let tint: NSColor
    let maxScrollback: Int?
    private(set) var launchWorkingDirectory: String
    let kind: SessionKind
    let agentName: String?
    @Published private(set) var parentAgentID: UUID?
    private(set) var commandName: String?
    private var launchCommand: String?
    private var launchEnvironment: [String: String]
    private var restartOnExit: Bool
    private var systemTitle: String
    private var automaticTitle: String?
    private let summaryRunner: AgentSummaryRun

    @Published private(set) var revision = 0

    private let processor: TerminalProcessor
    private let rawOutputStore = TerminalRawOutputStore()
    private let metadataParser = TerminalMetadataParser()
    let hostInputWriter = TerminalInputWriter()
    private var shellProcess: ShellProcessController?
    private var activeLaunchID: UUID?
    private var viewportSize = TerminalViewportSize(columns: 120, rows: 32)
    private var traceRecorder: TerminalTraceRecorder?
    private var outputHoldUntil: Date?
    private var isOutputPausedForInteraction = false
    private var keyboardProtocolFlagStack: [Int] = []
    private var ghosttyBridgeStorage: GhosttySessionBridge?
    private var summaryDebounceTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var summaryGeneration = 0
    private var lastSummaryOutputChangeDate: Date?
    private var lastSummaryInput: String?
    private var lastSummaryDate: Date?
    private var lastHumanInputLine: Int?
    private var agentActivitySource: AgentActivitySource = .none
    private var titleIndicatesAgentWorking = false
    private var lastTitleSpinnerAt: Date?
    private var lastStrongWorkingEvidenceAt: Date?
    private var agentIdleConfirmationTask: Task<Void, Never>?
    private var agentIdleRecheckTask: Task<Void, Never>?
    private var lastContentFingerprint: Int?

    enum AgentActivitySource {
        case none
        case summary
        case outputActivity
        case inputSubmit
        case promptMarker
        case workingMarker
        case titleSpinner
        case notification
        case processExit
    }

    private static let defaultMaxScrollback = 50_000
    private static let userScrollOutputHoldInterval: TimeInterval = 0.16
    private static let agentIdleConfirmationEvidenceWindow: TimeInterval = 1.0
    private static let agentIdleConfirmationDelay: TimeInterval = 0.4
    private static let agentIdleRecheckQuietInterval: TimeInterval = 4.0
    private static let contentFingerprintTailLineLimit = 40
    private static let summaryIdleInterval: TimeInterval = 2
    private static let summaryMaximumIdleWait: TimeInterval = 20
    private static let summaryTailLineLimit = 80
    private static let summaryMaximumCharacters = 6_000

    init(
        title: String,
        titleSource: TitleSource = .system,
        subtitle: String,
        tint: NSColor,
        workingDirectory: String = NSHomeDirectory(),
        projectRoot: String? = nil,
        maxScrollback: Int? = TerminalSession.defaultMaxScrollback,
        buffer: (any TerminalBuffering)? = nil,
        launchShell: Bool = true,
        kind: SessionKind = .terminal,
        agentName: String? = nil,
        parentAgentID: UUID? = nil,
        commandName: String? = nil,
        launchCommand: String? = nil,
        launchEnvironment: [String: String] = [:],
        restartOnExit: Bool = false,
        summaryRunner: @escaping AgentSummaryRun = { transcript, workingDirectory, model in
            try await CodexMCPSummaryRunner.shared.run(
                transcript: transcript,
                workingDirectory: workingDirectory,
                model: model
            )
        }
    ) {
        self.title = title
        self.titleSource = titleSource
        self.subtitle = subtitle
        self.tint = tint
        self.workingDirectory = workingDirectory
        self.launchWorkingDirectory = workingDirectory
        self.projectRoot = projectRoot
        self.maxScrollback = maxScrollback
        self.kind = kind
        self.agentName = agentName
        self.parentAgentID = kind == .agent ? parentAgentID : nil
        self.commandName = commandName
        self.launchCommand = launchCommand?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.launchEnvironment = launchEnvironment
        self.restartOnExit = restartOnExit
        self.summaryRunner = summaryRunner
        self.systemTitle = title
        let processorBuffer = buffer ?? (launchShell && !fullPrototypeProcessorEnabled
            ? LiveTerminalOutputBuffer(maxScrollback: maxScrollback)
            : nil)
        self.processor = TerminalProcessor(maxScrollback: maxScrollback, buffer: processorBuffer)
        self.traceRecorder = TerminalTraceRecorder(sessionID: id, title: title)
        self.processor.setChangeHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleProcessorDidChange()
            }
        }
        self.hostInputWriter.setInputHandler { [weak self] data in
            self?.noteInputBurst(data)
            self?.discardPendingOutputForInterrupt(in: data)
        }

        if launchShell {
            startShell()
        } else {
            state = .exited(0)
        }
    }

    var lineCount: Int {
        processor.lineCount
    }

    var cursorState: TerminalCursorState {
        processor.cursorState
    }

    var usesAlternateScreen: Bool {
        processor.usesAlternateScreen
    }

    var usesApplicationCursorKeys: Bool {
        processor.usesApplicationCursorKeys
    }

    var usesBracketedPasteMode: Bool {
        processor.usesBracketedPasteMode
    }

    var mouseState: TerminalMouseState {
        processor.mouseState
    }

    var statusLine: String {
        "\(state.label) · \(lineSummary)"
    }

    var acceptsInput: Bool {
        if case .live = state {
            return true
        }

        return false
    }

    var isRunning: Bool {
        activeLaunchID != nil
    }

    var restartPolicy: String? {
        guard kind == .command else { return nil }
        return restartOnExit ? "auto_restart" : "manual"
    }

    var hasExplicitTitle: Bool {
        titleSource == .explicit
    }

    var sidebarDetail: String {
        if let summary = summary?.nilIfEmpty {
            return summary
        }

        guard kind != .terminal else { return "" }
        return subtitle
    }

    func snapshot(range: Range<Int>) -> [String] {
        processor.snapshot(range: range)
    }

    func styledSnapshot(range: Range<Int>) -> [TerminalRenderedLine] {
        processor.styledSnapshot(range: range)
    }

    func lineLength(at row: Int) -> Int {
        processor.lineLength(at: row)
    }

    func gridPoint(row: Int, column: Int) -> TerminalGridPoint {
        processor.gridPoint(row: row, column: column)
    }

    func selectedText(in selection: TerminalSelectionRange) -> String {
        processor.selectedText(in: selection)
    }

    func setParentAgentID(_ parentAgentID: UUID?) {
        guard kind == .agent else { return }
        self.parentAgentID = parentAgentID
    }

    func send(text: String) {
        guard acceptsInput else { return }
        let data = Data(text.utf8)
        if !data.isEmpty {
            noteInputBurst(data)
        }
        if inputDebugEnabled {
            fputs("[send text] \(text.debugDescription)\n", stderr)
        }
        shellProcess?.write(text)
    }

    func send(data: Data) {
        guard acceptsInput else { return }
        sendInputData(data, normalize: true)
    }

    func sendRaw(data: Data) {
        guard acceptsInput else { return }
        sendInputData(data, normalize: false)
    }

    private func sendInputData(_ data: Data, normalize: Bool) {
        let outboundData = normalize ? normalizedInputData(data) : data
        if !outboundData.isEmpty {
            noteInputBurst(outboundData)
            discardPendingOutputForInterrupt(in: outboundData)
        }
        if inputDebugEnabled {
            let rendered = outboundData.map { String(format: "%02x", $0) }.joined(separator: " ")
            fputs("[send data] \(rendered) shellProcess=\(shellProcess != nil)\n", stderr)
        }
        shellProcess?.write(outboundData)
    }

    func sendInterrupt() {
        guard acceptsInput else { return }
        if inputDebugEnabled {
            fputs("[send interrupt] shellProcess=\(shellProcess != nil)\n", stderr)
        }
        processor.discardPendingOutput()
        shellProcess?.writeUrgent(Data([0x03]))
    }

    /// Mirror the kernel tty's flush-on-INTR for Cherry's own pipeline:
    /// when host input carries ^C, drop output we've already queued
    /// internally so the interrupt takes effect immediately even when a
    /// flooding process has megabytes buffered ahead of it. Kitty-protocol
    /// encodings of ^C don't match the raw byte — protocol-aware apps
    /// manage their own interrupt handling.
    private func discardPendingOutputForInterrupt(in outboundData: Data) {
        guard outboundData.contains(0x03) else { return }
        processor.discardPendingOutput()
    }

    func clearScrollback() {
        clearScrollback(preservingTerminalState: true)
    }

    private func clearScrollback(preservingTerminalState: Bool) {
        outputHoldUntil = nil
        resumeOutputIfPausedForInteraction()
        rawOutputStore.clear()
        if preservingTerminalState {
            processor.clearScreenAndScrollbackPreservingTerminalState()
            ghosttyBridgeStorage?.clearScreenAndScrollback()
        } else {
            processor.clear()
            ghosttyBridgeStorage?.reset()
        }
        lastHumanInputLine = nil
        lastContentFingerprint = nil
        clearUnreadNotification()
        bumpRevision()
    }

    func clearUnreadNotification() {
        guard hasUnreadNotification || lastNotification != nil else { return }
        hasUnreadNotification = false
        lastNotification = nil
        bumpRevision()
    }

    func restart() {
        stop()
        clearScrollback(preservingTerminalState: false)
        startShell()
    }

    func restartManagedCommandIfNeeded() {
        guard kind == .command else { return }

        switch state {
        case .launching, .live:
            return
        case .exited, .failed:
            clearScrollback(preservingTerminalState: false)
            startShell()
        }
    }

    func rename(to requestedTitle: String?) {
        let trimmedTitle = requestedTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        guard let trimmedTitle else {
            clearExplicitTitle()
            return
        }

        title = trimmedTitle
        titleSource = .explicit
        bumpRevision()
    }

    func applyAutomaticSummary(
        _ nextSummary: String,
        useAsTitle: Bool,
        agentActivityState nextAgentActivityState: AgentActivityState? = nil
    ) {
        let sanitized = sanitizedSummary(nextSummary).nilIfEmpty
        let shouldApplyTitle = kind != .agent && useAsTitle && titleSource != .explicit && sanitized != nil
        var didChange = false

        if summary != sanitized {
            summary = sanitized
            didChange = true
        }

        if shouldApplyTitle, let sanitized {
            automaticTitle = sanitized
            title = sanitized
            titleSource = .automatic
            didChange = true
        }

        if kind == .agent, let nextAgentActivityState {
            if applySummaryActivityState(nextAgentActivityState) {
                didChange = true
            }
        }

        guard didChange else { return }
        bumpRevision()
    }

    func stop() {
        let launchID = activeLaunchID
        activeLaunchID = nil
        summaryDebounceTask?.cancel()
        summaryDebounceTask = nil
        summaryTask?.cancel()
        summaryTask = nil
        nixShellEnvironment = nil
        cancelAgentIdleConfirmation()
        cancelAgentIdleRecheck()
        resetKeyboardProtocolState()
        lastHumanInputLine = nil
        outputHoldUntil = nil
        processor.endLaunch(launchID)
        resumeOutputIfPausedForInteraction()
        hostInputWriter.set(nil)
        shellProcess?.terminate()
        shellProcess = nil
    }

    func releaseGhosttyBridge() {
        guard let ghosttyBridgeStorage else { return }
        ghosttyBridgeStorage.releaseResources()
        self.ghosttyBridgeStorage = nil
    }

    func detachGhosttyBridge(from container: GhosttyTerminalContainerView, preservingSurface: Bool = false) {
        ghosttyBridgeStorage?.detach(from: container, preservingSurface: preservingSurface)
    }

    func stopManagedCommand() {
        guard kind == .command else {
            stop()
            return
        }

        stop()
        state = .exited(0)
        let hideCursor = Data("\u{1B}[?25l".utf8)
        rawOutputStore.append(hideCursor)
        processor.ingestTestingData(hideCursor)
        bumpRevision()
    }

    func updateManagedCommand(_ command: ProjectCommandDefinition, workingDirectory: String) {
        guard kind == .command else { return }

        if !command.name.isEmpty {
            updateSystemTitle(command.name)
        }
        subtitle = command.commandLine
        self.workingDirectory = workingDirectory
        launchWorkingDirectory = workingDirectory
        commandName = command.name
        launchCommand = command.commandLine.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        launchEnvironment = command.environment
        restartOnExit = command.autoRestart
        bumpRevision()
    }

    func resize(columns: Int, rows: Int) {
        let nextSize = TerminalViewportSize(columns: columns, rows: rows)
        guard nextSize.columns > 0, nextSize.rows > 0, nextSize != viewportSize else { return }

        viewportSize = nextSize
        processor.resize(to: nextSize)
        shellProcess?.resize(columns: nextSize.columns, rows: nextSize.rows)
        revision &+= 1
    }

    func deferOutputForUserInteraction() {
        outputHoldUntil = Date(timeIntervalSinceNow: Self.userScrollOutputHoldInterval)
        pauseOutputForInteractionIfNeeded()
    }

    func ingestTestingData(_ data: Data) {
        rawOutputStore.append(data)
        lastOutputAt = Date()
        ingestTerminalMetadata(data)
        processor.ingestTestingData(data)
        bumpRevision()
    }

    func rawOutput(maxBytes: Int) -> (data: Data, truncated: Bool) {
        rawOutputStore.snapshot(maxBytes: maxBytes)
    }

    func observeRawOutput(replayExistingOutput: Bool, _ observer: @escaping @Sendable (Data) -> Void) -> UUID {
        rawOutputStore.observe(replayExistingOutput: replayExistingOutput, observer)
    }

    func removeRawOutputObserver(id: UUID) {
        rawOutputStore.removeObserver(id: id)
    }

    var rawOutputObserverCount: Int {
        rawOutputStore.observerCount
    }

    var ghosttyBridge: GhosttySessionBridge {
        if let ghosttyBridgeStorage {
            return ghosttyBridgeStorage
        }

        let bridge = GhosttySessionBridge(session: self)
        ghosttyBridgeStorage = bridge
        return bridge
    }

    private func startShell() {
        let launchID = UUID()
        activeLaunchID = launchID
        resetKeyboardProtocolState()
        outputHoldUntil = nil
        processor.beginLaunch(launchID)
        resumeOutputIfPausedForInteraction()
        state = .launching
        startedAt = Date()
        exitedAt = nil
        lastOutputAt = nil
        childProcessID = nil
        exitCode = nil
        nixShellEnvironment = nil
        if kind == .agent {
            cancelAgentIdleConfirmation()
            cancelAgentIdleRecheck()
            titleIndicatesAgentWorking = false
            lastTitleSpinnerAt = nil
            lastStrongWorkingEvidenceAt = nil
            setAgentActivityState(.unknown, source: .none)
        }
        bumpRevision()

        do {
            let processor = processor
            let traceRecorder = traceRecorder
            let process = try ShellProcessController(
                configuration: .init(
                    shellPath: ShellProcessController.defaultShellPath,
                    workingDirectory: workingDirectory,
                    projectRoot: projectRoot,
                    processID: id.uuidString,
                    agentID: kind == .agent ? id.uuidString : nil,
                    environment: launchEnvironment,
                    term: ShellProcessController.preferredTerminfo.term,
                    initialSize: viewportSize,
                    startupCommand: launchCommand
                ),
                onData: { data in
                    TerminalPerformanceMonitor.recordPTYOutputChunk(bytes: data.count)
                    traceRecorder?.recordOutput(data)
                    self.rawOutputStore.append(data)
                    DispatchQueue.main.async { [weak self] in
                        self?.lastOutputAt = Date()
                        self?.ingestTerminalMetadata(data)
                    }
                    if !prototypeProcessorDisabledForPerf {
                        processor.enqueueOutput(data, launchID: launchID, responseWriter: { response in
                            self.hostInputWriter.write(response, normalize: false, notifyInput: false)
                        })
                    }
                },
                onExit: { [weak self] status in
                    DispatchQueue.main.async {
                        self?.handleProcessExit(status: status, launchID: launchID)
                    }
                }
            )
            shellProcess = process
            hostInputWriter.set(process)
            childProcessID = process.processIdentifier.map { Int32($0) }

            state = .live
            bumpRevision()
        } catch {
            activeLaunchID = nil
            hostInputWriter.set(nil)
            processor.endLaunch(launchID)
            state = .failed(error.localizedDescription)
            processor.appendPlainLines([
                "launch failed: \(error.localizedDescription)"
            ])
            bumpRevision()
        }
    }

    private func handleProcessExit(status: Int32, launchID: UUID) {
        guard activeLaunchID == launchID else { return }
        finishProcessExit(status: status, launchID: launchID)
    }

    private func finishProcessExit(status: Int32, launchID: UUID) {
        guard activeLaunchID == launchID else { return }

        activeLaunchID = nil
        hostInputWriter.set(nil)
        shellProcess = nil
        childProcessID = nil
        exitCode = status
        nixShellEnvironment = nil
        exitedAt = Date()
        if kind == .agent {
            cancelAgentIdleConfirmation()
            cancelAgentIdleRecheck()
            titleIndicatesAgentWorking = false
            lastTitleSpinnerAt = nil
            setAgentActivityState(status == 0 ? .idle : .error, source: .processExit)
        }
        resetKeyboardProtocolState()
        outputHoldUntil = nil
        processor.endLaunch(launchID)
        resumeOutputIfPausedForInteraction()
        state = .exited(status)
        if kind == .agent || kind == .command {
            let hideCursor = Data("\u{1B}[?25l".utf8)
            rawOutputStore.append(hideCursor)
            processor.ingestTestingData(hideCursor)
            if kind == .command, restartOnExit {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self, self.shellProcess == nil else { return }
                    self.clearScrollback(preservingTerminalState: false)
                    self.startShell()
                }
            }
        } else {
            processor.appendPlainLines([
                "",
                "[shell exited with status \(status)]"
            ])
        }
        bumpRevision()
    }

    private func pauseOutputForInteractionIfNeeded() {
        guard !isOutputPausedForInteraction else { return }
        isOutputPausedForInteraction = true
        shellProcess?.pauseOutput()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.userScrollOutputHoldInterval) { [weak self] in
            self?.resumeOutputIfScrollHoldExpired()
        }
    }

    private func resumeOutputIfScrollHoldExpired() {
        guard let outputHoldUntil else {
            resumeOutputIfPausedForInteraction()
            return
        }

        let remaining = outputHoldUntil.timeIntervalSinceNow
        if remaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                self?.resumeOutputIfScrollHoldExpired()
            }
            return
        }

        self.outputHoldUntil = nil
        resumeOutputIfPausedForInteraction()
    }

    private func resumeOutputIfPausedForInteraction() {
        guard isOutputPausedForInteraction else { return }
        isOutputPausedForInteraction = false
        shellProcess?.resumeOutput()
    }

    private func handleProcessorDidChange() {
        TerminalPerformanceMonitor.recordProcessorChange()
        if inputDebugEnabled {
            let tailStart = max(0, processor.lineCount - 4)
            let tail = processor.snapshot(range: tailStart..<processor.lineCount)
            fputs("[buffer tail] \(tail.map(\.debugDescription).joined(separator: " | "))\n", stderr)
        }
        if case .launching = state {
            state = .live
        }
        outputVersion &+= 1
        let contentChanged = updateContentFingerprint()
        if contentChanged {
            lastContentChangeAt = Date()
            contentVersion &+= 1
        }
        if kind == .agent, contentChanged {
            lastSummaryOutputChangeDate = Date()
            recordAgentActivitySignal()
            if agentActivityState == .working {
                scheduleAgentIdleRecheck()
            }
        }
        if contentChanged {
            scheduleSummaryIfNeeded()
        }
        bumpRevision()
    }

    private func updateContentFingerprint() -> Bool {
        let lineCount = processor.lineCount
        let tailStart = max(0, lineCount - Self.contentFingerprintTailLineLimit)
        var hasher = Hasher()
        hasher.combine(lineCount)
        hasher.combine(processor.usesAlternateScreen)
        for line in processor.snapshot(range: tailStart..<lineCount) {
            hasher.combine(line)
        }
        let fingerprint = hasher.finalize()
        guard fingerprint != lastContentFingerprint else { return false }
        lastContentFingerprint = fingerprint
        return true
    }

    private func noteInputBurst(_ input: Data) {
        noteInputOutputBaseline()
        if kind == .agent {
            if Self.agentInputSubmitsTurn(input) {
                noteHumanInputIfNeeded()
                setAgentActivityState(.working, source: .inputSubmit)
                scheduleAgentIdleRecheck()
            }
        }
    }

    private func noteInputOutputBaseline() {
        lastInputOutputVersion = outputVersion
    }

    private func ingestTerminalMetadata(_ data: Data) {
        var didChange = false
        for event in metadataParser.parse(data) {
            switch event {
            case .title(let nextTitle):
                if kind == .agent {
                    didChange = recordAgentTitleActivity(nextTitle) || didChange
                } else {
                    guard systemTitle != nextTitle else { continue }
                    updateSystemTitle(nextTitle)
                    didChange = true
                }

            case .workingDirectory(let nextWorkingDirectory):
                if workingDirectory != nextWorkingDirectory {
                    workingDirectory = nextWorkingDirectory
                    didChange = true
                }
                if restoreShellTitle(from: nextWorkingDirectory) {
                    didChange = true
                }

            case .notification(let notification):
                if handleAgentNotification(notification) == .passThrough {
                    handleTerminalNotification(notification)
                }
                didChange = true

            case .nixShell(let event):
                switch event {
                case .enter(let environment):
                    if nixShellEnvironment != environment {
                        nixShellEnvironment = environment
                        didChange = true
                    }
                case .exit:
                    if nixShellEnvironment != nil {
                        nixShellEnvironment = nil
                        didChange = true
                    }
                }

            case .keyboardProtocolPush(let flags):
                keyboardProtocolFlagStack.append(keyboardProtocolFlags)
                applyKeyboardProtocolFlags(flags)

            case .keyboardProtocolPop(let count):
                if count > keyboardProtocolFlagStack.count {
                    keyboardProtocolFlagStack.removeAll(keepingCapacity: true)
                    applyKeyboardProtocolFlags(0)
                } else {
                    keyboardProtocolFlagStack.removeLast(count - 1)
                    applyKeyboardProtocolFlags(keyboardProtocolFlagStack.removeLast())
                }

            case .keyboardProtocolSet(let flags, let mode):
                applyKeyboardProtocolFlags(keyboardProtocolFlagsByApplying(flags: flags, mode: mode))
            }
        }

        if didChange {
            bumpRevision()
        }
    }

    private func handleTerminalNotification(_ notification: TerminalNotificationRequest) {
        guard !ProjectWindowRegistry.shared.isSessionVisible(self) else { return }
        guard !(kind == .agent && parentAgentID != nil) else { return }
        lastNotification = notification
        hasUnreadNotification = true
        TerminalNotificationCenter.shared.post(notification, for: self)
    }

    enum AgentNotificationDisposition {
        case passThrough
        case suppress
    }

    private func handleAgentNotification(
        _ notification: TerminalNotificationRequest
    ) -> AgentNotificationDisposition {
        guard kind == .agent else { return .passThrough }

        let body = notification.body
        if Self.notificationBodyIndicatesPermission(body) {
            setAgentActivityState(.permission, source: .notification)
            return .passThrough
        }
        if Self.notificationBodyIndicatesCompletion(body) {
            setAgentActivityState(.idle, source: .notification)
            clearUnreadNotification()
            return .suppress
        }
        return .passThrough
    }

    private var agentStateHasDirectEvidence: Bool {
        switch agentActivitySource {
        case .promptMarker, .workingMarker, .titleSpinner, .notification, .processExit:
            true
        case .none, .summary, .outputActivity, .inputSubmit:
            false
        }
    }

    // Agents without a recognizable prompt/working UI (e.g. plain REPLs) only
    // ever produce weak evidence; idle waits fall back to quiet windows for them.
    var agentActivityEvidenceIsStrong: Bool {
        kind == .agent && agentStateHasDirectEvidence
    }

    private func applySummaryActivityState(_ nextState: AgentActivityState) -> Bool {
        guard agentActivityState != nextState else { return false }
        guard !agentStateHasDirectEvidence else { return false }
        setAgentActivityState(nextState, source: .summary)
        return true
    }

    @discardableResult
    private func recordAgentTitleActivity(_ title: String) -> Bool {
        guard kind == .agent else { return false }

        let spinnerActive = Self.titleIndicatesAgentWorking(title)
        let spinnerCleared = titleIndicatesAgentWorking && !spinnerActive
        titleIndicatesAgentWorking = spinnerActive

        if spinnerActive {
            lastTitleSpinnerAt = Date()
            lastStrongWorkingEvidenceAt = Date()
            scheduleAgentIdleRecheck()
            return markAgentWorking(source: .titleSpinner)
        }
        if spinnerCleared || agentUsesTitleActivitySignals {
            return recordAgentActivitySignal()
        }
        return false
    }

    private static func titleIndicatesAgentWorking(_ title: String) -> Bool {
        guard let first = title.trimmingCharacters(in: .whitespaces).unicodeScalars.first else {
            return false
        }
        return (0x2800...0x28FF).contains(Int(first.value))
    }

    // Codex/Claude pulse the title spinner several times per second while a turn
    // is in flight, but may leave the last spinner frame behind when they settle,
    // so the title only counts as working evidence while the pulses are fresh.
    private static let titleSpinnerFreshnessWindow: TimeInterval = 3.0

    private var titleSpinnerEvidenceIsActive: Bool {
        guard titleIndicatesAgentWorking, let lastTitleSpinnerAt else { return false }
        return Date().timeIntervalSince(lastTitleSpinnerAt) < Self.titleSpinnerFreshnessWindow
    }

    private var agentUsesTitleActivitySignals: Bool {
        let normalizedName = AgentToolDefinition.normalizedName(agentName ?? title)
        if normalizedName == "codex" || normalizedName == "amp" {
            return true
        }

        let commandName = subtitle
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)?
            .lowercased()
        return commandName == "codex" || commandName == "amp"
    }

    @discardableResult
    private func recordAgentActivitySignal() -> Bool {
        guard kind == .agent else { return false }
        guard agentActivitySource != .processExit else { return false }

        if renderedOutputShowsAgentWorkingMarker() {
            return markAgentWorking(source: .workingMarker)
        }
        if titleSpinnerEvidenceIsActive {
            return markAgentWorking(source: .titleSpinner)
        }
        if renderedOutputShowsAgentInputPrompt() {
            return requestAgentIdleFromRenderedOutput()
        }
        guard !agentStateResistsOutputActivity else { return false }
        return setAgentActivityState(.working, source: .outputActivity)
    }

    private var agentStateResistsOutputActivity: Bool {
        if agentActivityState == .permission || agentActivityState == .error {
            return true
        }
        switch agentActivitySource {
        case .promptMarker, .notification, .processExit:
            return true
        case .none, .summary, .outputActivity, .inputSubmit, .workingMarker, .titleSpinner:
            return false
        }
    }

    @discardableResult
    private func markAgentWorking(source: AgentActivitySource) -> Bool {
        guard agentActivitySource != .processExit else { return false }
        guard agentActivityState != .permission, agentActivityState != .error else { return false }
        cancelAgentIdleConfirmation()
        if source == .workingMarker || source == .titleSpinner {
            lastStrongWorkingEvidenceAt = Date()
        }
        return setAgentActivityState(.working, source: source)
    }

    @discardableResult
    private func requestAgentIdleFromRenderedOutput() -> Bool {
        guard agentActivitySource != .processExit else { return false }
        guard agentActivityState != .permission, agentActivityState != .error else { return false }

        if let lastStrongWorkingEvidenceAt,
           Date().timeIntervalSince(lastStrongWorkingEvidenceAt) < Self.agentIdleConfirmationEvidenceWindow {
            scheduleAgentIdleConfirmation()
            return false
        }
        cancelAgentIdleConfirmation()
        return setAgentActivityState(.idle, source: .promptMarker)
    }

    private func scheduleAgentIdleConfirmation() {
        guard agentIdleConfirmationTask == nil else { return }
        agentIdleConfirmationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.agentIdleConfirmationDelay * 1_000)))
            guard let self, !Task.isCancelled else { return }
            self.agentIdleConfirmationTask = nil
            self.confirmAgentIdleIfStillAtPrompt()
        }
    }

    private func cancelAgentIdleConfirmation() {
        agentIdleConfirmationTask?.cancel()
        agentIdleConfirmationTask = nil
    }

    private func confirmAgentIdleIfStillAtPrompt() {
        guard kind == .agent, agentActivitySource != .processExit else { return }
        guard agentActivityState != .permission, agentActivityState != .error else { return }
        guard !renderedOutputShowsAgentWorkingMarker(), !titleSpinnerEvidenceIsActive else { return }
        guard renderedOutputShowsAgentInputPrompt() else { return }
        setAgentActivityState(.idle, source: .promptMarker)
    }

    private func scheduleAgentIdleRecheck() {
        guard kind == .agent else { return }
        agentIdleRecheckTask?.cancel()
        agentIdleRecheckTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.agentIdleRecheckQuietInterval * 1_000)))
            guard let self, !Task.isCancelled else { return }
            self.agentIdleRecheckTask = nil
            self.recheckAgentActivityAfterQuiet()
        }
    }

    private func cancelAgentIdleRecheck() {
        agentIdleRecheckTask?.cancel()
        agentIdleRecheckTask = nil
    }

    private func recheckAgentActivityAfterQuiet() {
        if activityDebugEnabled {
            fputs("[activity] recheck state=\(agentActivityState) source=\(agentActivitySource) marker=\(renderedOutputShowsAgentWorkingMarker()) spinner=\(titleSpinnerEvidenceIsActive) prompt=\(renderedOutputShowsAgentInputPrompt())\n", stderr)
        }
        guard kind == .agent, agentActivityState == .working else { return }
        guard agentActivitySource != .processExit else { return }
        guard !renderedOutputShowsAgentWorkingMarker(), !titleSpinnerEvidenceIsActive else { return }

        let lineCount = effectiveAgentContentLineCount()
        guard lineCount > 0 else { return }
        let normalizedAgentName = AgentToolDefinition.normalizedName(agentName ?? title)
        let scanStart = max(0, lineCount - Self.agentInputMarkerTailLineLimit)
        let scanLines = processor.snapshot(range: scanStart..<lineCount)
        let promptLines = agentPromptWindowLines(
            scanStart: scanStart,
            scanLines: scanLines,
            applyInputFloor: false
        )
        let promptVisible = promptLines.contains { line in
            Self.isAgentInputPromptLine(line, normalizedAgentName: normalizedAgentName)
        } || Self.outputContainsAgentInputMarker(scanLines, normalizedAgentName: normalizedAgentName)
        guard promptVisible else { return }
        setAgentActivityState(.idle, source: .promptMarker)
    }

    // TUIs that park the cursor on the bottom screen row materialize dozens of
    // empty rows below their content, so tail windows must anchor to the last
    // row that actually holds text.
    private static let agentTrailingBlankScanLimit = 600

    private func effectiveAgentContentLineCount() -> Int {
        let lineCount = processor.lineCount
        guard lineCount > 0 else { return 0 }
        let scanStart = max(0, lineCount - Self.agentTrailingBlankScanLimit)
        let scanLines = processor.snapshot(range: scanStart..<lineCount)
        var effectiveEnd = lineCount
        var index = scanLines.count - 1
        while index >= 0,
              scanLines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            effectiveEnd -= 1
            index -= 1
        }
        return effectiveEnd
    }

    private func renderedOutputShowsAgentWorkingMarker() -> Bool {
        let lineCount = effectiveAgentContentLineCount()
        guard lineCount > 0 else { return false }
        let normalizedAgentName = AgentToolDefinition.normalizedName(agentName ?? title)
        let markerStart = max(0, lineCount - Self.agentInputMarkerTailLineLimit)
        let markerLines = processor.snapshot(range: markerStart..<lineCount)
        return Self.outputContainsAgentWorkingMarker(markerLines, normalizedAgentName: normalizedAgentName)
    }

    private func renderedOutputShowsAgentInputPrompt() -> Bool {
        let lineCount = effectiveAgentContentLineCount()
        guard lineCount > 0 else { return false }

        let normalizedAgentName = AgentToolDefinition.normalizedName(agentName ?? title)
        let markerStart = max(0, lineCount - Self.agentInputMarkerTailLineLimit)
        let markerLines = processor.snapshot(range: markerStart..<lineCount)
        if Self.outputContainsAgentWorkingMarker(markerLines, normalizedAgentName: normalizedAgentName) {
            return false
        }

        let promptLines = agentPromptWindowLines(
            scanStart: markerStart,
            scanLines: markerLines,
            applyInputFloor: true
        )
        if promptLines.contains(where: { line in
            Self.isAgentInputPromptLine(line, normalizedAgentName: normalizedAgentName)
        }) {
            return true
        }

        return Self.outputContainsAgentInputMarker(markerLines, normalizedAgentName: normalizedAgentName)
    }

    // Alternate-screen grids and PTY echo can leave blank rows below the visible
    // content, so the prompt window is anchored to the last non-blank row.
    private func agentPromptWindowLines(
        scanStart: Int,
        scanLines: [String],
        applyInputFloor: Bool
    ) -> [String] {
        var effectiveEndOffset = scanLines.count
        while effectiveEndOffset > 0,
              scanLines[effectiveEndOffset - 1]
                  .trimmingCharacters(in: .whitespacesAndNewlines)
                  .isEmpty {
            effectiveEndOffset -= 1
        }
        guard effectiveEndOffset > 0 else { return [] }

        let effectiveEnd = scanStart + effectiveEndOffset
        let promptStart = Self.agentInputPromptSearchStart(
            lineCount: effectiveEnd,
            lastHumanInputLine: applyInputFloor ? lastHumanInputLine : nil
        )
        guard promptStart < effectiveEnd, promptStart >= scanStart else { return [] }
        return Array(scanLines[(promptStart - scanStart)..<effectiveEndOffset])
    }

    private static let agentInputPromptTailLineLimit = 8
    private static let agentInputMarkerTailLineLimit = 32

    private static func agentInputPromptSearchStart(lineCount: Int, lastHumanInputLine: Int?) -> Int {
        let tailStart = max(0, lineCount - agentInputPromptTailLineLimit)
        guard let lastHumanInputLine, lastHumanInputLine < lineCount else {
            // Fixed-size screens (alternate-screen TUIs) repaint in place, so the
            // buffer never grows past the line recorded at submit time; a floor
            // there would disable idle detection permanently.
            return tailStart
        }
        return max(lastHumanInputLine, tailStart)
    }

    private static func isAgentInputPromptLine(_ line: String, normalizedAgentName: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if isPromptLine(trimmed, prompt: "\u{203A}") ||
            isPromptLine(trimmed, prompt: "\u{276F}") {
            return true
        }

        if normalizedAgentName == "claude" || normalizedAgentName == "gemini" {
            return isPromptLine(trimmed, prompt: ">")
        }

        return false
    }

    // Claude Code separates the composer glyph from its ghost text with a
    // no-break space, so any Unicode whitespace counts as the separator.
    private static func isPromptLine(_ trimmed: String, prompt: String) -> Bool {
        guard trimmed.hasPrefix(prompt) else { return false }
        let rest = trimmed.dropFirst(prompt.count)
        guard let next = rest.first else { return true }
        return next.isWhitespace
    }

    private static func outputContainsAgentInputMarker(_ lines: [String], normalizedAgentName: String) -> Bool {
        let output = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "\n")

        switch normalizedAgentName {
        case "gemini":
            return output.contains("do you trust this folder?")
                || output.contains("how would you like to authenticate for this project?")
        case "opencode":
            return output.contains("ask anything...")
        case "pi":
            return output.contains("press ctrl+o to show full startup help")
                || output.contains("pi can explain its own features")
        default:
            return false
        }
    }

    private static func outputContainsAgentWorkingMarker(_ lines: [String], normalizedAgentName: String) -> Bool {
        let output = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "\n")

        // Claude Code 2.x and Codex both surface "esc to interrupt" only while a
        // turn is in flight; older Codex builds used "Working (Xs · esc to interrupt)".
        if output.contains("esc to interrupt") {
            return true
        }
        if output.contains("working (") {
            return true
        }

        guard normalizedAgentName == "claude" else { return false }
        return output.contains("whisking")
            || output.contains("still thinking")
            || output.contains("shell still running")
    }

    private static let agentCompletionPhrases: [String] = [
        "turn complete",
        "task complete",
        "task done",
        "agent done"
    ]

    private static let agentPermissionPhrases: [String] = [
        "permission required",
        "permission needed",
        "needs approval",
        "needs permission",
        "needs confirmation",
        "awaiting approval",
        "awaiting permission",
        "awaiting confirmation",
        "approval required",
        "approval needed",
        "confirmation required",
        "confirmation needed"
    ]

    private static func notificationBodyIndicatesCompletion(_ body: String) -> Bool {
        notificationBody(body, containsAnyPhraseAsWord: agentCompletionPhrases)
    }

    private static func notificationBodyIndicatesPermission(_ body: String) -> Bool {
        notificationBody(body, containsAnyPhraseAsWord: agentPermissionPhrases)
    }

    private static func notificationBody(_ body: String, containsAnyPhraseAsWord phrases: [String]) -> Bool {
        let lowered = body.lowercased()
        for phrase in phrases {
            var searchStart = lowered.startIndex
            while searchStart < lowered.endIndex,
                  let range = lowered.range(of: phrase, range: searchStart..<lowered.endIndex) {
                let startIsBoundary = range.lowerBound == lowered.startIndex
                    || !lowered[lowered.index(before: range.lowerBound)].isLetter
                let endIsBoundary = range.upperBound == lowered.endIndex
                    || !lowered[range.upperBound].isLetter
                if startIsBoundary && endIsBoundary {
                    return true
                }
                searchStart = range.upperBound
            }
        }
        return false
    }

    private static let bracketedPasteStartBytes = Array("\u{1B}[200~".utf8)
    private static let bracketedPasteEndBytes = Array("\u{1B}[201~".utf8)

    private static func agentInputSubmitsTurn(_ data: Data) -> Bool {
        let bytes = Array(data)
        var isBracketedPaste = false
        var index = 0

        while index < bytes.count {
            if bytes[index...].starts(with: bracketedPasteStartBytes) {
                isBracketedPaste = true
                index += bracketedPasteStartBytes.count
                continue
            }

            if isBracketedPaste, bytes[index...].starts(with: bracketedPasteEndBytes) {
                isBracketedPaste = false
                index += bracketedPasteEndBytes.count
                continue
            }

            if !isBracketedPaste, bytes[index] == 0x0A || bytes[index] == 0x0D {
                return true
            }

            index += 1
        }

        return false
    }

    @discardableResult
    private func setAgentActivityState(_ nextState: AgentActivityState, source: AgentActivitySource) -> Bool {
        guard kind == .agent else { return false }
        let stateChanged = agentActivityState != nextState
        agentActivityState = nextState
        agentActivitySource = source
        guard stateChanged else { return false }
        bumpRevision()
        return true
    }

    private func normalizedInputData(_ data: Data) -> Data {
        TerminalInputNormalizer.normalize(data, keyboardProtocolFlags: keyboardProtocolFlags)
    }

    private func applyKeyboardProtocolFlags(_ flags: Int) {
        keyboardProtocolFlags = flags
        isEnhancedKeyboardProtocolActive = keyboardProtocolFlags > 0
        hostInputWriter.setKeyboardProtocolFlags(keyboardProtocolFlags)
    }

    private func resetKeyboardProtocolState() {
        keyboardProtocolFlagStack.removeAll(keepingCapacity: true)
        applyKeyboardProtocolFlags(0)
    }

    private func clearExplicitTitle() {
        guard titleSource == .explicit else { return }
        if let automaticTitle {
            title = automaticTitle
            titleSource = .automatic
        } else {
            title = systemTitle
            titleSource = .system
        }
        bumpRevision()
    }

    private func updateSystemTitle(_ nextTitle: String) {
        let trimmedTitle = nextTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        systemTitle = trimmedTitle
        if titleSource == .system {
            title = trimmedTitle
        }
    }

    private func restoreShellTitle(from workingDirectory: String) -> Bool {
        guard kind != .agent else { return false }

        let shellTitle = NSString(string: workingDirectory).abbreviatingWithTildeInPath
        guard systemTitle != shellTitle else { return false }
        updateSystemTitle(shellTitle)
        return true
    }

    private func scheduleSummaryIfNeeded() {
        guard kind == .agent else { return }
        guard !ProjectWindowRegistry.shared.isSessionVisible(self) else { return }

        let settings = AgentSettings.shared
        let command = settings.effectiveAgentSummaryCommand.trimmingCharacters(in: .whitespacesAndNewlines)

        let now = Date()
        if let lastSummaryDate, now.timeIntervalSince(lastSummaryDate) < settings.agentSummaryCadence.interval {
            return
        }
        guard summaryDebounceTask == nil, summaryTask == nil else { return }

        summaryGeneration &+= 1
        let generation = summaryGeneration
        let scheduledAt = now
        summaryDebounceTask = Task { [weak self] in
            while !Task.isCancelled {
                let waitSeconds = await MainActor.run {
                    guard let self else { return 0.0 }
                    let latestOutputDate = self.lastSummaryOutputChangeDate ?? scheduledAt
                    let idleReadyDate = latestOutputDate.addingTimeInterval(Self.summaryIdleInterval)
                    let maximumReadyDate = scheduledAt.addingTimeInterval(Self.summaryMaximumIdleWait)
                    let readyDate = min(idleReadyDate, maximumReadyDate)
                    return max(0, readyDate.timeIntervalSinceNow)
                }
                if waitSeconds <= 0 { break }
                try? await Task.sleep(for: .milliseconds(Int(waitSeconds * 1_000)))
            }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.summaryDebounceTask = nil
                self.startSummary(generation: generation, command: command)
            }
        }
    }

    private func startSummary(generation: Int, command: String) {
        guard generation == summaryGeneration, kind == .agent else { return }
        let transcript = summaryTranscript()
        let transcriptOutputVersion = outputVersion
        guard !transcript.text.isEmpty else {
            recordSummaryDebug(command: command, transcript: transcript, prompt: "", summary: nil, error: "No summarizable terminal output yet.")
            return
        }
        guard transcript.text != lastSummaryInput else {
            lastSummaryDate = Date()
            recordSummaryDebug(command: command, transcript: transcript, prompt: "", summary: nil, error: "Transcript unchanged.")
            return
        }

        let settings = AgentSettings.shared
        let useAsTitle = settings.useAgentSummaryAsTitle
        let summaryModel = settings.agentSummaryModel
        let prompt = summaryPrompt(for: transcript.text)
        let summaryWorkingDirectory = workingDirectory
        let summaryRunner = self.summaryRunner
        recordSummaryDebug(command: command, transcript: transcript, prompt: prompt, summary: nil, error: nil)
        summaryTask = Task { [weak self] in
            do {
                let result = try await summaryRunner(transcript.text, summaryWorkingDirectory, summaryModel)
                await MainActor.run {
                    guard let self else { return }
                    guard !Task.isCancelled else {
                        self.summaryTask = nil
                        return
                    }
                    let outputChanged = self.outputVersion != transcriptOutputVersion
                    self.summaryTask = nil
                    guard generation == self.summaryGeneration, !outputChanged else {
                        if outputChanged {
                            self.scheduleSummaryIfNeeded()
                        }
                        return
                    }
                    self.lastSummaryInput = transcript.text
                    self.lastSummaryDate = Date()
                    self.recordSummaryDebug(
                        command: command,
                        transcript: transcript,
                        prompt: result.prompt,
                        summary: result.summary,
                        error: nil
                    )
                    self.applyAutomaticSummary(
                        result.summary,
                        useAsTitle: useAsTitle,
                        agentActivityState: result.state
                    )
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    guard !Task.isCancelled else {
                        self.summaryTask = nil
                        return
                    }
                    let outputChanged = self.outputVersion != transcriptOutputVersion
                    self.summaryTask = nil
                    guard generation == self.summaryGeneration, !outputChanged else {
                        if outputChanged {
                            self.scheduleSummaryIfNeeded()
                        }
                        return
                    }
                    self.lastSummaryDate = Date()
                    self.recordSummaryDebug(
                        command: command,
                        transcript: transcript,
                        prompt: prompt,
                        summary: nil,
                        error: error.localizedDescription
                    )
                }
            }
        }
    }

    private func recordSummaryDebug(
        command: String,
        transcript: SummaryTranscript,
        prompt: String,
        summary: String?,
        error: String?
    ) {
        AgentSummaryDebugStore.shared.record(.init(
            date: Date(),
            sessionID: id,
            sessionTitle: title,
            command: command,
            workingDirectory: workingDirectory,
            inputLineCount: transcript.inputLineCount,
            filteredLineCount: transcript.filteredLineCount,
            charactersSent: prompt.count,
            transcript: transcript.text,
            prompt: prompt,
            summary: summary,
            error: error
        ))
    }

    private func summaryTranscript() -> SummaryTranscript {
        let lineCount = effectiveAgentContentLineCount()
        guard lineCount > 0 else { return .empty }
        let recentStartLine = max(0, lineCount - Self.summaryTailLineLimit)
        let inputLines = processor.snapshot(range: recentStartLine..<lineCount)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let lines = inputLines.filter { !Self.shouldDropSummaryLine($0) }
        let text = lines.joined(separator: "\n")
        var trimmedText = text.count > Self.summaryMaximumCharacters
            ? String(text.suffix(Self.summaryMaximumCharacters))
            : text
        if kind == .agent {
            let promptVisible = !renderedOutputShowsAgentWorkingMarker()
                && !titleSpinnerEvidenceIsActive
                && renderedOutputShowsAgentInputPrompt()
            trimmedText += "\n[terminal status: input prompt waiting for user = \(promptVisible ? "yes" : "no")]"
        }
        return SummaryTranscript(
            text: trimmedText,
            inputLineCount: inputLines.count,
            filteredLineCount: lines.count
        )
    }

    private func noteHumanInputIfNeeded() {
        guard kind == .agent else { return }
        lastHumanInputLine = effectiveAgentContentLineCount()
    }

    private static func shouldDropSummaryLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed.allSatisfy({ "╭╮╰╯─│┌┐└┘═║ ".contains($0) }) {
            return true
        }
        if trimmed.contains("OpenAI Codex")
            || trimmed.contains("/model to change")
            || trimmed.contains("permissions: YOLO mode")
            || trimmed.contains("directory:") && trimmed.contains("~/")
            || trimmed.contains("Tip: Try the Codex App")
            || trimmed.hasPrefix("Tip: NEW:")
            || trimmed.hasPrefix("›")
            || trimmed.contains("gpt-5.") && trimmed.contains("· ~/") {
            return true
        }
        if Self.isMCPStartupWarningLine(trimmed) {
            return true
        }
        if trimmed.contains("@filename") || trimmed.contains("{feature}") {
            return true
        }
        return false
    }

    private static func isMCPStartupWarningLine(_ line: String) -> Bool {
        if line.contains("MCP client for") && line.contains("failed to start") {
            return true
        }
        if line.contains("MCP startup incomplete") {
            return true
        }
        if line.contains("rmcp::transport")
            || line.contains("StreamableHttpClient")
            || line.contains("codex_rmcp_client") {
            return true
        }
        if line.contains("connection closed: initialize response") {
            return true
        }
        if line.contains("/mcp"),
           line.contains("http://127.0.0.1") || line.contains("initialize request") {
            return true
        }
        return false
    }

    private func keyboardProtocolFlagsByApplying(flags: Int, mode: Int) -> Int {
        switch mode {
        case 2:
            keyboardProtocolFlags | flags
        case 3:
            keyboardProtocolFlags & ~flags
        default:
            flags
        }
    }

    private var lineSummary: String {
        let visibleLineCount = max(processor.storedLineCount, 1)
        if let maxScrollback {
            return "\(min(visibleLineCount, maxScrollback))/\(maxScrollback) lines"
        } else {
            return "\(visibleLineCount) lines · unlimited"
        }
    }

    private func bumpRevision() {
        revision &+= 1
    }
}
