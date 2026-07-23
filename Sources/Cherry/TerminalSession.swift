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
    enum BackpressurePolicy {
        case preserveAll
        case dropStalePending(maxPendingBytes: Int)
    }

    private static let changeNotificationInterval: TimeInterval = 1.0 / 30.0
    static let defaultTerminalPendingOutputLimit = 8 * 1024 * 1024
    private static let suspendedDropReportThreshold = 1 * 1024 * 1024

    private let processingQueue = DispatchQueue(label: "Cherry.TerminalProcessor", qos: .userInitiated)
    private let lock = NSLock()
    private let notificationLock = NSLock()
    private let backpressurePolicy: BackpressurePolicy

    private var buffer: any TerminalBuffering
    private var viewportSize = TerminalViewportSize(columns: 120, rows: 32)
    private var activeLaunchID: UUID?
    private var outputEpoch = 0
    private var pendingOutputBytes = 0
    private var needsRawReplayResynchronization = false
    private var isOutputProcessingSuspended = false
    private var unreportedSuspendedDroppedBytes = 0
    private var isChangeNotificationScheduled = false
    private var onDidChange: (@Sendable () -> Void)?

    init(
        maxScrollback: Int?,
        buffer: (any TerminalBuffering)? = nil,
        backpressurePolicy: BackpressurePolicy = .preserveAll
    ) {
        self.buffer = buffer ?? PrototypeTerminalBuffer(maxScrollback: maxScrollback)
        self.backpressurePolicy = backpressurePolicy
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
            pendingOutputBytes = 0
            needsRawReplayResynchronization = true
        }
    }

    func setOutputProcessingSuspended(_ isSuspended: Bool) {
        let droppedPendingBytes = locked {
            let droppedPendingBytes = unreportedSuspendedDroppedBytes
            unreportedSuspendedDroppedBytes = 0
            if droppedPendingBytes > 0 {
                needsRawReplayResynchronization = true
            }
            return droppedPendingBytes
        }
        if droppedPendingBytes > 0 {
            TerminalPerformanceMonitor.recordProcessorBacklogDrop(bytes: droppedPendingBytes)
        }

        locked {
            guard isOutputProcessingSuspended != isSuspended else { return }
            isOutputProcessingSuspended = isSuspended
            outputEpoch &+= 1
            pendingOutputBytes = 0
        }
    }

    func enqueueOutput(
        _ data: Data,
        launchID: UUID?,
        responseWriter: @escaping @Sendable (Data) -> Void
    ) {
        guard !data.isEmpty else { return }

        let (epoch, droppedPendingBytes) = locked { () -> (Int?, Int) in
            if isOutputProcessingSuspended {
                unreportedSuspendedDroppedBytes += data.count
                if unreportedSuspendedDroppedBytes >= Self.suspendedDropReportThreshold {
                    let droppedBytes = unreportedSuspendedDroppedBytes
                    unreportedSuspendedDroppedBytes = 0
                    needsRawReplayResynchronization = true
                    return (nil, droppedBytes)
                }
                return (nil, 0)
            }
            let droppedPendingBytes = applyBackpressureIfNeeded(forIncomingByteCount: data.count)
            pendingOutputBytes += data.count
            return (outputEpoch, droppedPendingBytes)
        }
        if droppedPendingBytes > 0 {
            TerminalPerformanceMonitor.recordProcessorBacklogDrop(bytes: droppedPendingBytes)
        }
        guard let epoch else { return }

        processingQueue.async { [self] in
            defer {
                locked {
                    if outputEpoch == epoch {
                        pendingOutputBytes = max(0, pendingOutputBytes - data.count)
                    }
                }
            }
            processOutput(data, launchID: launchID, expectedEpoch: epoch, responseWriter: responseWriter)
        }
    }

    private func applyBackpressureIfNeeded(forIncomingByteCount byteCount: Int) -> Int {
        guard case .dropStalePending(let maxPendingBytes) = backpressurePolicy,
              pendingOutputBytes > 0,
              pendingOutputBytes + byteCount > maxPendingBytes
        else {
            return 0
        }

        let droppedBytes = pendingOutputBytes
        outputEpoch &+= 1
        pendingOutputBytes = 0
        needsRawReplayResynchronization = true
        buffer.clear()
        return droppedBytes
    }

    var needsReplayResynchronization: Bool {
        locked {
            pendingOutputBytes > 0
                || unreportedSuspendedDroppedBytes > 0
                || needsRawReplayResynchronization
        }
    }

    func replaceWithReplayOutput(_ data: Data, viewportSize: TerminalViewportSize) {
        locked {
            outputEpoch &+= 1
            pendingOutputBytes = 0
            unreportedSuspendedDroppedBytes = 0
            needsRawReplayResynchronization = false
            self.viewportSize = viewportSize
            buffer.clear()
        }

        processOutput(data, launchID: nil, responseWriter: { _ in })
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
    private static let retainedChunkTargetBytes = 64 * 1024

    private let lock = NSLock()
    private let maximumBytes: Int
    private let trimThresholdBytes: Int
    private var chunks: [Data] = []
    private var byteCount = 0
    private var hasDiscardedBytes = false
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

    var chunkCount: Int {
        lock.withLock {
            chunks.count
        }
    }

    var retainedByteCount: Int {
        lock.withLock {
            byteCount
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
            hasDiscardedBytes = false
        }
    }

    private func appendLocked(_ chunk: Data) {
        let retainedChunk: Data
        if chunk.count > maximumBytes {
            retainedChunk = Data(chunk.suffix(maximumBytes))
            hasDiscardedBytes = true
        } else {
            retainedChunk = chunk
        }
        appendRetainedChunkLocked(retainedChunk)
        byteCount += retainedChunk.count

        guard byteCount > trimThresholdBytes else { return }
        trimLocked(to: maximumBytes)
    }

    private func appendRetainedChunkLocked(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        let targetBytes = max(1, min(maximumBytes, Self.retainedChunkTargetBytes))
        if let lastIndex = chunks.indices.last,
           chunks[lastIndex].count + chunk.count <= targetBytes {
            chunks[lastIndex].append(chunk)
        } else {
            chunks.append(chunk)
        }
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
            hasDiscardedBytes = true
        }

        if excessBytes > 0, let first = chunks.first {
            chunks[0] = Data(first.dropFirst(excessBytes))
            byteCount -= excessBytes
            hasDiscardedBytes = true
        }

        if chunks.isEmpty {
            byteCount = 0
        }
    }

    private func snapshotLocked(maxBytes: Int) -> (data: Data, truncated: Bool) {
        guard maxBytes > 0, byteCount > 0 else {
            return (Data(), hasDiscardedBytes || byteCount > 0)
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
        return (output, hasDiscardedBytes || byteCount > maxBytes)
    }
}

private enum TerminalMetadataEvent: Equatable {
    case title(String)
    case workingDirectory(String)
    case resolvedCommandLine(String)
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

    func reset() {
        state = .ground
        controlBuffer.removeAll(keepingCapacity: true)
    }

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
            if let event = cherryCommandEvent(from: value) {
                return event
            }
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

