import AppKit
import Foundation

private let inputDebugEnabled = ProcessInfo.processInfo.environment["CHERRY_DEBUG_INPUT"] == "1"
private let ptyTraceDirectory = ProcessInfo.processInfo.environment["CHERRY_TRACE_PTY_DIR"]

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

private final class ShellProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var process: ShellProcessController?

    func set(_ process: ShellProcessController?) {
        lock.withLock {
            self.process = process
        }
    }

    func write(_ data: Data) {
        let process = lock.withLock {
            self.process
        }
        process?.write(data)
    }
}

private final class TerminalRawOutputStore: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var data = Data()
    private var observers: [UUID: @Sendable (Data) -> Void] = [:]

    init(maximumBytes: Int = 1_048_576) {
        self.maximumBytes = maximumBytes
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }

        let currentObservers: [@Sendable (Data) -> Void] = lock.withLock {
            data.append(chunk)
            if data.count > maximumBytes {
                data.removeFirst(data.count - maximumBytes)
            }
            return Array(observers.values)
        }

        for observer in currentObservers {
            observer(chunk)
        }
    }

    func observe(replayExistingOutput: Bool, _ observer: @escaping @Sendable (Data) -> Void) -> UUID {
        let id = UUID()
        lock.withLock {
            if replayExistingOutput, !data.isEmpty {
                observer(data)
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

    func snapshot(maxBytes requestedMaxBytes: Int) -> (data: Data, truncated: Bool) {
        lock.withLock {
            let maxBytes = max(0, min(requestedMaxBytes, maximumBytes))
            guard data.count > maxBytes else {
                return (data, false)
            }

            return (data.suffix(maxBytes), true)
        }
    }

    func clear() {
        lock.withLock {
            data.removeAll(keepingCapacity: true)
        }
    }
}

@MainActor
final class TerminalWorkspace: ObservableObject {
    @Published private(set) var sessions: [TerminalSession]
    @Published var selectedSessionID: UUID?

    init() {
        let firstSession = Self.makeSession(index: 1)
        sessions = [firstSession]
        selectedSessionID = firstSession.id
    }

    var selectedSession: TerminalSession? {
        guard let selectedSessionID else { return sessions.first }
        return sessions.first(where: { $0.id == selectedSessionID }) ?? sessions.first
    }

    func select(_ session: TerminalSession) {
        selectedSessionID = session.id
    }

    @discardableResult
    func addSession(
        title: String? = nil,
        workingDirectory: String? = nil,
        command: String? = nil,
        select: Bool = true
    ) -> TerminalSession {
        let session = Self.makeSession(
            index: sessions.count + 1,
            title: title,
            workingDirectory: workingDirectory
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

    func close(_ session: TerminalSession) {
        guard sessions.count > 1 else { return }

        let removedIndex = sessions.firstIndex(where: { $0.id == session.id })
        sessions.removeAll(where: { $0.id == session.id })
        session.stop()

        guard selectedSessionID == session.id else { return }

        if let removedIndex, sessions.indices.contains(removedIndex) {
            selectedSessionID = sessions[removedIndex].id
        } else {
            selectedSessionID = sessions.last?.id
        }
    }

    func selectPreviousSession() {
        selectSession(offset: -1)
    }

    func selectNextSession() {
        selectSession(offset: 1)
    }

    func interruptSelectedSession() {
        selectedSession?.sendInterrupt()
    }

    func restartSelectedSession() {
        selectedSession?.restart()
    }

    func clearSelectedSessionScrollback() {
        selectedSession?.clearScrollback()
    }

    private func selectSession(offset: Int) {
        guard !sessions.isEmpty else { return }

        let currentIndex = selectedSession
            .flatMap { selectedSession in
                sessions.firstIndex(where: { $0.id == selectedSession.id })
            } ?? 0
        let nextIndex = (currentIndex + offset + sessions.count) % sessions.count
        selectedSessionID = sessions[nextIndex].id
    }

    func session(id terminalID: String) -> TerminalSession? {
        guard let uuid = UUID(uuidString: terminalID) else { return nil }
        return sessions.first(where: { $0.id == uuid })
    }

    private static func makeSession(index: Int, title: String? = nil, workingDirectory: String? = nil) -> TerminalSession {
        TerminalSession(
            title: title?.isEmpty == false ? title! : "Shell \(index)",
            subtitle: "\(ShellProcessController.defaultShellName) login shell",
            tint: palette[(index - 1) % palette.count],
            workingDirectory: Self.resolvedWorkingDirectory(workingDirectory)
        )
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
    let title: String
    let subtitle: String
    let tint: NSColor
    let maxScrollback: Int?
    let workingDirectory: String

    @Published private(set) var revision = 0

    private(set) var state: SessionState = .launching
    private let processor: TerminalProcessor
    private let rawOutputStore = TerminalRawOutputStore()
    private var shellProcess: ShellProcessController?
    private var activeLaunchID: UUID?
    private var viewportSize = TerminalViewportSize(columns: 120, rows: 32)
    private var traceRecorder: TerminalTraceRecorder?
    private var outputHoldUntil: Date?
    private var isOutputPausedForInteraction = false
    private var ghosttyBridgeStorage: GhosttySessionBridge?

    private static let defaultMaxScrollback = 50_000
    private static let userScrollOutputHoldInterval: TimeInterval = 0.16

    init(
        title: String,
        subtitle: String,
        tint: NSColor,
        workingDirectory: String = NSHomeDirectory(),
        maxScrollback: Int? = TerminalSession.defaultMaxScrollback,
        buffer: (any TerminalBuffering)? = nil,
        launchShell: Bool = true
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.workingDirectory = workingDirectory
        self.maxScrollback = maxScrollback
        self.processor = TerminalProcessor(maxScrollback: maxScrollback, buffer: buffer)
        self.traceRecorder = TerminalTraceRecorder(sessionID: id, title: title)
        self.processor.setChangeHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleProcessorDidChange()
            }
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

    func send(text: String) {
        guard acceptsInput else { return }
        if inputDebugEnabled {
            fputs("[send text] \(text.debugDescription)\n", stderr)
        }
        shellProcess?.write(text)
    }

    func send(data: Data) {
        guard acceptsInput else { return }
        if inputDebugEnabled {
            let rendered = data.map { String(format: "%02x", $0) }.joined(separator: " ")
            fputs("[send data] \(rendered) shellProcess=\(shellProcess != nil)\n", stderr)
        }
        shellProcess?.write(data)
    }

    func sendInterrupt() {
        guard acceptsInput else { return }
        if inputDebugEnabled {
            fputs("[send interrupt] shellProcess=\(shellProcess != nil)\n", stderr)
        }
        processor.discardPendingOutput()
        shellProcess?.writeUrgent(Data([0x03]))
    }

    func clearScrollback() {
        outputHoldUntil = nil
        resumeOutputIfPausedForInteraction()
        rawOutputStore.clear()
        processor.clear()
        ghosttyBridgeStorage?.reset()
        bumpRevision()
    }

    func restart() {
        stop()
        clearScrollback()
        startShell()
    }

    func stop() {
        let launchID = activeLaunchID
        activeLaunchID = nil
        outputHoldUntil = nil
        processor.endLaunch(launchID)
        resumeOutputIfPausedForInteraction()
        shellProcess?.terminate()
        shellProcess = nil
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
        outputHoldUntil = nil
        processor.beginLaunch(launchID)
        resumeOutputIfPausedForInteraction()
        state = .launching
        bumpRevision()

        do {
            let processor = processor
            let traceRecorder = traceRecorder
            let processBox = ShellProcessBox()
            let process = try ShellProcessController(
                configuration: .init(
                    shellPath: ShellProcessController.defaultShellPath,
                    workingDirectory: workingDirectory,
                    term: "xterm-256color",
                    initialSize: viewportSize
                ),
                onData: { data in
                    traceRecorder?.recordOutput(data)
                    self.rawOutputStore.append(data)
                    processor.enqueueOutput(data, launchID: launchID) { response in
                        processBox.write(response)
                    }
                },
                onExit: { [weak self] status in
                    DispatchQueue.main.async {
                        self?.handleProcessExit(status: status, launchID: launchID)
                    }
                }
            )
            processBox.set(process)
            shellProcess = process

            state = .live
            bumpRevision()
        } catch {
            activeLaunchID = nil
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
        shellProcess = nil
        ghosttyBridgeStorage?.finish(exitCode: UInt32(max(status, 0)))
        outputHoldUntil = nil
        processor.endLaunch(launchID)
        resumeOutputIfPausedForInteraction()
        state = .exited(status)
        processor.appendPlainLines([
            "",
            "[shell exited with status \(status)]"
        ])
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
        if inputDebugEnabled {
            let tailStart = max(0, processor.lineCount - 4)
            let tail = processor.snapshot(range: tailStart..<processor.lineCount)
            fputs("[buffer tail] \(tail.map(\.debugDescription).joined(separator: " | "))\n", stderr)
        }
        if case .launching = state {
            state = .live
        }
        bumpRevision()
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