    private static func cherryCommandEvent(from value: String) -> TerminalMetadataEvent? {
        let prefix = "cherry-command;"
        guard value.hasPrefix(prefix) else { return nil }

        let command = sanitized(String(value.dropFirst(prefix.count))).nilIfEmpty
        return command.map(TerminalMetadataEvent.resolvedCommandLine)
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

enum TerminalDisplayItem: Identifiable, Equatable {
    case single(UUID)
    case split(UUID)

    var id: UUID {
        switch self {
        case .single(let sessionID), .split(let sessionID):
            sessionID
        }
    }
}

struct TerminalSplitGroup: Identifiable, Equatable {
    let id: UUID
    var paneSessionIDs: [UUID]
    var activeSessionID: UUID
    var widthWeights: [Double]

    init(
        id: UUID = UUID(),
        paneSessionIDs: [UUID],
        activeSessionID: UUID,
        widthWeights: [Double]? = nil
    ) {
        self.id = id
        self.paneSessionIDs = paneSessionIDs
        self.activeSessionID = activeSessionID
        self.widthWeights = widthWeights ?? Self.balancedWeights(count: paneSessionIDs.count)
    }

    static func balancedWeights(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        return Array(repeating: 1 / Double(count), count: count)
    }
}

@MainActor
final class TerminalWorkspace: ObservableObject {
    @Published private(set) var sessions: [TerminalSession]
    @Published private(set) var terminalDisplayItems: [TerminalDisplayItem]
    @Published private(set) var terminalSplitGroups: [TerminalSplitGroup] = []
    @Published private(set) var terminalDetailWidth: CGFloat = 0
    @Published var selectedSessionID: UUID? {
        didSet {
            updateAuxiliaryProcessingForSelection(previousSelectedSessionID: oldValue)
            clearUnreadNotificationForSelectedSession()
        }
    }
    let projectRoot: String?

    init(projectRoot: String? = nil, createInitialSession: Bool = true) {
        self.projectRoot = projectRoot.map(Self.resolvedWorkingDirectory)
        guard createInitialSession else {
            sessions = []
            terminalDisplayItems = []
            selectedSessionID = nil
            return
        }
        let firstSession = Self.makeSession(index: 1, workingDirectory: self.projectRoot, projectRoot: self.projectRoot)
        sessions = [firstSession]
        terminalDisplayItems = [.single(firstSession.id)]
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

    func scheduleHiddenAgentSummaries() {
        agentSessions.forEach { $0.scheduleSummaryWhenHiddenIfNeeded() }
    }

    /// Sessions currently running a process across every kind — broader than
    /// `runningAgentSessions` (adds live commands and terminals executing a
    /// foreground program). A method, not a computed var: for terminals it probes
    /// the process table, so it must never be read from a SwiftUI body.
    func sessionsWithRunningProcess() -> [TerminalSession] {
        sessions.filter { $0.hasRunningProcess() }
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

    var terminalDisplaySessions: [TerminalSession] {
        terminalDisplayItems.compactMap { displayItem in
            switch displayItem {
            case .single(let sessionID):
                sessions.first { $0.id == sessionID }
            case .split(let groupID):
                terminalSplitGroups.first { $0.id == groupID }
                    .flatMap { group in sessions.first { $0.id == group.activeSessionID } }
            }
        }
    }

    var visibleTerminalSessionIDs: Set<UUID> {
        Set(terminalDisplayItems.flatMap { displayItem in
            switch displayItem {
            case .single(let sessionID):
                [sessionID]
            case .split(let groupID):
                terminalSplitGroups.first { $0.id == groupID }?.paneSessionIDs ?? []
            }
        })
    }

    var commandSessions: [TerminalSession] {
        sessions.filter { $0.kind == .command }
    }

    var sidebarOrderedSessions: [TerminalSession] {
        visibleAgentSessions() + terminalDisplaySessions + commandSessions
    }

    func sidebarOrderedSessions(visibleCommandNames: [String]) -> [TerminalSession] {
        visibleAgentSessions() + terminalDisplaySessions + commandSessions(orderedBy: visibleCommandNames)
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
        if let groupIndex = terminalSplitGroups.firstIndex(where: { $0.paneSessionIDs.contains(session.id) }) {
            terminalSplitGroups[groupIndex].activeSessionID = session.id
        }
        selectedSessionID = session.id
    }

    private func updateAuxiliaryProcessingForSelection(previousSelectedSessionID: UUID?) {
        guard previousSelectedSessionID != selectedSessionID else {
            selectedSession?.setAuxiliaryProcessingActive(true)
            return
        }

        if let previousSelectedSessionID,
           let previousSession = sessions.first(where: { $0.id == previousSelectedSessionID }) {
            previousSession.setAuxiliaryProcessingActive(false)
            previousSession.scheduleSummaryWhenHiddenIfNeeded()
        }

        selectedSession?.setAuxiliaryProcessingActive(true)
    }

    func moveSession(id sessionID: UUID, to targetIndex: Int) {
        guard let currentIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return }

        let clampedIndex = min(max(targetIndex, 0), sessions.count - 1)
        guard currentIndex != clampedIndex else { return }

        let session = sessions.remove(at: currentIndex)
        sessions.insert(session, at: clampedIndex)
    }

    func moveSession(id sessionID: UUID, to targetIndex: Int, within kind: TerminalSession.SessionKind) {
        if kind == .terminal {
            moveTerminalDisplayItem(containing: sessionID, to: targetIndex)
            return
        }

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

    func moveTerminalDisplayItem(containing sessionID: UUID, to targetIndex: Int) {
        guard let currentIndex = terminalDisplayItems.firstIndex(where: { displayItemContains($0, sessionID: sessionID) }) else {
            return
        }

        moveTerminalDisplayItem(at: currentIndex, to: targetIndex)
    }

    func moveTerminalDisplayItem(id displayItemID: UUID, to targetIndex: Int) {
        guard let currentIndex = terminalDisplayItems.firstIndex(where: { $0.id == displayItemID }) else {
            return
        }

        moveTerminalDisplayItem(at: currentIndex, to: targetIndex)
    }

    private func moveTerminalDisplayItem(at currentIndex: Int, to targetIndex: Int) {
        let clampedIndex = min(max(targetIndex, 0), terminalDisplayItems.count - 1)
        guard currentIndex != clampedIndex else { return }

        let item = terminalDisplayItems.remove(at: currentIndex)
        terminalDisplayItems.insert(item, at: clampedIndex)
    }

    @discardableResult
    func addSession(
        title: String? = nil,
        workingDirectory: String? = nil,
        command: String? = nil,
        select: Bool = true,
        displayAsStandalone: Bool = true
    ) -> TerminalSession {
        // Match Ghostty's new-surface behavior: when no cwd is requested,
        // inherit the selected session's last trusted OSC 7 cwd report. In an
        // empty workspace (worktree spaces start with no sessions) fall back
        // to the project root rather than the process home directory.
        let resolvedWorkingDirectory = workingDirectory
            ?? selectedSession?.workingDirectory
            ?? projectRoot
        let session = Self.makeSession(
            index: sessions.count + 1,
            title: title,
            workingDirectory: resolvedWorkingDirectory,
            projectRoot: projectRoot
        )
        sessions.append(session)
        if displayAsStandalone {
            terminalDisplayItems.append(.single(session.id))
        }
        if select {
            self.select(session)
        } else {
            session.scheduleAuxiliaryProcessingSuspensionAfterStartupGrace()
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
            self.select(session)
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
                self.select(session)
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
            self.select(session)
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

    func splitGroup(id groupID: UUID) -> TerminalSplitGroup? {
        terminalSplitGroups.first { $0.id == groupID }
    }

    func splitGroup(containing sessionID: UUID) -> TerminalSplitGroup? {
        terminalSplitGroups.first { $0.paneSessionIDs.contains(sessionID) }
    }

    func sessions(for displayItem: TerminalDisplayItem) -> [TerminalSession] {
        switch displayItem {
        case .single(let sessionID):
            return sessions.first { $0.id == sessionID }.map { [$0] } ?? []
        case .split(let groupID):
            guard let group = splitGroup(id: groupID) else { return [] }
            return group.paneSessionIDs.compactMap { paneID in
                sessions.first { $0.id == paneID }
            }
        }
    }

    func activeSession(for displayItem: TerminalDisplayItem) -> TerminalSession? {
        switch displayItem {
        case .single(let sessionID):
            return sessions.first { $0.id == sessionID }
        case .split(let groupID):
            guard let group = splitGroup(id: groupID) else { return nil }
            return sessions.first { $0.id == group.activeSessionID }
        }
    }

    func canAddSplitPane(to sessionID: UUID) -> Bool {
        guard session(withID: sessionID)?.kind == .terminal else { return false }
        guard let group = splitGroup(containing: sessionID) else { return true }
        guard group.paneSessionIDs.count < Self.maximumSplitPaneCount else { return false }
        let nextPaneCount = group.paneSessionIDs.count + 1
        guard nextPaneCount >= Self.maximumSplitPaneCount, terminalDetailWidth > 0 else { return true }
        return terminalDetailWidth >= CGFloat(nextPaneCount) * Self.minimumSplitPaneWidth
    }

    func updateTerminalDetailWidth(_ width: CGFloat) {
        let clampedWidth = max(0, width)
        guard abs(terminalDetailWidth - clampedWidth) > 1 else { return }
        terminalDetailWidth = clampedWidth
    }

    @discardableResult
    func splitDuplicateActiveTerminal() -> TerminalSession? {
        guard let activeSession = selectedSession,
              activeSession.kind == .terminal,
              canAddSplitPane(to: activeSession.id)
        else {
            return nil
        }

        let session = addSession(
            workingDirectory: activeSession.workingDirectory,
            select: false,
            displayAsStandalone: false
        )
        guard addTerminalPane(session.id, after: activeSession.id) else {
            closeSessions(withIDs: Set([session.id]))
            return nil
        }
        select(session)
        return session
    }

    @discardableResult
    func splitActiveTerminal(with session: TerminalSession) -> Bool {
        guard terminalDisplayItems.contains(where: { $0 == .single(session.id) }),
              splitGroup(containing: session.id) == nil,
              let activeSession = selectedSession,
              activeSession.id != session.id,
              activeSession.kind == .terminal,
              session.kind == .terminal,
              canAddSplitPane(to: activeSession.id)
        else {
            return false
        }

        guard addTerminalPane(session.id, after: activeSession.id) else {
            return false
        }
        select(session)
        return true
    }

    @discardableResult
    func focusPreviousPane() -> Bool {
        focusPane(offset: -1)
    }

    @discardableResult
    func focusNextPane() -> Bool {
        focusPane(offset: 1)
    }

    func balanceSplitGroup(id groupID: UUID) {
        guard let groupIndex = terminalSplitGroups.firstIndex(where: { $0.id == groupID }) else { return }
        terminalSplitGroups[groupIndex].widthWeights = TerminalSplitGroup.balancedWeights(
            count: terminalSplitGroups[groupIndex].paneSessionIDs.count
        )
    }

    func balanceActiveSplitGroup() {
        guard let selectedSessionID,
              let group = splitGroup(containing: selectedSessionID)
        else {
            return
        }
        balanceSplitGroup(id: group.id)
    }

    func setSplitGroupWidthWeights(id groupID: UUID, weights: [Double]) {
        guard let groupIndex = terminalSplitGroups.firstIndex(where: { $0.id == groupID }),
              let normalizedWeights = Self.normalizedWidthWeights(
                weights,
                count: terminalSplitGroups[groupIndex].paneSessionIDs.count
              )
        else {
            return
        }

        terminalSplitGroups[groupIndex].widthWeights = normalizedWeights
    }

    func separateSplitGroup(id groupID: UUID) {
        guard let groupIndex = terminalSplitGroups.firstIndex(where: { $0.id == groupID }),
              let displayIndex = terminalDisplayItems.firstIndex(where: { $0 == .split(groupID) })
        else {
            return
        }

        let group = terminalSplitGroups.remove(at: groupIndex)
        terminalDisplayItems.replaceSubrange(
            displayIndex...displayIndex,
            with: group.paneSessionIDs.map { .single($0) }
        )
    }

    func separateActiveSplitGroup() {
        guard let selectedSessionID,
              let group = splitGroup(containing: selectedSessionID)
        else {
            return
        }
        separateSplitGroup(id: group.id)
    }

    func canCloseSplitGroup(id groupID: UUID) -> Bool {
        guard let group = splitGroup(id: groupID) else { return false }
        return sessions.count > group.paneSessionIDs.count
    }

    func closeSplitGroup(id groupID: UUID) {
        guard let group = splitGroup(id: groupID),
              canCloseSplitGroup(id: groupID)
        else {
            return
        }
        closeSessions(withIDs: Set(group.paneSessionIDs))
    }

    func close(_ session: TerminalSession, allowEmptyWorkspace: Bool = false) {
        if session.kind == .agent {
            promoteChildAgents(of: session)
        }
        closeSessions(
            withIDs: Set([session.id]),
            replacementSelectionID: replacementPaneSelection(afterClosing: session.id),
            allowEmptyWorkspace: allowEmptyWorkspace
        )
    }

    func closeAgentGroup(_ session: TerminalSession, allowEmptyWorkspace: Bool = false) {
        let groupIDs = Set(([session] + descendantAgentSessions(of: session)).map(\.id))
        closeSessions(withIDs: groupIDs, allowEmptyWorkspace: allowEmptyWorkspace)
    }

    func closeAgentPromotingChildren(_ session: TerminalSession) {
        promoteChildAgents(of: session)
        closeSessions(withIDs: Set([session.id]))
    }

    func closeAllSessions() {
        let removedSessions = sessions
        sessions.removeAll()
        terminalDisplayItems.removeAll()
        terminalSplitGroups.removeAll()
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

    func closeActivePane() {
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
        select(orderedSessions[nextIndex])
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

    func session(withID sessionID: UUID) -> TerminalSession? {
        sessions.first { $0.id == sessionID }
    }

    static let minimumSplitPaneWidth: CGFloat = 280
    private static let maximumSplitPaneCount = 3

    private func displayItemContains(_ item: TerminalDisplayItem, sessionID: UUID) -> Bool {
        switch item {
        case .single(let itemSessionID):
            itemSessionID == sessionID
        case .split(let groupID):
            splitGroup(id: groupID)?.paneSessionIDs.contains(sessionID) == true
        }
    }

    private func addTerminalPane(_ paneSessionID: UUID, after activeSessionID: UUID) -> Bool {
        guard paneSessionID != activeSessionID,
              session(withID: paneSessionID)?.kind == .terminal,
              session(withID: activeSessionID)?.kind == .terminal,
              splitGroup(containing: paneSessionID) == nil
        else {
            return false
        }

        if let groupIndex = terminalSplitGroups.firstIndex(where: { $0.paneSessionIDs.contains(activeSessionID) }) {
            guard terminalSplitGroups[groupIndex].paneSessionIDs.count < Self.maximumSplitPaneCount,
                  let activePaneIndex = terminalSplitGroups[groupIndex].paneSessionIDs.firstIndex(of: activeSessionID)
            else {
                return false
            }

            removeStandaloneTerminalDisplayItem(sessionID: paneSessionID)
            terminalSplitGroups[groupIndex].paneSessionIDs.insert(paneSessionID, at: activePaneIndex + 1)
            terminalSplitGroups[groupIndex].activeSessionID = paneSessionID
            terminalSplitGroups[groupIndex].widthWeights = TerminalSplitGroup.balancedWeights(
                count: terminalSplitGroups[groupIndex].paneSessionIDs.count
            )
            return true
        }

        removeStandaloneTerminalDisplayItem(sessionID: paneSessionID)
        guard let activeDisplayIndex = terminalDisplayItems.firstIndex(where: { $0 == .single(activeSessionID) }) else {
            return false
        }

        let group = TerminalSplitGroup(
            paneSessionIDs: [activeSessionID, paneSessionID],
            activeSessionID: paneSessionID
        )
        terminalSplitGroups.append(group)
        terminalDisplayItems[activeDisplayIndex] = .split(group.id)
        return true
    }

    private func removeStandaloneTerminalDisplayItem(sessionID: UUID) {
        terminalDisplayItems.removeAll { $0 == .single(sessionID) }
    }

    private func focusPane(offset: Int) -> Bool {
        guard let selectedSessionID,
              let group = splitGroup(containing: selectedSessionID),
              let currentIndex = group.paneSessionIDs.firstIndex(of: selectedSessionID),
              group.paneSessionIDs.count > 1
        else {
            return false
        }

        let nextIndex = (currentIndex + offset + group.paneSessionIDs.count) % group.paneSessionIDs.count
        guard let session = session(withID: group.paneSessionIDs[nextIndex]) else { return false }
        select(session)
        return true
    }

    private func replacementPaneSelection(afterClosing sessionID: UUID) -> UUID? {
        guard let group = splitGroup(containing: sessionID),
              group.activeSessionID == sessionID,
              let currentIndex = group.paneSessionIDs.firstIndex(of: sessionID),
              group.paneSessionIDs.count > 1
        else {
            return nil
        }

        if currentIndex > 0 {
            return group.paneSessionIDs[currentIndex - 1]
        }
        return group.paneSessionIDs[1]
    }

    private static func normalizedWidthWeights(_ weights: [Double], count: Int) -> [Double]? {
        guard count > 0, weights.count == count else { return nil }
        let sanitized = weights.map { weight in
            weight.isFinite ? max(weight, 0.01) : 0.01
        }
        let total = sanitized.reduce(0, +)
        guard total > 0 else { return TerminalSplitGroup.balancedWeights(count: count) }
        return sanitized.map { $0 / total }
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

    private func closeSessions(
        withIDs removedIDs: Set<UUID>,
        replacementSelectionID: UUID? = nil,
        allowEmptyWorkspace: Bool = false
    ) {
        guard !removedIDs.isEmpty,
              allowEmptyWorkspace || sessions.count > removedIDs.count
        else {
            return
        }

        let removedIndex = sessions.firstIndex { removedIDs.contains($0.id) }
        let removedSessions = sessions.filter { removedIDs.contains($0.id) }
        sessions.removeAll { removedIDs.contains($0.id) }
        removeClosedSessionsFromTerminalDisplay(removedIDs)
        removedSessions.forEach { session in
            session.releaseGhosttyBridge()
            session.stop()
        }

        guard let currentSelectedSessionID = selectedSessionID,
              removedIDs.contains(currentSelectedSessionID)
        else { return }

        if let replacementSelectionID,
           let replacementSession = session(withID: replacementSelectionID) {
            select(replacementSession)
            return
        }

        if let removedIndex, sessions.indices.contains(removedIndex) {
            select(sessions[removedIndex])
        } else {
            if let session = sessions.last {
                select(session)
            } else {
                selectedSessionID = nil
            }
        }
    }

    private func removeClosedSessionsFromTerminalDisplay(_ removedIDs: Set<UUID>) {
        guard !removedIDs.isEmpty else { return }

        var updatedGroups: [TerminalSplitGroup] = []
        var groupByID: [UUID: TerminalSplitGroup] = [:]

        for group in terminalSplitGroups {
            var filteredPaneIDs: [UUID] = []
            var filteredWeights: [Double] = []
            for (index, paneID) in group.paneSessionIDs.enumerated() where !removedIDs.contains(paneID) {
                filteredPaneIDs.append(paneID)
                if group.widthWeights.indices.contains(index) {
                    filteredWeights.append(group.widthWeights[index])
                }
            }

            guard filteredPaneIDs.count >= 2 else { continue }

            let activeSessionID = filteredPaneIDs.contains(group.activeSessionID)
                ? group.activeSessionID
                : filteredPaneIDs[0]
            let widthWeights = Self.normalizedWidthWeights(filteredWeights, count: filteredPaneIDs.count)
                ?? TerminalSplitGroup.balancedWeights(count: filteredPaneIDs.count)
            let updatedGroup = TerminalSplitGroup(
                id: group.id,
                paneSessionIDs: filteredPaneIDs,
                activeSessionID: activeSessionID,
                widthWeights: widthWeights
            )
            updatedGroups.append(updatedGroup)
            groupByID[group.id] = updatedGroup
        }

        let previousGroupsByID = Dictionary(uniqueKeysWithValues: terminalSplitGroups.map { ($0.id, $0) })
        terminalSplitGroups = updatedGroups

        terminalDisplayItems = terminalDisplayItems.compactMap { item in
            switch item {
            case .single(let sessionID):
                return removedIDs.contains(sessionID) ? nil : item
            case .split(let groupID):
                if let updatedGroup = groupByID[groupID] {
                    return .split(updatedGroup.id)
                }
                guard let previousGroup = previousGroupsByID[groupID] else { return nil }
                let remainingPaneIDs = previousGroup.paneSessionIDs.filter { !removedIDs.contains($0) }
                if remainingPaneIDs.count == 1 {
                    return .single(remainingPaneIDs[0])
                }
                return nil
            }
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
    @Published private(set) var resolvedCommandLine: String?
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
    /// True when auto-restart gave up on a crash-looping command (see
    /// `CommandAutoRestartPolicy`); cleared by a manual restart.
    @Published private(set) var isAutoRestartPaused = false
    private var pendingAutoRestart: DispatchWorkItem?
    private var consecutiveRapidExitCount = 0
    private var systemTitle: String
    private var automaticTitle: String?
    private var pendingResolvedCommandLine: String?
    private let summaryRunner: AgentSummaryRun
    private let summaryVisibilityProvider: @MainActor (TerminalSession) -> Bool

    @Published private(set) var revision = 0

    private let processor: TerminalProcessor
    private let rawOutputStore = TerminalRawOutputStore()
    private let metadataParser = TerminalMetadataParser()
    private let metadataOutputLock = NSLock()

    // Native-PTY (EXEC) content model: under EXEC the surface owns the terminal
    // state, so these mirror what the processor holds in the host path, refreshed
    // from `ghostty_surface_read_text` on a debounced render signal.
    private static let nativeContentDebounceInterval: TimeInterval = 0.12
    private static let nativeContentReadThrottle: TimeInterval = 0.05
    private var nativeContentLines: [String] = []
    private var isRefreshingNativeContent = false
    private var nativeContentHash = 0
    private var nativeContentRefreshScheduled = false
    private var lastNativeContentReadAt: Date?
    /// OSC 133 command-end signal (native). A precise "back at prompt / command
    /// done" marker for non-TUI commands; published so idle detection can use it.
    @Published private(set) var lastNativeCommandFinishedAt: Date?
    private(set) var lastNativeCommandExitCode: Int32?
    let hostInputWriter = TerminalInputWriter()
    private var shellProcess: ShellProcessController?
    private var activeLaunchID: UUID?
    private var viewportSize = TerminalViewportSize(columns: 120, rows: 32)
    private var traceRecorder: TerminalTraceRecorder?
    private let attentionObservationDirectoryProvider: @MainActor () -> URL?
    private var attentionObservationRecorder: TerminalAttentionObservationRecorder?
    private var attentionObservationTask: Task<Void, Never>?
    private var outputHoldUntil: Date?
    private var isOutputPausedForInteraction = false
    private var isOutputPausedForBackgroundThrottle = false
    private var backgroundOutputThrottleTask: Task<Void, Never>?
    private var backgroundOutputBytesSinceThrottle = 0
    private var keyboardProtocolFlagStack: [Int] = []
    private var ghosttyBridgeStorage: GhosttySessionBridge?
    private var renderedReplayCache: RenderedReplayCache?
    private var summaryDebounceTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var summaryGeneration = 0
    private var lastSummaryOutputChangeDate: Date?
    private var lastSummaryInput: String?
    private var lastSummaryDate: Date?
    private var lastHumanInputLine: Int?
    private var lastHumanInputAt: Date?
    private var humanInputGeneration = 0
    private var agentActivitySource: AgentActivitySource = .none
    private var titleIndicatesAgentWorking = false
    private var lastTitleSpinnerAt: Date?
    private var lastStrongWorkingEvidenceAt: Date?
    private var agentIdleConfirmationTask: Task<Void, Never>?
    private var agentIdleRecheckTask: Task<Void, Never>?
    private var auxiliaryProcessingSuspensionTask: Task<Void, Never>?
    private var lastContentFingerprint: Int?
    private var pendingMetadataOutput = Data()
    private var hasPendingOutputActivity = false
    private var isMetadataOutputFlushScheduled = false
    private var shouldResetMetadataParserBeforeFlush = false
    private var isAuxiliaryProcessingActive = true

    enum AgentActivitySource {
        case none
        case summary
        case outputActivity
        case inputSubmit
        // Idle inferred purely from a quiet content window (no prompt/marker/spinner
        // to key off) — weak evidence, so fresh output flips straight back to working.
        case quietWindow
        case promptMarker
        case workingMarker
        case titleSpinner
        case notification
        case processExit
    }

    private struct RenderedReplayCache {
        let outputVersion: Int
        let viewportSize: TerminalViewportSize
        let maxBytes: Int
        let maxLines: Int
        let output: Data
    }

    private static let defaultMaxScrollback = 50_000
    private static let auxiliaryTerminalProcessorMaxScrollback = 4_096
    private static let auxiliaryTerminalProcessorReplayByteLimit = 1_048_576
    private static let auxiliaryTerminalProcessorStartupGrace: TimeInterval = 3.0
    private static let metadataOutputPendingByteLimit = 512 * 1024
    private static let metadataOutputFlushInterval: TimeInterval = 0.2
    private static let backgroundOutputThrottleByteInterval = 256 * 1024
    private static let backgroundOutputThrottleDuration: TimeInterval = 0.5
    private static let userScrollOutputHoldInterval: TimeInterval = 0.16
    private static let agentIdleConfirmationEvidenceWindow: TimeInterval = 1.0
    private static let agentIdleConfirmationDelay: TimeInterval = 0.4
    private static let agentIdleRecheckQuietInterval: TimeInterval = 4.0
    private static let attentionObservationInterval: TimeInterval = 1.0
    private static let attentionObservationMaximumRows = 200
    private static let attentionObservationMaximumColumns = 512
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
        },
        summaryVisibilityProvider: @escaping @MainActor (TerminalSession) -> Bool = {
            ProjectWindowRegistry.shared.isSessionVisible($0)
        },
        attentionObservationDirectoryProvider: @escaping @MainActor () -> URL? = {
            TerminalAttentionObservationRecorder.configuredDirectoryURL
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
        self.summaryVisibilityProvider = summaryVisibilityProvider
        self.attentionObservationDirectoryProvider = attentionObservationDirectoryProvider
        self.systemTitle = title
        let processorMaxScrollback = Self.processorMaxScrollback(for: kind, configuredMaxScrollback: maxScrollback)
        let processorBuffer = buffer ?? (launchShell && !fullPrototypeProcessorEnabled
            ? LiveTerminalOutputBuffer(maxScrollback: processorMaxScrollback)
            : nil)
        let processorBackpressurePolicy: TerminalProcessor.BackpressurePolicy = kind == .terminal
            ? .dropStalePending(maxPendingBytes: TerminalProcessor.defaultTerminalPendingOutputLimit)
            : .preserveAll
        self.processor = TerminalProcessor(
            maxScrollback: processorMaxScrollback,
            buffer: processorBuffer,
            backpressurePolicy: processorBackpressurePolicy
        )
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

    private static func processorMaxScrollback(
        for kind: SessionKind,
        configuredMaxScrollback: Int?
    ) -> Int? {
        guard kind == .terminal else { return configuredMaxScrollback }
        return min(
            max(0, configuredMaxScrollback ?? auxiliaryTerminalProcessorMaxScrollback),
            auxiliaryTerminalProcessorMaxScrollback
        )
    }

    func scheduleAuxiliaryProcessingSuspensionAfterStartupGrace() {
        setAuxiliaryProcessingActive(false, suspensionDelay: Self.auxiliaryTerminalProcessorStartupGrace)
    }

    func setAuxiliaryProcessingActive(_ isActive: Bool, suspensionDelay: TimeInterval = 0) {
        guard kind == .terminal else { return }
        auxiliaryProcessingSuspensionTask?.cancel()
        auxiliaryProcessingSuspensionTask = nil

        if !isActive, suspensionDelay > 0 {
            auxiliaryProcessingSuspensionTask = Task { [weak self] in
                let nanoseconds = UInt64(suspensionDelay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.setAuxiliaryProcessingActive(false)
                }
            }
            return
        }

        guard isAuxiliaryProcessingActive != isActive else { return }

        isAuxiliaryProcessingActive = isActive
        processor.setOutputProcessingSuspended(!isActive)

        if isActive {
            cancelBackgroundOutputThrottle()
        } else {
            backgroundOutputBytesSinceThrottle = 0
        }

        guard isActive else { return }

        processor.clear()
        let replay = rawOutputStore.snapshot(maxBytes: Self.auxiliaryTerminalProcessorReplayByteLimit).data
        guard !replay.isEmpty else { return }

        ingestTerminalMetadata(replay)
        guard !prototypeProcessorDisabledForPerf else { return }
        processor.enqueueOutput(replay, launchID: activeLaunchID, responseWriter: { _ in })
    }

    private func noteProcessOutputForBackgroundThrottle(bytes: Int) {
        guard kind == .terminal,
              !isAuxiliaryProcessingActive,
              bytes > 0,
              !isOutputPausedForBackgroundThrottle
        else {
            return
        }

        backgroundOutputBytesSinceThrottle += bytes
        guard backgroundOutputBytesSinceThrottle >= Self.backgroundOutputThrottleByteInterval else { return }
        backgroundOutputBytesSinceThrottle = 0
        isOutputPausedForBackgroundThrottle = true
        TerminalPerformanceMonitor.recordBackgroundOutputThrottle()
        updateShellOutputPauseState()

        backgroundOutputThrottleTask?.cancel()
        backgroundOutputThrottleTask = Task { [weak self] in
            let nanoseconds = UInt64(Self.backgroundOutputThrottleDuration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.isOutputPausedForBackgroundThrottle = false
                self.updateShellOutputPauseState()
            }
        }
    }

    private func cancelBackgroundOutputThrottle() {
        backgroundOutputThrottleTask?.cancel()
        backgroundOutputThrottleTask = nil
        isOutputPausedForBackgroundThrottle = false
        backgroundOutputBytesSinceThrottle = 0
        updateShellOutputPauseState()
    }

    private func updateShellOutputPauseState() {
        if isOutputPausedForInteraction || isOutputPausedForBackgroundThrottle {
            shellProcess?.pauseOutput()
        } else {
            shellProcess?.resumeOutput()
        }
    }

    var lineCount: Int {
        contentLineCount()
    }

    /// Like `lineCount` but never triggers a native content refresh — for hot paths
    /// like process listings that poll many sessions. The render signal keeps the
    /// native line model current; this just reads it.
    var listingLineCount: Int {
        GhosttySessionBridge.nativePTYEnabled && ghosttyBridgeStorage != nil
            ? nativeContentLines.count
            : processor.lineCount
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

    /// Whether closing this session would tear down a live program the user might
    /// care about — drives the close/quit confirmation. A command or agent pane IS
    /// its process, so any live one counts. A plain terminal only counts when its
    /// shell is actually running a child program (not sitting idle at the prompt),
    /// mirroring how ghostty and other terminals decide whether to confirm.
    ///
    /// Product intent is to eventually narrow this back to running agents only; at
    /// that point the body becomes `kind == .agent && isRunning`.
    func hasRunningProcess() -> Bool {
        guard isRunning else { return false }
        switch kind {
        case .command, .agent:
            return true
        case .terminal:
            guard let shellPID = childProcessID
                ?? ShellProcessController.readNativeShellPID(processID: id.uuidString)
            else {
                return false
            }
            return ShellProcessController.shellHasChildProcess(shellPID: shellPID)
        }
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
        contentSnapshot(range: range)
    }

    func styledSnapshot(range: Range<Int>) -> [TerminalRenderedLine] {
        processor.styledSnapshot(range: range)
    }

    func cachedRenderedReplayOutput(maxBytes: Int, maxLines: Int) -> Data? {
        guard let renderedReplayCache,
              renderedReplayCache.outputVersion == outputVersion,
              renderedReplayCache.viewportSize == viewportSize,
              renderedReplayCache.maxBytes == maxBytes,
              renderedReplayCache.maxLines == maxLines
        else {
            return nil
        }

        return renderedReplayCache.output
    }

    func synchronizeReplayModelIfNeededForRenderedReplay() {
        guard kind == .terminal,
              processor.needsReplayResynchronization
        else {
            return
        }

        let replay = rawOutputStore.snapshot(maxBytes: Self.auxiliaryTerminalProcessorReplayByteLimit).data
        guard !replay.isEmpty else { return }

        renderedReplayCache = nil
        ingestTerminalMetadata(replay)
        processor.replaceWithReplayOutput(replay, viewportSize: viewportSize)
    }

    func cacheRenderedReplayOutput(_ output: Data, maxBytes: Int, maxLines: Int) {
        renderedReplayCache = RenderedReplayCache(
            outputVersion: outputVersion,
            viewportSize: viewportSize,
            maxBytes: maxBytes,
            maxLines: maxLines,
            output: output
        )
    }

    var replayViewportSize: TerminalViewportSize {
        viewportSize
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
        if GhosttySessionBridge.nativePTYEnabled {
            ghosttyBridgeStorage?.sendNativeInput(data)
            return
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
        if GhosttySessionBridge.nativePTYEnabled {
            ghosttyBridgeStorage?.sendNativeInput(outboundData)
            return
        }
        shellProcess?.write(outboundData)
    }

    func sendInterrupt() {
        guard acceptsInput else { return }
        if inputDebugEnabled {
            fputs("[send interrupt] shellProcess=\(shellProcess != nil)\n", stderr)
        }
        processor.discardPendingOutput()
        if GhosttySessionBridge.nativePTYEnabled {
            ghosttyBridgeStorage?.sendNativeInput(Data([0x03]))
            return
        }
        shellProcess?.writeUrgent(Data([0x03]))
    }

    func noteNativeHostInput(event: NSEvent?) {
        noteInputOutputBaseline()
        guard kind == .agent, Self.appKitKeyEventSubmitsAgentTurn(event) else { return }
        noteHumanInputIfNeeded()
        setAgentActivityState(.working, source: .inputSubmit)
        scheduleAgentIdleRecheck()
        scheduleAttentionObservation(event: .inputSubmitted)
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
        renderedReplayCache = nil
        rawOutputStore.clear()
        if preservingTerminalState {
            processor.clearScreenAndScrollbackPreservingTerminalState()
            ghosttyBridgeStorage?.clearScreenAndScrollback()
        } else {
            processor.clear()
            ghosttyBridgeStorage?.reset()
        }
        lastHumanInputLine = nil
        lastHumanInputAt = nil
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
        resetAutoRestartPolicy()
        stop()
        clearScrollback(preservingTerminalState: false)
        startShell()
    }

    func restartManagedCommandIfNeeded() {
        guard kind == .command else { return }
        resetAutoRestartPolicy()

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
        title nextTitle: String? = nil,
        useAsTitle: Bool,
        agentActivityState nextAgentActivityState: AgentActivityState? = nil
    ) {
        let sanitized = sanitizedSummary(nextSummary).nilIfEmpty
        let generatedTitle = sanitizedAgentTitle(nextTitle) ?? (kind == .agent ? nil : sanitized)
        var didChange = false

        if summary != sanitized {
            summary = sanitized
            didChange = true
        }

        if useAsTitle, let generatedTitle {
            if automaticTitle != generatedTitle,
               (titleSource != .explicit || kind == .agent) {
                automaticTitle = generatedTitle
                didChange = true
            }
            if titleSource != .explicit,
               title != generatedTitle || titleSource != .automatic {
                title = generatedTitle
                titleSource = .automatic
                didChange = true
            }
        }

        if kind == .agent, let nextAgentActivityState {
            if applySummaryActivityState(nextAgentActivityState) {
                didChange = true
            }
        }

        guard didChange else { return }
        bumpRevision()
    }

    func clearAutomaticSummaryTitle() {
        automaticTitle = nil
        guard titleSource == .automatic else { return }
        title = systemTitle
        titleSource = .system
        bumpRevision()
    }

    func scheduleSummaryWhenHiddenIfNeeded() {
        scheduleSummaryIfNeeded()
    }

    func stop() {
        pendingAutoRestart?.cancel()
        pendingAutoRestart = nil
        let launchID = activeLaunchID
        activeLaunchID = nil
        summaryDebounceTask?.cancel()
        summaryDebounceTask = nil
        summaryTask?.cancel()
        summaryTask = nil
        auxiliaryProcessingSuspensionTask?.cancel()
        auxiliaryProcessingSuspensionTask = nil
        backgroundOutputThrottleTask?.cancel()
        backgroundOutputThrottleTask = nil
        isOutputPausedForBackgroundThrottle = false
        backgroundOutputBytesSinceThrottle = 0
        nixShellEnvironment = nil
        cancelAgentIdleConfirmation()
        cancelAgentIdleRecheck()
        attentionObservationTask?.cancel()
        attentionObservationTask = nil
        resetKeyboardProtocolState()
        lastHumanInputLine = nil
        lastHumanInputAt = nil
        outputHoldUntil = nil
        pendingResolvedCommandLine = nil
        resolvedCommandLine = nil
        processor.endLaunch(launchID)
        updateShellOutputPauseState()
        hostInputWriter.set(nil)
        if GhosttySessionBridge.nativePTYEnabled {
            // Native-PTY: ghostty owns the PTY and there is no shellProcess to
            // terminate, so signal the shell directly — otherwise Stop leaves the
            // command running invisibly, still holding its ports. The async startup
            // capture can miss the PID (a never-ending command like `tilt up`
            // outruns the poll), so read the PID file one last time synchronously
            // rather than skip teardown. Kill the WHOLE session: a server that
            // ignores SIGHUP and moved into its own process group survives both
            // ghostty's PTY-close SIGHUP and a shell-only kill.
            if let anchorPID = childProcessID
                ?? ShellProcessController.readNativeShellPID(processID: id.uuidString) {
                ShellProcessController.terminateNativeShellSession(anchorPID: anchorPID)
            }
        }
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
        renderedReplayCache = nil
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
        resetAutoRestartPolicy()
        bumpRevision()
    }

    func resize(columns: Int, rows: Int, forceShellResize: Bool = false) {
        let nextSize = TerminalViewportSize(columns: columns, rows: rows)
        guard nextSize.columns > 0, nextSize.rows > 0 else { return }
        guard nextSize != viewportSize else {
            if forceShellResize {
                shellProcess?.resize(columns: nextSize.columns, rows: nextSize.rows)
            }
            return
        }

        viewportSize = nextSize
        renderedReplayCache = nil
        processor.resize(to: nextSize)
        shellProcess?.resize(columns: nextSize.columns, rows: nextSize.rows)
        revision &+= 1
    }

    func deferOutputForUserInteraction() {
        outputHoldUntil = Date(timeIntervalSinceNow: Self.userScrollOutputHoldInterval)
        pauseOutputForInteractionIfNeeded()
    }

    func ingestTestingData(_ data: Data) {
        renderedReplayCache = nil
        rawOutputStore.append(data)
        lastOutputAt = Date()
        ingestTerminalMetadata(data)
        processor.ingestTestingData(data)
        bumpRevision()
    }

#if DEBUG
    func noteTestingInput(_ data: Data) {
        noteInputBurst(data)
    }

    func setLastSummaryDateForTesting(_ date: Date?) {
        lastSummaryDate = date
    }
#endif

    func rawOutput(maxBytes: Int) -> (data: Data, truncated: Bool) {
        if GhosttySessionBridge.nativePTYEnabled {
            // Native-PTY: the host owns no byte stream, so the surface IS the
            // source of truth. NOTE: this is rendered text, not raw VT bytes — a
            // deliberate semantic change for native panes (no escape sequences, no
            // exact byte fidelity).
            let text = readNativeSurfaceText() ?? ""
            let full = Data(text.utf8)
            if full.count > maxBytes {
                return (Data(full.suffix(maxBytes)), true)
            }
            return (full, false)
        }
        return rawOutputStore.snapshot(maxBytes: maxBytes)
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

    var rawOutputRetainedChunkCount: Int {
        rawOutputStore.chunkCount
    }

    var rawOutputRetainedByteCount: Int {
        rawOutputStore.retainedByteCount
    }

    var ghosttyBridge: GhosttySessionBridge {
        if let ghosttyBridgeStorage {
            return ghosttyBridgeStorage
        }

        let bridge = GhosttySessionBridge(session: self)
        ghosttyBridgeStorage = bridge
        return bridge
    }

    /// Shared launch configuration for the host-managed forkpty shell AND the
    /// native-PTY (ghostty EXEC) shell, so the two stay in parity.
    private func shellLaunchConfiguration() -> ShellProcessController.Configuration {
        ShellProcessController.Configuration(
            shellPath: ShellProcessController.defaultShellPath,
            workingDirectory: workingDirectory,
            projectRoot: projectRoot,
            processID: id.uuidString,
            agentID: kind == .agent ? id.uuidString : nil,
            environment: launchEnvironment,
            term: ShellProcessController.preferredTerminfo.term,
            initialSize: viewportSize,
            startupCommand: launchCommand
        )
    }

    /// Native-PTY (EXEC) command + environment for the ghostty surface to spawn,
    /// resolved from the same configuration the host-managed shell uses.
    var nativeExecLaunch: (command: String?, environment: [String: String]) {
        let resolved = ShellProcessController.nativeExecLaunch(for: shellLaunchConfiguration())
        return (resolved.command, resolved.environment)
    }

    private func startShell() {
        let launchID = UUID()
        activeLaunchID = launchID
        resetAutomaticSummaryForNewAgentLaunch()
        resetKeyboardProtocolState()
        outputHoldUntil = nil
        backgroundOutputThrottleTask?.cancel()
        backgroundOutputThrottleTask = nil
        isOutputPausedForInteraction = false
        isOutputPausedForBackgroundThrottle = false
        backgroundOutputBytesSinceThrottle = 0
        processor.beginLaunch(launchID)
        updateShellOutputPauseState()
        state = .launching
        if isAutoRestartPaused {
            isAutoRestartPaused = false
        }
        startedAt = Date()
        exitedAt = nil
        lastOutputAt = nil
        lastHumanInputAt = nil
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

        if GhosttySessionBridge.nativePTYEnabled {
            // Native-PTY: the ghostty surface owns/spawns the PTY (see
            // GhosttySessionBridge.makeOptions). Do NOT also fork a host shell —
            // that would be a second shell (and a SECOND agent process for agent
            // panes). Reach .live so the surface mounts. Input flows through the
            // surface directly, not the host writer.
            // Shell-exit detection arrives via the ghostty childexited action.
            shellProcess = nil
            hostInputWriter.set(nil)
            childProcessID = nil
            state = .live
            bumpRevision()
            // Remove the previous run's PID file so captureNativeShellPID can't
            // resurrect a stale PID before the new shell rewrites it.
            try? FileManager.default.removeItem(
                atPath: ShellProcessController.shellPIDFilePath(processID: id.uuidString)
            )
            if let bridge = ghosttyBridgeStorage {
                // Relaunch: merely touching the lazy accessor would return the
                // existing surface with its exited child and respawn nothing.
                bridge.relaunchNativeSurface()
            } else {
                // Eagerly build the bridge so the EXEC surface — and therefore
                // the child process — spawns now, like the host forkpty does,
                // instead of lazily on first display. Agents/commands are normal
                // sessions: they must run even when they're not the active tab
                // (e.g. an AI-spawned agent the user hasn't opened yet).
                _ = ghosttyBridge
            }
            // Recover the child PID the shell self-reports (ghostty gives us none),
            // so process-ancestry parent resolution works for AI-spawned subagents.
            captureNativeShellPID()
            return
        }

        do {
            let processor = processor
            let traceRecorder = traceRecorder
            let process = try ShellProcessController(
                configuration: shellLaunchConfiguration(),
                onData: { data in
                    TerminalPerformanceMonitor.recordPTYOutputChunk(bytes: data.count)
                    traceRecorder?.recordOutput(data)
                    self.renderedReplayCache = nil
                    self.rawOutputStore.append(data)
                    self.enqueueTerminalMetadata(data)
                    self.noteProcessOutputForBackgroundThrottle(bytes: data.count)
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

    private func resetAutomaticSummaryForNewAgentLaunch() {
        guard kind == .agent else { return }
        summaryGeneration &+= 1
        lastSummaryOutputChangeDate = nil
        lastSummaryInput = nil
        lastSummaryDate = nil
        summary = nil
        automaticTitle = nil
        if titleSource == .automatic {
            title = systemTitle
            titleSource = .system
        }
    }

    private func handleProcessExit(status: Int32, launchID: UUID) {
        guard activeLaunchID == launchID else { return }
        finishProcessExit(status: status, launchID: launchID)
    }

    private func scheduleAutoRestartAfterExit() {
        let runDuration: TimeInterval? = {
            guard let startedAt, let exitedAt else { return nil }
            return exitedAt.timeIntervalSince(startedAt)
        }()
        consecutiveRapidExitCount = CommandAutoRestartPolicy.nextConsecutiveRapidExitCount(
            previous: consecutiveRapidExitCount,
            runDuration: runDuration
        )
        guard let delay = CommandAutoRestartPolicy.restartDelay(
            consecutiveRapidExits: consecutiveRapidExitCount
        ) else {
            isAutoRestartPaused = true
            return
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self, self.activeLaunchID == nil, self.shellProcess == nil else { return }
            self.pendingAutoRestart = nil
            self.clearScrollback(preservingTerminalState: false)
            self.startShell()
        }
        pendingAutoRestart?.cancel()
        pendingAutoRestart = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Forget crash-loop history. Called on manual restarts and command edits,
    /// so a deliberate user action always gets a fresh set of attempts.
    private func resetAutoRestartPolicy() {
        consecutiveRapidExitCount = 0
        if isAutoRestartPaused {
            isAutoRestartPaused = false
        }
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
            renderedReplayCache = nil
            rawOutputStore.append(hideCursor)
            processor.ingestTestingData(hideCursor)
            if kind == .command, restartOnExit {
                scheduleAutoRestartAfterExit()
            }
        } else {
            processor.appendPlainLines([
                "",
                "[shell exited with status \(status)]"
            ])
        }
        scheduleAttentionObservation(event: .processExited)
        bumpRevision()
    }

    private func pauseOutputForInteractionIfNeeded() {
        guard !isOutputPausedForInteraction else { return }
        isOutputPausedForInteraction = true
        updateShellOutputPauseState()
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
        updateShellOutputPauseState()
    }

    private func handleProcessorDidChange() {
        TerminalPerformanceMonitor.recordProcessorChange()
        renderedReplayCache = nil
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
            scheduleAttentionObservation(event: .contentChanged)
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
        ghosttyBridgeStorage?.noteHostInputForOutputLatency()
        noteInputOutputBaseline()
        if kind == .agent {
            if Self.agentInputSubmitsTurn(input) {
                noteHumanInputIfNeeded()
                setAgentActivityState(.working, source: .inputSubmit)
                scheduleAgentIdleRecheck()
                scheduleAttentionObservation(event: .inputSubmitted)
            }
        }
    }

    private func noteInputOutputBaseline() {
        lastInputOutputVersion = outputVersion
    }

    private func enqueueTerminalMetadata(_ data: Data, parseMetadata: Bool = true) {
        let shouldSchedule = metadataOutputLock.withLock {
            hasPendingOutputActivity = true
            if parseMetadata, !data.isEmpty {
                if pendingMetadataOutput.count + data.count > Self.metadataOutputPendingByteLimit {
                    pendingMetadataOutput.removeAll(keepingCapacity: true)
                    if data.count > Self.metadataOutputPendingByteLimit {
                        pendingMetadataOutput.append(data.suffix(Self.metadataOutputPendingByteLimit))
                    } else {
                        pendingMetadataOutput.append(data)
                    }
                    shouldResetMetadataParserBeforeFlush = true
                } else {
                    pendingMetadataOutput.append(data)
                }
            }

            guard !isMetadataOutputFlushScheduled else { return false }
            isMetadataOutputFlushScheduled = true
            return true
        }

        if shouldSchedule {
            DispatchQueue.main.async { [weak self] in
                self?.flushTerminalMetadata()
            }
        }
    }

    private func flushTerminalMetadata() {
        let (data, didOutput, shouldResetParser) = metadataOutputLock.withLock {
            let data = pendingMetadataOutput
            let didOutput = hasPendingOutputActivity
            let shouldResetParser = shouldResetMetadataParserBeforeFlush
            pendingMetadataOutput.removeAll(keepingCapacity: true)
            hasPendingOutputActivity = false
            shouldResetMetadataParserBeforeFlush = false
            return (data, didOutput, shouldResetParser)
        }

        if didOutput {
            lastOutputAt = Date()
        }
        if shouldResetParser {
            metadataParser.reset()
        }
        if !data.isEmpty {
            ingestTerminalMetadata(data)
        }

        let shouldReschedule = metadataOutputLock.withLock {
            if pendingMetadataOutput.isEmpty, !hasPendingOutputActivity {
                isMetadataOutputFlushScheduled = false
                return false
            }
            return true
        }

        if shouldReschedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.metadataOutputFlushInterval) { [weak self] in
                self?.flushTerminalMetadata()
            }
        }
    }

    private func ingestTerminalMetadata(_ data: Data) {
        var didChange = false
        for event in metadataParser.parse(data) {
            switch event {
            case .title(let nextTitle):
                let nextResolvedCommandLine = kind == .terminal ? pendingResolvedCommandLine : nil
                pendingResolvedCommandLine = nil

                if kind == .agent {
                    didChange = recordAgentTitleActivity(nextTitle) || didChange
                } else {
                    if resolvedCommandLine != nextResolvedCommandLine {
                        resolvedCommandLine = nextResolvedCommandLine
                        didChange = true
                    }
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

            case .resolvedCommandLine(let commandLine):
                pendingResolvedCommandLine = commandLine

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

    // MARK: - Native-PTY chrome ingestion
    //
    // Under the EXEC backend the ghostty surface owns the PTY, so chrome that the
    // host path derives from PTY bytes (`ingestTerminalMetadata`) instead arrives
    // as ghostty actions forwarded by `GhosttySessionBridge`. These route those
    // actions through the same consumers so the sidebar title/cwd/notifications
    // and shell-exit detection stay live without a host byte stream. They mirror
    // the matching `case`s in `ingestTerminalMetadata`.

    func ingestNativeTitle(_ nextTitle: String) {
        if kind == .agent {
            if recordAgentTitleActivity(nextTitle) { bumpRevision() }
        } else {
            guard systemTitle != nextTitle else { return }
            updateSystemTitle(nextTitle)
            bumpRevision()
        }
    }

    func ingestNativeWorkingDirectory(_ path: String) {
        var didChange = false
        if workingDirectory != path {
            workingDirectory = path
            didChange = true
        }
        if restoreShellTitle(from: path) {
            didChange = true
        }
        if didChange { bumpRevision() }
    }

    func ingestNativeNotification(title: String?, body: String) {
        let notification = TerminalNotificationRequest(title: title, body: body, source: .osc777)
        if handleAgentNotification(notification) == .passThrough {
            handleTerminalNotification(notification)
        }
        bumpRevision()
    }

    func ingestNativeChildExit(exitCode: Int32) {
        guard let launchID = activeLaunchID else { return }
        finishProcessExit(status: exitCode, launchID: launchID)
    }

    /// OSC 133 'D' (shell-integration command end) under native. A precise
    /// command-boundary signal for plain scripts/commands — far better than a
    /// quiet-period guess. (Agent TUIs run on the alternate screen and emit no
    /// per-command markers, so this fires only for primary-screen commands.)
    /// Polls the PID file the native-PTY shell writes at startup and stores it as
    /// `childProcessID`, so `process.pid` is populated for process-ancestry parent
    /// resolution (ghostty exposes no child PID). Self-healing: retries until the
    /// shell integration has written the file.
    private func captureNativeShellPID() {
        guard GhosttySessionBridge.nativePTYEnabled else { return }
        let launchID = activeLaunchID
        func poll(_ attempt: Int) {
            guard activeLaunchID == launchID else { return } // session relaunched/exited
            if let pid = ShellProcessController.readNativeShellPID(processID: id.uuidString) {
                childProcessID = pid
                bumpRevision()
                return
            }
            guard attempt < 25 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll(attempt + 1) }
        }
        poll(0)
    }

    func noteNativeCommandFinished(exitCode: Int32?) {
        guard GhosttySessionBridge.nativePTYEnabled else { return }
        lastNativeCommandFinishedAt = Date()
        lastNativeCommandExitCode = exitCode
        // Capture the command's final output and advance the counters so idle
        // detection converges on the real boundary, not a heuristic timeout.
        refreshNativeContentNow()
        bumpRevision()
    }

    // MARK: - Native-PTY content model (search / summary / idle under EXEC)
    //
    // The data layer (getProcessOutput, search, agent summaries, waitForProcessIdle)
    // reads `lineCount`/`snapshot(range:)` and the `outputVersion`/`contentVersion`
    // counters, all driven by `handleProcessorDidChange` in the host path. Under
    // EXEC there is no host byte stream, so we instead pull the surface's text on a
    // debounced render signal and drive the same counters/hooks from it.

    /// Pulls the surface's text for the native data layer. The SCREEN selection
    /// returns the active screen — including a TUI's live alternate screen (verified
    /// against `top`) — plus scrollback for primary-screen shells.
    private func readNativeSurfaceText() -> String? {
        ghosttyBridgeStorage?.readNativeScreenText()
    }

    private func contentLineCount() -> Int {
        guard GhosttySessionBridge.nativePTYEnabled, ghosttyBridgeStorage != nil else {
            return processor.lineCount
        }
        ensureNativeContentFresh()
        return nativeContentLines.count
    }

    private func contentSnapshot(range: Range<Int>) -> [String] {
        guard GhosttySessionBridge.nativePTYEnabled, ghosttyBridgeStorage != nil else {
            return processor.snapshot(range: range)
        }
        ensureNativeContentFresh()
        guard !nativeContentLines.isEmpty else { return [] }
        let clamped = range.clamped(to: 0..<nativeContentLines.count)
        return Array(nativeContentLines[clamped])
    }

    /// Render-signal entry point: schedule a debounced content refresh so the
    /// output/idle counters advance even when nothing is actively reading.
    func noteNativeRenderRequest() {
        guard GhosttySessionBridge.nativePTYEnabled else { return }
        guard !nativeContentRefreshScheduled else { return }
        nativeContentRefreshScheduled = true
        // Off-screen sessions (e.g. background agents an orchestrator drives) refresh
        // less aggressively — their content is still pulled on demand by the data
        // layer; this just throttles the proactive counter/idle updates.
        let debounce = ProjectWindowRegistry.shared.isSessionVisible(self)
            ? Self.nativeContentDebounceInterval
            : Self.nativeContentDebounceInterval * 4
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce) { [weak self] in
            guard let self else { return }
            self.nativeContentRefreshScheduled = false
            self.refreshNativeContentNow()
        }
    }

    /// Re-read the surface scrollback when stale (throttled). Called on every
    /// data-layer read so search/output are always current, independent of how
    /// reliably the render signal fires.
    private func ensureNativeContentFresh() {
        if let last = lastNativeContentReadAt,
           Date().timeIntervalSince(last) < Self.nativeContentReadThrottle {
            return
        }
        refreshNativeContentNow()
    }

    /// Pulls the surface scrollback and, if it changed, rebuilds the native line
    /// model and advances the same counters/hooks `handleProcessorDidChange` drives
    /// in the host path. The change probe hashes the full screen text (the viewport
    /// selection isn't reliably readable), which cursor blink etc. don't alter.
    @discardableResult
    private func refreshNativeContentNow() -> Bool {
        guard GhosttySessionBridge.nativePTYEnabled else { return false }
        // recordAgentActivitySignal / summaryTranscript below re-enter this
        // function through contentSnapshot → ensureNativeContentFresh. Without
        // this guard, a session whose screen changes faster than one scan pass
        // (any working agent repaints its spinner every second) recurses
        // unboundedly and livelocks the main thread.
        guard !isRefreshingNativeContent else { return false }
        isRefreshingNativeContent = true
        defer { isRefreshingNativeContent = false }
        guard let text = readNativeSurfaceText() else { return false }
        lastNativeContentReadAt = Date()
        var hasher = Hasher()
        hasher.combine(text)
        let hash = hasher.finalize()
        guard hash != nativeContentHash else { return false }
        nativeContentHash = hash
        nativeContentLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        lastOutputAt = Date()
        if case .launching = state { state = .live }
        outputVersion &+= 1
        lastContentChangeAt = Date()
        contentVersion &+= 1
        if kind == .agent {
            lastSummaryOutputChangeDate = Date()
            recordAgentActivitySignal()
            if agentActivityState == .working {
                scheduleAgentIdleRecheck()
            }
            scheduleSummaryIfNeeded()
            scheduleAttentionObservation(event: .contentChanged)
        }
        bumpRevision()
        return true
    }

    @discardableResult
    func captureAttentionObservation(
        label: TerminalAttentionLabel,
        scenarioID: String?,
        checkpoint: String?,
        harnessVersion: String?,
        runID: String?
    ) throws -> (id: UUID, outputURL: URL) {
        guard let attentionObservationRecorder = ensureAttentionObservationRecorder() else {
            throw TerminalAttentionRecordingError.disabled
        }

        let observation = makeAttentionObservation(
            event: .labeledCheckpoint,
            label: label,
            scenarioID: scenarioID,
            checkpoint: checkpoint,
            harnessVersion: harnessVersion,
            runID: runID
        )
        attentionObservationRecorder.record(observation, synchronously: true)
        return (observation.id, attentionObservationRecorder.outputURL)
    }

    private func scheduleAttentionObservation(event: TerminalAttentionObservationEvent) {
        guard kind == .agent, attentionObservationDirectoryProvider() != nil else { return }

        if event != .contentChanged {
            recordAttentionObservation(event: event)
            return
        }

        guard attentionObservationTask == nil else { return }
        attentionObservationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.attentionObservationInterval * 1_000)))
            guard let self, !Task.isCancelled else { return }
            self.attentionObservationTask = nil
            self.recordAttentionObservation(event: .contentChanged)
        }
    }

    private func recordAttentionObservation(event: TerminalAttentionObservationEvent) {
        guard let attentionObservationRecorder = ensureAttentionObservationRecorder() else { return }
        let observation = makeAttentionObservation(
            event: event,
            label: nil,
            scenarioID: nil,
            checkpoint: nil,
            harnessVersion: nil,
            runID: nil
        )
        attentionObservationRecorder.record(observation)
    }

    private func ensureAttentionObservationRecorder() -> TerminalAttentionObservationRecorder? {
        guard let directoryURL = attentionObservationDirectoryProvider() else { return nil }
        if attentionObservationRecorder == nil {
            attentionObservationRecorder = TerminalAttentionObservationRecorder(
                directoryURL: directoryURL,
                sessionID: id,
                harness: agentName
            )
        }
        return attentionObservationRecorder
    }

    private func makeAttentionObservation(
        event: TerminalAttentionObservationEvent,
        label: TerminalAttentionLabel?,
        scenarioID: String?,
        checkpoint: String?,
        harnessVersion: String?,
        runID: String?
    ) -> TerminalAttentionObservation {
        let now = Date()
        let lineCount = contentLineCount()
        let rowLimit = min(max(viewportSize.rows, 1), Self.attentionObservationMaximumRows)
        let columnLimit = min(max(viewportSize.columns, 1), Self.attentionObservationMaximumColumns)
        let gridStart = max(0, lineCount - rowLimit)
        let grid = contentSnapshot(range: gridStart..<lineCount).map { line in
            String(line.prefix(columnLimit))
        }
        let cursor = cursorState

        return TerminalAttentionObservation(
            schemaVersion: TerminalAttentionObservation.currentSchemaVersion,
            id: UUID(),
            recordedAt: now,
            event: event,
            label: label,
            scenarioID: Self.attentionRecordingMetadata(scenarioID),
            checkpoint: Self.attentionRecordingMetadata(checkpoint),
            session: .init(
                id: id.uuidString,
                kind: kind.rawValue,
                harness: Self.attentionRecordingMetadata(agentName),
                harnessVersion: Self.attentionRecordingMetadata(harnessVersion),
                runID: Self.attentionRecordingMetadata(runID)
            ),
            terminal: .init(
                columns: viewportSize.columns,
                rows: viewportSize.rows,
                usesAlternateScreen: usesAlternateScreen,
                cursor: .init(
                    row: max(0, cursor.row - gridStart),
                    column: cursor.column,
                    shape: Self.attentionCursorShapeName(cursor.shape),
                    isVisible: cursor.isVisible
                ),
                grid: grid,
                scrollbackLinesOmitted: gridStart
            ),
            timing: .init(
                millisecondsSinceStarted: Self.milliseconds(since: startedAt, now: now),
                millisecondsSinceLastOutput: Self.milliseconds(since: lastOutputAt, now: now),
                millisecondsSinceLastContentChange: Self.milliseconds(since: lastContentChangeAt, now: now),
                millisecondsSinceLastHumanInput: Self.milliseconds(since: lastHumanInputAt, now: now)
            ),
            activity: .init(
                state: agentActivityState.rawValue,
                evidence: attentionActivityEvidenceName,
                hasUnreadNotification: hasUnreadNotification,
                processState: state.label,
                exitCode: exitCode
            ),
            outputVersion: outputVersion,
            contentVersion: contentVersion
        )
    }

    private var attentionActivityEvidenceName: String {
        switch agentActivitySource {
        case .none: "none"
        case .summary: "summary"
        case .outputActivity: "output_activity"
        case .inputSubmit: "input_submit"
        case .quietWindow: "quiet_window"
        case .promptMarker: "prompt_marker"
        case .workingMarker: "working_marker"
        case .titleSpinner: "title_spinner"
        case .notification: "notification"
        case .processExit: "process_exit"
        }
    }

    private static func attentionCursorShapeName(_ shape: TerminalCursorShape) -> String {
        switch shape {
        case .block: "block"
        case .bar: "bar"
        case .underline: "underline"
        }
    }

    private static func milliseconds(since date: Date?, now: Date) -> Int? {
        guard let date else { return nil }
        return max(0, Int(now.timeIntervalSince(date) * 1_000))
    }

    private static func attentionRecordingMetadata(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return String(value.prefix(160))
    }

    enum AgentNotificationDisposition {
        case passThrough
        case suppress
    }

    private func handleAgentNotification(
        _ notification: TerminalNotificationRequest
    ) -> AgentNotificationDisposition {
        guard kind == .agent else { return .passThrough }
        defer {
            scheduleAttentionObservation(event: .notification)
        }

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
        case .none, .summary, .outputActivity, .inputSubmit, .quietWindow:
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
        if nextState == .working {
            // A summary verdict is weak evidence. Give the quiet recheck a chance
            // to overturn it, otherwise a misclassified "working" sticks until the
            // next content change — which for a finished agent never comes.
            scheduleAgentIdleRecheck()
        }
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
        case .none, .summary, .outputActivity, .inputSubmit, .workingMarker, .titleSpinner, .quietWindow:
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
        // A live working marker or a still-pulsing title spinner outranks quiet —
        // but keep rechecking, so evidence that later disappears (marker scrolls
        // out of the tail window, spinner stops pulsing) cannot pin "working"
        // forever on a session that never produces another content change.
        guard !renderedOutputShowsAgentWorkingMarker(), !titleSpinnerEvidenceIsActive else {
            scheduleAgentIdleRecheck()
            return
        }

        // Prefer a recognized composer prompt — the strongest idle signal. Ignore the
        // human-input floor so a settled prompt is still found below the last typed line.
        let lineCount = effectiveAgentContentLineCount()
        if lineCount > 0 {
            let normalizedAgentName = AgentToolDefinition.normalizedName(agentName ?? title)
            let scanStart = max(0, lineCount - Self.agentInputMarkerTailLineLimit)
            let scanLines = contentSnapshot(range: scanStart..<lineCount)
            let promptLines = agentPromptWindowLines(
                scanStart: scanStart,
                scanLines: scanLines,
                applyInputFloor: false
            )
            let promptVisible = promptLines.contains { line in
                Self.isAgentInputPromptLine(line, normalizedAgentName: normalizedAgentName)
            } || Self.outputContainsAgentInputMarker(scanLines, normalizedAgentName: normalizedAgentName)
            if promptVisible {
                setAgentActivityState(.idle, source: .promptMarker)
                return
            }
        }

        // No prompt/working UI to key off (amp, bare REPLs, unrecognized agents): the
        // turn's strong evidence has gone stale and the content has been quiet for the
        // recheck window, so settle to idle. Mirrors the content-quiet fallback the MCP
        // wait_for_process_idle loop already applies, lifted into the live UI state so the
        // sidebar/menu bar stop showing a permanent "working" spinner for these agents.
        guard hasBeenContentQuiet(for: Self.agentIdleRecheckQuietInterval) else {
            scheduleAgentIdleRecheck()
            return
        }
        setAgentActivityState(.idle, source: .quietWindow)
    }

    private func hasBeenContentQuiet(for interval: TimeInterval) -> Bool {
        guard let lastContentChangeAt else { return true }
        return Date().timeIntervalSince(lastContentChangeAt) >= interval
    }

    // TUIs that park the cursor on the bottom screen row materialize dozens of
    // empty rows below their content, so tail windows must anchor to the last
    // row that actually holds text.
    private static let agentTrailingBlankScanLimit = 600

    private func effectiveAgentContentLineCount() -> Int {
        let lineCount = contentLineCount()
        guard lineCount > 0 else { return 0 }
        let scanStart = max(0, lineCount - Self.agentTrailingBlankScanLimit)
        let scanLines = contentSnapshot(range: scanStart..<lineCount)
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
        let markerLines = contentSnapshot(range: markerStart..<lineCount)
        return Self.outputContainsAgentWorkingMarker(markerLines, normalizedAgentName: normalizedAgentName)
    }

    private func renderedOutputShowsAgentInputPrompt() -> Bool {
        let lineCount = effectiveAgentContentLineCount()
        guard lineCount > 0 else { return false }

        let normalizedAgentName = AgentToolDefinition.normalizedName(agentName ?? title)
        let markerStart = max(0, lineCount - Self.agentInputMarkerTailLineLimit)
        let markerLines = contentSnapshot(range: markerStart..<lineCount)
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

    // Claude Code 2.x and Codex both surface "esc to interrupt" only while a
    // turn is in flight; older Codex status lines ("Working (Xs · esc to
    // interrupt)") contained it too. Markers must never trust transcript PROSE:
    // an agent narrating its own work ("~3–5% while working (0% idle)") pinned
    // its session to "working" forever, so there is no bare "working (" match,
    // and Claude's post-turn statuses ("✳ Sautéed for 23s · 1 shell still
    // running") only count on lines led by a spinner glyph.
    private static let claudeStatusMarkerPhrases = ["whisking", "still thinking", "shell still running"]
    private static let claudeSpinnerGlyphs: Set<Character> = ["·", "✢", "✳", "✶", "✻", "✽", "∗", "*"]

    private static func outputContainsAgentWorkingMarker(_ lines: [String], normalizedAgentName: String) -> Bool {
        let trimmedLines = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if trimmedLines.contains(where: { $0.lowercased().contains("esc to interrupt") }) {
            return true
        }

        guard normalizedAgentName == "claude" else { return false }
        return trimmedLines.contains { line in
            guard let first = line.first, claudeSpinnerGlyphs.contains(first) else { return false }
            let lowered = line.lowercased()
            return claudeStatusMarkerPhrases.contains { lowered.contains($0) }
        }
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

    static func appKitKeyEventSubmitsAgentTurn(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        guard event.keyCode == 36 || event.keyCode == 76 else { return false }

        let heldModifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        return heldModifiers.isEmpty
    }

    @discardableResult
    private func setAgentActivityState(_ nextState: AgentActivityState, source: AgentActivitySource) -> Bool {
        guard kind == .agent else { return false }
        let stateChanged = agentActivityState != nextState
        agentActivityState = nextState
        agentActivitySource = source
        guard stateChanged else { return false }
        scheduleAttentionObservation(event: .activityStateChanged)
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
        guard canRunSummaryAtCurrentVisibility else { return }

        let settings = AgentSettings.shared
        let command = settings.effectiveAgentSummaryCommand.trimmingCharacters(in: .whitespacesAndNewlines)

        let now = Date()
        let cadenceReadyDate = lastSummaryDate?.addingTimeInterval(settings.agentSummaryCadence.interval) ?? now
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
                    let activityReadyDate = min(idleReadyDate, maximumReadyDate)
                    let readyDate = max(cadenceReadyDate, activityReadyDate)
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
        guard canRunSummaryAtCurrentVisibility else { return }
        let transcript = summaryTranscript()
        let transcriptOutputVersion = outputVersion
        let transcriptHumanInputGeneration = humanInputGeneration
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
                    let submittedTurnChanged = self.humanInputGeneration != transcriptHumanInputGeneration
                    self.summaryTask = nil
                    guard generation == self.summaryGeneration, !submittedTurnChanged else {
                        if submittedTurnChanged {
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
                        title: result.title,
                        summary: result.summary,
                        error: nil
                    )
                    self.applyAutomaticSummary(
                        result.summary,
                        title: result.title,
                        useAsTitle: AgentSettings.shared.useAgentSummaryAsTitle,
                        // The title and summary still describe this submitted
                        // turn, but activity state is point-in-time data. Do not
                        // let an older snapshot overwrite fresher output signals.
                        agentActivityState: outputChanged ? nil : result.state
                    )
                    if outputChanged {
                        self.scheduleSummaryIfNeeded()
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    guard !Task.isCancelled else {
                        self.summaryTask = nil
                        return
                    }
                    let outputChanged = self.outputVersion != transcriptOutputVersion
                    let submittedTurnChanged = self.humanInputGeneration != transcriptHumanInputGeneration
                    self.summaryTask = nil
                    guard generation == self.summaryGeneration, !submittedTurnChanged else {
                        if submittedTurnChanged {
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
                    if outputChanged || self.needsInitialGeneratedTitle {
                        self.scheduleSummaryIfNeeded()
                    }
                }
            }
        }
    }

    private var canRunSummaryAtCurrentVisibility: Bool {
        guard summaryVisibilityProvider(self) else { return true }

        // Visible agents still need generated-title refreshes. Avoid summarizing
        // their startup screen before any work is submitted, and keep explicit
        // titles entirely user-owned.
        return AgentSettings.shared.useAgentSummaryAsTitle
            && titleSource != .explicit
            && (titleSource == .automatic || lastHumanInputLine != nil)
    }

    private var needsInitialGeneratedTitle: Bool {
        AgentSettings.shared.useAgentSummaryAsTitle
            && titleSource == .system
            && lastHumanInputLine != nil
    }

    private func recordSummaryDebug(
        command: String,
        transcript: SummaryTranscript,
        prompt: String,
        title: String? = nil,
        summary: String?,
        error: String?
    ) {
        AgentSummaryDebugStore.shared.record(.init(
            date: Date(),
            sessionID: id,
            sessionTitle: self.title,
            command: command,
            workingDirectory: workingDirectory,
            inputLineCount: transcript.inputLineCount,
            filteredLineCount: transcript.filteredLineCount,
            charactersSent: prompt.count,
            transcript: transcript.text,
            prompt: prompt,
            title: title,
            summary: summary,
            error: error
        ))
    }

    private func summaryTranscript() -> SummaryTranscript {
        let lineCount = effectiveAgentContentLineCount()
        guard lineCount > 0 else { return .empty }
        let recentStartLine = max(0, lineCount - Self.summaryTailLineLimit)
        let inputLines = contentSnapshot(range: recentStartLine..<lineCount)
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
        lastHumanInputAt = Date()
        humanInputGeneration &+= 1
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
