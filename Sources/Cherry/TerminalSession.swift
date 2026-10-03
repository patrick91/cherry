import AppKit
import CherryControl
import Combine
import Darwin
import Foundation

/// `CHERRY_DEBUG_INPUT=1`: trace typed input and the buffer's tail to the
/// unified log (as private data). Tests switch it on.
nonisolated(unsafe) var inputDebugEnabled = ProcessInfo.processInfo.environment["CHERRY_DEBUG_INPUT"] == "1"
private let activityDebugEnabled = ProcessInfo.processInfo.environment["CHERRY_ACTIVITY_DEBUG"] == "1"
private let ptyTraceDirectory = ProcessInfo.processInfo.environment["CHERRY_TRACE_PTY_DIR"]
private let prototypeProcessorDisabledForPerf =
    ProcessInfo.processInfo.environment["CHERRY_DISABLE_PROTOTYPE_PROCESSOR"] == "1"

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
            SessionLog.debug("[pty trace] failed to create \(directoryURL.path): \(error.localizedDescription)")
            return nil
        }

        let filename = "\(Self.timestamp())-\(Self.safeFilename(title))-\(sessionID.uuidString.prefix(8)).pty"
        outputURL = directoryURL.appendingPathComponent(filename)

        FileManager.default.createFile(atPath: outputURL.path, contents: Data())

        do {
            outputHandle = try FileHandle(forWritingTo: outputURL)
        } catch {
            SessionLog.debug("[pty trace] failed to open \(outputURL.path): \(error.localizedDescription)")
            return nil
        }

        SessionLog.debug("[pty trace] writing raw PTY output to \(outputURL.path)")
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
        self.buffer = buffer ?? LiveTerminalOutputBuffer(maxScrollback: maxScrollback)
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
    private var fallbackWriteHandler: WriteHandler?
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

    /// Takes what is written while no process is set.
    func setFallbackWriteHandler(_ handler: WriteHandler?) {
        lock.withLock {
            fallbackWriteHandler = handler
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

    /// `data` with its unmodified arrow, Home and End keys (`ESC [ A`…,
    /// `ESC O A`…; `TerminalSession.containsCursorModeKeys`) in the form a
    /// terminal types them in the program's cursor key mode (DECCKM):
    /// `ESC O x` while application cursor keys are on, `ESC [ x` while off.
    /// Everything else is kept as it is.
    static func encodingCursorKeys(_ data: Data, applicationCursorKeys: Bool) -> Data {
        var bytes = [UInt8](data)
        let introducer: UInt8 = applicationCursorKeys ? 0x4F : 0x5B
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0x1B, bytes[index + 1] == 0x5B || bytes[index + 1] == 0x4F,
               [0x41, 0x42, 0x43, 0x44, 0x46, 0x48].contains(bytes[index + 2]) {
                bytes[index + 1] = introducer
                index += 3
            } else {
                index += 1
            }
        }
        return Data(bytes)
    }
}

struct AgentSessionTreeItem: Identifiable {
    let session: TerminalSession
    let depth: Int

    var id: UUID { session.id }
}

@MainActor
struct AgentSessionTreeSnapshot {
    let sessions: [TerminalSession]
    let roots: [TerminalSession]
    private let childrenByParentID: [UUID: [TerminalSession]]

    init(sessions: [TerminalSession]) {
        let agents = sessions.filter { $0.kind == .agent }
        let agentIDs = Set(agents.map(\.id))
        var roots: [TerminalSession] = []
        var childrenByParentID: [UUID: [TerminalSession]] = [:]

        for session in agents {
            if let parentID = session.parentAgentID, agentIDs.contains(parentID) {
                childrenByParentID[parentID, default: []].append(session)
            } else {
                roots.append(session)
            }
        }

        self.sessions = agents
        self.roots = roots
        self.childrenByParentID = childrenByParentID
    }

    func children(of parent: TerminalSession) -> [TerminalSession] {
        childrenByParentID[parent.id] ?? []
    }

    func visibleItems(collapsedIDs: Set<UUID>) -> [AgentSessionTreeItem] {
        var items: [AgentSessionTreeItem] = []
        items.reserveCapacity(sessions.count)
        for root in roots {
            items.append(AgentSessionTreeItem(session: root, depth: 0))
            guard !collapsedIDs.contains(root.id) else { continue }
            items.append(contentsOf: children(of: root).map {
                AgentSessionTreeItem(session: $0, depth: 1)
            })
        }
        return items
    }
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
    @Published private(set) var sessions: [TerminalSession] {
        didSet { sessionsDidChange() }
    }
    @Published private(set) var terminalDisplayItems: [TerminalDisplayItem]
    @Published private(set) var terminalSplitGroups: [TerminalSplitGroup] = []
    @Published private(set) var terminalDetailWidth: CGFloat = 0
    @Published var selectedSessionID: UUID? {
        didSet {
            updateAuxiliaryProcessingForSelection(previousSelectedSessionID: oldValue)
            clearUnreadNotificationForSelectedSession()
        }
    }
    /// The project's key (`ProjectLocation`): its directory for a project
    /// on This Mac, `device:<uuid>:<path>` for one on another Mac. What
    /// identifies the project; never a directory to start in by itself.
    let projectRoot: String?
    /// Where new tabs start on the machine that runs them: the project's
    /// directory there (`ProjectLocation.launchPath(forKey:)`).
    var launchRoot: String? {
        projectRoot.map(ProjectLocation.launchPath(forKey:))
    }
    let backendPolicy: SessionBackendPolicy
    private let launchBackend: TerminalSessionLaunchBackend
    /// Fires for changes workspace persistence saves that the published
    /// properties above do not report: a tab rename, a managed command edit,
    /// or an agent moving to another parent.
    let persistentStateChanges = PassthroughSubject<Void, Never>()
    /// What a restored tab was saved with, for the metadata its
    /// `TerminalSession` cannot carry yet (a hosted tab is always a terminal),
    /// so saving it again keeps that metadata. Closing the tab drops it.
    private(set) var restoredSessionRecords: [UUID: WorkspaceSessionRecord] = [:]
    /// Set once the workspace's window or the app tore it down; its sessions
    /// are gone and must not be saved as an empty workspace.
    private(set) var isTornDown = false
    /// Why every tab was last closed at once (window closed, app quit,
    /// worktree removed): tabs a restore finishes afterwards end the same way.
    private(set) var closeAllIntent: SessionCloseIntent?
    /// Launches restored tabs' attach adapters a few at a time (tests give
    /// a workspace its own).
    var restoredTabLaunchQueue: RestoredTabLaunchQueue = .shared
    /// Closes a terminal tab whose shell exited with status 0
    /// (`tabProgramDidExit`). The default keeps a workspace's last tab (it
    /// has no window to close); a project window's repository replaces it to
    /// close the window with its last tab, as ⌘W does.
    var closeTabAfterCleanExit: @MainActor (TerminalWorkspace, TerminalSession) -> Void = { workspace, session in
        workspace.close(session, intent: .programExited)
    }

    init(
        projectRoot: String? = nil,
        createInitialSession: Bool = true,
        launchBackend: TerminalSessionLaunchBackend = .nativePTY,
        backendPolicy: SessionBackendPolicy = .native
    ) {
        // A project on another Mac keeps its key: it is not a directory here.
        self.projectRoot = projectRoot.map { root in
            ProjectLocation.isRemoteKey(root) ? ProjectLocation(key: root).key : Self.resolvedWorkingDirectory(root)
        }
        self.launchBackend = launchBackend
        self.backendPolicy = backendPolicy
        guard createInitialSession else {
            sessions = []
            terminalDisplayItems = []
            selectedSessionID = nil
            return
        }
        let firstSession = Self.makeSession(
            index: 1,
            workingDirectory: self.projectRoot.map(ProjectLocation.launchPath(forKey:)),
            projectRoot: self.projectRoot,
            launchBackend: launchBackend,
            persistentHosting: launchBackend == .nativePTY ? backendPolicy.persistentHostingForNewTab() : nil
        )
        sessions = [firstSession]
        terminalDisplayItems = [.single(firstSession.id)]
        selectedSessionID = firstSession.id
        sessionsDidChange()
    }

    /// Opens the default "Shell 1" in a workspace that restored nothing.
    /// `ignoringCommands`: also when its only tabs are commands (auto-start
    /// ran while tabs were still being restored).
    func addInitialSessionIfEmpty(ignoringCommands: Bool = false) {
        let isEmpty = ignoringCommands ? sessions.allSatisfy { $0.kind == .command } : sessions.isEmpty
        guard isEmpty else { return }
        let firstSession = Self.makeSession(
            index: 1,
            workingDirectory: launchRoot,
            projectRoot: projectRoot,
            launchBackend: launchBackend,
            persistentHosting: persistentHostingForNewTab()
        )
        sessions = [firstSession] + sessions
        terminalDisplayItems = [.single(firstSession.id)] + terminalDisplayItems
        select(firstSession)
    }

    /// The local host for a new tab's program when this workspace runs new
    /// local tabs as persistent sessions and the host can run them now; nil
    /// for a native tab.
    private func persistentHostingForNewTab() -> PersistentLocalSessions? {
        guard launchBackend == .nativePTY else { return nil }
        return backendPolicy.persistentHostingForNewTab()
    }

    private func sessionsDidChange() {
        for session in sessions where session.persistentStateDidChange == nil {
            session.persistentStateDidChange = { [weak self] in
                self?.persistentStateChanges.send()
            }
        }
        for session in sessions where session.programDidExit == nil {
            session.programDidExit = { [weak self] session in
                self?.tabProgramDidExit(session)
            }
        }
        for session in sessions where session.detachedSurfaceSize == nil {
            // A tab this workspace has not seen before: until its own
            // surface reports, it has the grid its window's terminal has.
            if let grid = mountedTerminalGrid {
                session.seedViewportSize(grid)
            }
            session.detachedSurfaceSize = { [weak self, weak session] in
                // Only while the tab is this workspace's.
                guard let self, let session, self.sessions.contains(where: { $0 === session }) else { return nil }
                return self.mountedTerminalSize
            }
            session.windowTerminalCell = { [weak self, weak session] grid in
                guard let self, let session, self.sessions.contains(where: { $0 === session }) else { return nil }
                return self.terminalCell(forGrid: grid)
            }
            session.surfaceShowedWindowGrid = { [weak self, weak session] grid, window in
                guard let self, let session, self.sessions.contains(where: { $0 === session }) else { return }
                self.windowGrid.note(grid, in: window)
            }
            if let wait = backendPolicy.windowGridWait {
                session.windowGridForCreate = (wait, { [weak self, weak session] in
                    guard let self, let session, self.sessions.contains(where: { $0 === session }) else { return nil }
                    return self.windowGrid.observation()
                })
            }
        }
    }

    /// The grid this workspace's window gives its terminals, and since when
    /// (`TerminalWindowGrid`): what a new persistent tab's Create starts its
    /// program at once it settled (`TerminalWindowGridWait`). A repository's
    /// worktrees share their window's (`RepositoryWorkspace`).
    var windowGrid = TerminalWindowGrid()

    /// The cell size, in pixels, that a terminal of `grid` in this
    /// workspace's window reports to its program, from a tab whose surface
    /// has that grid (`TerminalSession.terminalCell(forGrid:)`), the
    /// selected tab's first. Tabs of one window share its font and display,
    /// and one of the same grid has the same pixels as a rule. Nil when
    /// none has.
    func terminalCell(forGrid grid: TerminalViewportSize) -> TerminalCellSize? {
        let candidates = (selectedSession.map { [$0] } ?? []) + sessions
        return candidates.lazy.compactMap { $0.terminalCell(forGrid: grid) }.first
    }

    /// The grid of a terminal this workspace's window shows now (see
    /// `mountedTerminalSize`).
    var mountedTerminalGrid: TerminalViewportSize? {
        let shown = (selectedSession.map { [$0] } ?? []) + sessions
        return shown.lazy.compactMap(\.mountedTerminalGrid).first
    }

    /// The size, in points, of a terminal this workspace's window shows now:
    /// the selected tab's, else any other tab's that a view shows; nil when
    /// none is on screen.
    var mountedTerminalSize: CGSize? {
        if let size = selectedSession?.mountedTerminalSize { return size }
        return sessions.lazy.compactMap(\.mountedTerminalSize).first
    }

    /// Whether `session`'s tab closes now that its program ended: a terminal
    /// (not an attached tab) whose shell exited with status 0 after running
    /// at least `cleanExitMinimumRunTime` (from when it started, not when
    /// the tab asked for it: `programStartedAt`), while Settings › Sessions
    /// closes such tabs. Command and agent tabs stay (their output is the
    /// point), and so does a shell that failed, so its error stays readable.
    func closesTabAfterExit(_ session: TerminalSession) -> Bool {
        guard backendPolicy.settings().closeTabsOnCleanExit,
              session.kind == .terminal,
              session.hostedAttachment == nil,
              session.state == .exited(0),
              let startedAt = session.programStartedAt,
              let exitedAt = session.exitedAt
        else { return false }
        return exitedAt.timeIntervalSince(startedAt) >= backendPolicy.cleanExitMinimumRunTime
    }

    /// A tab's program ended by itself (`TerminalSession.programDidExit`):
    /// a terminal whose shell exited cleanly closes (`closeTabAfterCleanExit`)
    /// on the next main-loop turn. The exit may be reported from inside
    /// Ghostty's tick, which must not free the surface it runs for. By then
    /// the tab may be gone, closed or running again (Restart, MCP
    /// `start_process`); it then stays as it is.
    private func tabProgramDidExit(_ session: TerminalSession) {
        guard closesTabAfterExit(session) else { return }
        let exitedAt = session.exitedAt
        DispatchQueue.main.async { [weak self, weak session] in
            MainActor.assumeIsolated {
                guard let self, let session,
                      !self.isTornDown,
                      self.sessions.contains(where: { $0 === session }),
                      !session.isRunning,
                      session.exitedAt == exitedAt,
                      self.closesTabAfterExit(session)
                else { return }
                self.closeTabAfterCleanExit(self, session)
            }
        }
    }

    /// `id`, unless a tab here already has it: two tabs with one id would
    /// break list identity, split panes, MCP lookup and deep links, so the
    /// new tab gets a fresh id instead.
    private func unusedSessionID(_ id: UUID) -> UUID {
        guard sessions.contains(where: { $0.id == id }) else { return id }
        SessionLog.notice("tab id \(id.uuidString) is already open; the new tab gets another id")
        return UUID()
    }

    var selectedSession: TerminalSession? {
        guard let selectedSessionID else { return sessions.first }
        return sessions.first(where: { $0.id == selectedSessionID }) ?? sessions.first
    }

    var agentSessions: [TerminalSession] {
        sessions.filter { $0.kind == .agent }
    }

    /// Agents whose program runs; a persistent agent's runs until its host
    /// reports the exit, while its attach adapter reconnects too (the menu
    /// bar lists these).
    var runningAgentSessions: [TerminalSession] {
        agentSessions.filter(\.isProgramRunning)
    }

    /// Sessions currently running a process across every kind — broader than
    /// `runningAgentSessions` (adds live commands and terminals executing a
    /// foreground program). A method, not a computed var: for terminals it probes
    /// the process table, so it must never be read from a SwiftUI body.
    func sessionsWithRunningProcess() -> [TerminalSession] {
        sessions.filter { $0.hasRunningProcess() }
    }

    /// Running tabs that closing everything for `intent` would end: native
    /// ones, and persistent ones whose close action terminates their session
    /// (tabs that only detach, as in a window close or quit that keeps
    /// sessions running, are not counted). Drives the quit, window-close and
    /// worktree-removal confirmations.
    func sessionsWithRunningProcess(endingWith intent: SessionCloseIntent) -> [TerminalSession] {
        sessions.filter { session in
            backendPolicy.closeAction(for: session, intent: intent) != .detach && session.hasRunningProcess()
        }
    }

    /// Persistent tabs whose session closing everything for `intent` would
    /// end, running or not.
    func persistentSessionsEnded(by intent: SessionCloseIntent) -> [TerminalSession] {
        sessions.filter { session in
            session.isPersistentLocalSession && backendPolicy.closeAction(for: session, intent: intent) == .terminate
        }
    }

    /// What closing everything for `teardown` would do here, for its one
    /// confirmation: the persistent tabs whose program runs (a Create under
    /// way included), which its answer keeps running or ends, and the busy
    /// programs it stops either way or only when it ends sessions. `place`
    /// names this workspace in the question's list. Probes the process table
    /// (`hasRunningProcess`), so never from a SwiftUI body.
    func teardownSummary(
        _ teardown: SessionTeardown,
        place: String? = nil,
        pathDisplayMode: SidebarTerminalPathDisplayMode
    ) -> SessionTeardownSummary {
        let ending = teardown.intent(endingSessions: true)
        let running = persistentSessionsEnded(by: ending).filter(\.isProgramRunning).map { session in
            SessionTeardownSummary.Session(
                id: session.id,
                hostSessionID: session.persistentSession?.sessionID,
                title: SidebarSessionLabel.label(for: session, pathDisplayMode: pathDisplayMode).title,
                place: place,
                isBusy: session.hasRunningProcess(),
                machine: session.remoteMachineName
            )
        }
        return SessionTeardownSummary(
            runningSessions: running.filter(\.isBusy) + running.filter { !$0.isBusy },
            persistentTabCount: persistentSessionsEnded(by: ending).count,
            stoppedWhenKeeping: sessionsWithRunningProcess(endingWith: teardown.intent(endingSessions: false)).count,
            stoppedWhenEnding: sessionsWithRunningProcess(endingWith: ending).count
        )
    }

    var rootAgentSessions: [TerminalSession] {
        agentSessionTreeSnapshot().roots
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
        agentSessionTreeSnapshot().visibleItems(collapsedIDs: collapsedIDs)
    }

    func visibleAgentSessions(collapsedIDs: Set<UUID> = []) -> [TerminalSession] {
        visibleAgentTreeItems(collapsedIDs: collapsedIDs).map(\.session)
    }

    func agentSessionTreeSnapshot() -> AgentSessionTreeSnapshot {
        AgentSessionTreeSnapshot(sessions: sessions)
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
        }

        selectedSession?.setAuxiliaryProcessingActive(true)
    }

    func moveSession(id sessionID: UUID, to targetIndex: Int) {
        guard let currentIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return }

        let clampedIndex = min(max(targetIndex, 0), sessions.count - 1)
        guard currentIndex != clampedIndex else { return }

        // One assignment: observers never see the tab missing mid-move.
        var reordered = sessions
        let session = reordered.remove(at: currentIndex)
        reordered.insert(session, at: clampedIndex)
        sessions = reordered
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
        id: UUID = UUID(),
        title: String? = nil,
        workingDirectory: String? = nil,
        command: String? = nil,
        select: Bool = true,
        displayAsStandalone: Bool = true
    ) -> TerminalSession {
        // Match Ghostty's new-surface behavior: when no cwd is requested,
        // inherit the selected session's last trusted OSC 7 cwd report. In an
        // empty workspace (worktree spaces start with no sessions) fall back
        // to the project root rather than the process home directory. A tab
        // of This Mac's host (persistent, or attached to a local session)
        // seeds it like a native one; an SSH host's directory never seeds a
        // local shell. In a device's window (docs/specs/remote-devices.md,
        // rule 5) only a tab of the same host seeds it, with the directory
        // that host reported; otherwise the tab starts in the launch root.
        let hosting = persistentHostingForNewTab()
        let inheritedWorkingDirectory: String? = if let hosting, !hosting.profile.isThisMac {
            selectedSession.flatMap { $0.persistentHosting === hosting ? $0.workingDirectory.nilIfEmpty : nil }
        } else {
            selectedSession.flatMap { $0.reportsLocalWorkingDirectory ? $0.workingDirectory : nil }
        }
        let resolvedWorkingDirectory = workingDirectory ?? inheritedWorkingDirectory ?? launchRoot
        let session = Self.makeSession(
            id: unusedSessionID(id),
            index: sessions.count + 1,
            title: title,
            workingDirectory: resolvedWorkingDirectory,
            projectRoot: projectRoot,
            launchBackend: launchBackend,
            persistentHosting: hosting
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
        id: UUID = UUID(),
        agent: AgentToolDefinition,
        projectRoot: String,
        title: String? = nil,
        parentAgentID: UUID? = nil,
        select: Bool = true
    ) -> TerminalSession {
        let normalizedParentAgentID = normalizedParentAgentID(parentAgentID)
        let session = Self.makeAgentSession(
            id: unusedSessionID(id),
            index: agentSessions.count + 1,
            agent: agent,
            workingDirectory: ProjectLocation.launchPath(forKey: projectRoot),
            projectRoot: projectRoot,
            title: title,
            parentAgentID: normalizedParentAgentID,
            launchBackend: launchBackend,
            persistentHosting: persistentHostingForNewTab()
        )
        sessions.append(session)
        if select {
            self.select(session)
        }
        return session
    }

    /// `takeover` disconnects the session's other clients for this launch only.
    ///
    /// A session on This Mac that this app variant created, that no client
    /// shows and no open tab owns (`PersistentLocalSessions.canAdopt`)
    /// becomes this workspace's own persistent tab (`isPersistentLocalSession`)
    /// when the workspace runs local tabs in the host: it then closes and
    /// restarts like one, and keeps the kind, agent and command its tags
    /// name (`OrphanedSessionCriteria.record`), as Background Sessions ›
    /// Open and an orphan's adoption do. Everything else, including another
    /// app's or the CLI's sessions, is attached (`hostedAttachment`):
    /// closing the tab only disconnects it. `info` is the session as
    /// listed, when known.
    @discardableResult
    func attachHostedSession(
        _ attachment: HostedSessionAttachment,
        id: UUID = UUID(),
        takeover: Bool = false,
        launchShell: Bool = true,
        info: HostedSessionInfo? = nil
    ) -> TerminalSession {
        if let existing = hostedSession(attachedTo: attachment) {
            select(existing)
            if launchShell, takeover || !existing.isRunning {
                existing.reconnectHostedSession(takeover: takeover)
            }
            return existing
        }
        // A session of the host this workspace runs its persistent tabs on
        // (This Mac's, or a device's in its window).
        if let hosting = backendPolicy.localSessions,
           attachment.host == hosting.profile.host,
           launchBackend == .nativePTY,
           let info = info ?? hosting.sessionInfo(attachment.sessionID),
           info.id == attachment.sessionID,
           hosting.canAdopt(info) {
            // The tab the session was started for, when none is open: its
            // program's CHERRY_PROCESS_ID names that id.
            let startedFor = PersistentLocalSessions.tabID(of: info, owner: hosting.owner)
                .flatMap { hosting.hasOpenTab(withID: $0) ? nil : $0 }
            // Adopted as an orphan is (`OrphanedSessionCriteria.record`):
            // with the kind, agent and command its tags name, so an agent
            // stays one (MCP's permission-prompt guard) and the next save
            // keeps what it runs.
            var record = OrphanedSessionCriteria.record(
                for: info, tabID: unusedSessionID(startedFor ?? id), hostID: attachment.hostID, host: attachment.host
            )
            if record.title.isEmpty { record.title = attachment.name.nilIfEmpty ?? info.displayName }
            if record.projectRoot == nil { record.projectRoot = projectRoot }
            let session = makeRestoredPersistentSession(
                PersistentSessionLaunch(attachment: attachment, info: info),
                record: record,
                hosting: hosting,
                launchShell: launchShell,
                takeover: takeover
            )
            sessions.append(session)
            terminalDisplayItems.append(.single(session.id))
            select(session)
            return session
        }
        let session = makeHostedSession(
            attachment,
            id: unusedSessionID(id),
            title: attachment.name,
            titleSource: .explicit,
            takeover: takeover,
            launchShell: launchShell,
            info: info ?? backendPolicy.localSessions?.sessionInfo(attachment.sessionID)
        )
        sessions.append(session)
        terminalDisplayItems.append(.single(session.id))
        select(session)
        return session
    }

    /// A hosted tab for a saved record, built the way `attachHostedSession`
    /// builds one but not added: `restoreSessions(_:from:)` adds it with the
    /// saved layout. It keeps the record's tab id, title and metadata (kind,
    /// agent, parent agent, command, launch settings, project), so a
    /// command or agent comes back as one. `info`: the session as listed,
    /// when known (a session of This Mac then gives the tab its program's
    /// pid and directory).
    ///
    /// `deferringLaunch` (a restore): the adapter is launched later by
    /// `RestoredTabLaunchQueue` or when the tab is shown; meanwhile the tab
    /// follows its session's events through `control`. A session `info`
    /// lists as ended gets no adapter: the tab shows it ended, with the
    /// final screen read through `control`.
    func makeRestoredHostedSession(
        _ attachment: HostedSessionAttachment,
        record: WorkspaceSessionRecord,
        launchShell: Bool = true,
        info: HostedSessionInfo? = nil,
        deferringLaunch: Bool = false,
        following control: HostControl? = nil
    ) -> TerminalSession {
        let session = makeHostedSession(
            attachment,
            id: record.id,
            title: record.title.nilIfEmpty ?? attachment.name,
            titleSource: record.title.isEmpty ? .explicit : record.titleSource,
            takeover: false,
            launchShell: launchShell,
            info: info,
            record: record,
            deferringLaunch: deferringLaunch
        )
        if let control {
            session.attachedHostControlProvider = { _ in control }
        }
        if record.hasUnreadNotification == true { session.markUnread() }
        guard deferringLaunch, launchShell else { return session }
        if let info, !info.isRunning {
            session.showEndedHostedSession(
                exitCode: info.exitCode.map { Int32(clamping: $0) },
                signal: info.exitSignal,
                control: control
            )
        } else if let control {
            session.followDeferredHostEvents(from: control)
        }
        return session
    }

    private func makeHostedSession(
        _ attachment: HostedSessionAttachment,
        id: UUID,
        title: String,
        titleSource: TerminalSession.TitleSource,
        takeover: Bool,
        launchShell: Bool,
        info: HostedSessionInfo?,
        record: WorkspaceSessionRecord? = nil,
        deferringLaunch: Bool = false
    ) -> TerminalSession {
        // A session of This Mac starts where its host says (it then follows
        // OSC 7), else where it was saved; another machine's directory is
        // never local.
        let workingDirectory = attachment.host == .local
            ? Self.resolvedWorkingDirectory(
                info?.localWorkingDirectory ?? record?.workingDirectory ?? attachment.remoteWorkingDirectory
            )
            : NSHomeDirectory()
        let session = TerminalSession(
            id: id,
            title: title,
            titleSource: titleSource,
            subtitle: "\(attachment.host.displayName) · \(attachment.remoteWorkingDirectory)",
            tint: Self.palette[sessions.count % Self.palette.count],
            workingDirectory: workingDirectory,
            projectRoot: record?.projectRoot,
            launchShell: launchShell,
            kind: record?.kind ?? .terminal,
            agentName: record?.agentName,
            parentAgentID: record?.parentAgentID,
            commandName: record?.commandName,
            launchCommand: record?.launchCommand,
            launchEnvironment: record?.launchEnvironment ?? [:],
            restartOnExit: record?.restartOnExit ?? false,
            hostedAttachment: attachment,
            hostedTakeover: takeover,
            deferredLaunch: deferringLaunch
        )
        if attachment.host == .local, let hosting = backendPolicy.localSessions {
            session.attachedHostControlProvider = { _ in hosting.control }
        }
        if attachment.host.sshDestination != nil {
            session.hostReconnects = backendPolicy.hostReconnects
        }
        if let info {
            session.noteAttachedLocalSession(info)
        }
        return session
    }

    /// A persistent tab for a saved record whose session the local host
    /// still has (running or exited), built like the tab that saved it:
    /// same id, kind, title, launch settings and project. Not added:
    /// `restoreSessions(_:from:)` adds it with the saved layout. When an
    /// open tab (another window's) already owns the session, the record
    /// comes back only attached to it (`makeRestoredHostedSession`).
    ///
    /// `deferringLaunch` (a restore): the tab follows its session at once
    /// (exit, title, bells, input and screen through the host), and its
    /// attach adapter launches later (`RestoredTabLaunchQueue`, or when the
    /// tab is shown). An ended session gets no adapter at all: the tab
    /// shows its exit and the host's final screen.
    func makeRestoredPersistentSession(
        _ launch: PersistentSessionLaunch,
        record: WorkspaceSessionRecord,
        hosting: PersistentLocalSessions,
        launchShell: Bool = true,
        deferringLaunch: Bool = false,
        takeover: Bool = false,
        provisional: Bool = false
    ) -> TerminalSession {
        guard hosting.owningTab(of: launch.attachment.sessionID) == nil else {
            return makeRestoredHostedSession(
                launch.attachment, record: record, launchShell: launchShell, info: launch.info,
                deferringLaunch: deferringLaunch, following: deferringLaunch ? hosting.control : nil
            )
        }
        let workingDirectory = (hosting.profile.isThisMac
            ? launch.info.localWorkingDirectory
            : hosting.reportedWorkingDirectory(of: launch.info)) ?? record.workingDirectory
        let subtitle: String = switch record.kind {
        case .terminal: "\(ShellProcessController.defaultShellName) login shell"
        case .agent, .command: record.launchCommand ?? ""
        }
        let session = TerminalSession(
            id: record.id,
            title: record.title.nilIfEmpty ?? launch.info.displayName,
            titleSource: record.title.isEmpty ? .explicit : record.titleSource,
            subtitle: subtitle,
            tint: Self.palette[sessions.count % Self.palette.count],
            workingDirectory: Self.startingDirectory(
                hosting.profile.isThisMac ? workingDirectory : workingDirectory ?? launch.info.cwd.nilIfEmpty,
                hosting: hosting
            ),
            projectRoot: record.projectRoot,
            launchShell: launchShell,
            kind: record.kind,
            agentName: record.agentName,
            parentAgentID: record.parentAgentID,
            commandName: record.commandName,
            launchCommand: record.launchCommand,
            launchEnvironment: record.launchEnvironment,
            restartOnExit: record.restartOnExit,
            launchBackend: launchBackend,
            hostedTakeover: takeover,
            persistentHosting: hosting,
            adoptingPersistentSession: launch,
            deferredLaunch: deferringLaunch,
            provisionalRestore: provisional
        )
        if record.hasUnreadNotification == true { session.markUnread() }
        return session
    }

    /// A tab for a saved record whose session the system ended while
    /// Cherry was closed (a restart or log out, `SystemEndedSessions`),
    /// built like the tab that saved it (same id, kind, title, agent,
    /// parent agent, command, launch settings and project) but not
    /// launched: it shows how its session ended, and Restart starts its
    /// program again as a new session (a native tab when local tabs do not
    /// run as persistent sessions), in the tab's last directory, or where
    /// it started or its project when that is gone. Not added:
    /// `restoreSessions(_:from:)` adds it with the saved layout.
    func makeSystemEndedSession(record: WorkspaceSessionRecord, ended end: SystemSessionEnd) -> TerminalSession {
        let subtitle: String = switch record.kind {
        case .terminal: "\(ShellProcessController.defaultShellName) login shell"
        case .agent, .command: record.launchCommand ?? ""
        }
        // A device's tab (docs/specs/remote-devices.md): its directories
        // are that Mac's, never looked for here, and Restart starts it on
        // the device again whatever the local setting.
        let remoteHosting = backendPolicy.localSessions.flatMap { $0.profile.allowsNativeFallback ? nil : $0 }
        let workingDirectory: String
        if let remoteHosting {
            workingDirectory = Self.startingDirectory(
                record.workingDirectory.nilIfEmpty ?? record.launchWorkingDirectory ?? launchRoot,
                hosting: remoteHosting
            )
        } else {
            let directory = [record.workingDirectory, record.launchWorkingDirectory, record.projectRoot]
                .compactMap { $0 }
                .first { path in
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                }
            workingDirectory = Self.resolvedWorkingDirectory(directory)
        }
        let hosting = remoteHosting ?? (launchBackend == .nativePTY && backendPolicy.prefersPersistentLocalSessions
            ? backendPolicy.localSessions
            : nil)
        let session = TerminalSession(
            id: record.id,
            title: record.title.nilIfEmpty ?? record.commandName ?? record.agentName ?? "Shell",
            titleSource: record.title.isEmpty ? .explicit : record.titleSource,
            subtitle: subtitle,
            tint: Self.palette[sessions.count % Self.palette.count],
            workingDirectory: workingDirectory,
            projectRoot: record.projectRoot,
            launchShell: false,
            kind: record.kind,
            agentName: record.agentName,
            parentAgentID: record.parentAgentID,
            commandName: record.commandName,
            launchCommand: record.launchCommand,
            launchEnvironment: record.launchEnvironment,
            restartOnExit: record.restartOnExit,
            launchBackend: launchBackend,
            persistentHosting: hosting
        )
        session.showSystemSessionEnd(end, exitStatus: record.exitStatus)
        if record.hasUnreadNotification == true { session.markUnread() }
        return session
    }

    private func hostedSession(attachedTo attachment: HostedSessionAttachment) -> TerminalSession? {
        sessions.first {
            $0.hostedSessionBinding?.hostID == attachment.hostID
                && $0.hostedSessionBinding?.sessionID == attachment.sessionID
        }
    }

    /// Adds restored tabs with the saved order (an agent after its parent),
    /// display items, split groups and selection. A restored tab whose id
    /// or hosted session is already open, or a tab no saved record names,
    /// is detached and dropped.
    ///
    /// A command runs in one tab per workspace (auto-start and the sidebar
    /// find it by name). When a restored command meets a tab for the same
    /// command (opened while the restore ran, or restored before it), the
    /// one whose program runs keeps the command: a restored tab whose
    /// program runs replaces a tab whose program does not (that tab is
    /// closed); otherwise the restored tab is detached. When its program
    /// still runs, its record is returned (set aside): the caller keeps it
    /// saved, so its session is not forgotten.
    ///
    /// `selectingSavedTab`: the saved selection is selected (false for tabs
    /// a later retry brings back into a workspace in use).
    /// `addingAfterOpenTabs`: the tabs go after the tabs already open (tabs
    /// that come back later into a workspace in use) rather than before
    /// them (the restore that opened the workspace).
    /// `launchingAdapters`: restored tabs whose adapter a restore deferred
    /// are attached a few at a time (`restoredTabLaunchQueue`), the shown
    /// ones first; false leaves them to `launchRestoredAdapters()` (a
    /// worktree not shown now) or to being shown.
    @discardableResult
    func restoreSessions(
        _ restoredSessions: [TerminalSession],
        from record: WorktreeStateRecord,
        selectingSavedTab: Bool = true,
        addingAfterOpenTabs: Bool = false,
        launchingAdapters: Bool = true
    ) -> Set<UUID> {
        var recordsByID: [UUID: WorkspaceSessionRecord] = [:]
        var savedOrder: [UUID: Int] = [:]
        for (index, sessionRecord) in record.sessions.enumerated() where recordsByID[sessionRecord.id] == nil {
            recordsByID[sessionRecord.id] = sessionRecord
            savedOrder[sessionRecord.id] = index
        }

        var openIDs = Set(sessions.map(\.id))
        var accepted: [TerminalSession] = []
        var setAside: Set<UUID> = []
        // Open tabs a restored command tab replaces, with their replacement.
        var replaced: [(open: TerminalSession, replacement: TerminalSession)] = []
        for session in restoredSessions {
            let isDuplicateAttachment = session.hostedSessionBinding.map { attachment in
                hostedSession(attachedTo: attachment) != nil || accepted.contains {
                    $0.hostedSessionBinding?.hostID == attachment.hostID
                        && $0.hostedSessionBinding?.sessionID == attachment.sessionID
                }
            } ?? false
            guard recordsByID[session.id] != nil,
                  !isDuplicateAttachment,
                  !openIDs.contains(session.id)
            else {
                finishClosing(session, intent: .duplicateWindowTeardown)
                continue
            }
            if session.kind == .command, let name = session.commandName {
                let normalizedName = AgentToolDefinition.normalizedName(name)
                let sameCommand: (TerminalSession) -> Bool = { other in
                    other.kind == .command
                        && other.commandName.map { AgentToolDefinition.normalizedName($0) } == normalizedName
                }
                let replacedIDs = Set(replaced.map(\.open.id))
                let incumbent = accepted.first(where: sameCommand)
                    ?? commandSessions.first { sameCommand($0) && !replacedIDs.contains($0.id) }
                if let incumbent {
                    guard !Self.commandProgramRuns(incumbent), Self.commandProgramRuns(session) else {
                        if Self.commandProgramRuns(session) {
                            SessionLog.notice("command '\(name)' already has a tab; its restored tab \(session.id.uuidString) is set aside and stays saved")
                            setAside.insert(session.id)
                        }
                        finishClosing(session, intent: .duplicateWindowTeardown)
                        continue
                    }
                    if let index = accepted.firstIndex(where: { $0 === incumbent }) {
                        accepted.remove(at: index)
                        openIDs.remove(incumbent.id)
                        finishClosing(incumbent, intent: .duplicateWindowTeardown)
                    } else {
                        replaced.append((incumbent, session))
                    }
                }
            }
            openIDs.insert(session.id)
            accepted.append(session)
        }
        guard !accepted.isEmpty else { return setAside }
        accepted.sort { (savedOrder[$0.id] ?? .max) < (savedOrder[$1.id] ?? .max) }
        accepted = Self.parentsFirst(accepted)

        let displayableIDs = Set(accepted.filter { $0.kind == .terminal }.map(\.id))
        var restoredItems: [TerminalDisplayItem] = []
        var restoredGroups: [TerminalSplitGroup] = []
        var placedIDs = Set<UUID>()
        for item in record.displayItems {
            switch item.kind {
            case .single:
                guard displayableIDs.contains(item.id), placedIDs.insert(item.id).inserted else { continue }
                restoredItems.append(.single(item.id))
            case .split:
                guard let group = record.splitGroups.first(where: { $0.id == item.id }),
                      !terminalSplitGroups.contains(where: { $0.id == group.id }),
                      !restoredGroups.contains(where: { $0.id == group.id })
                else { continue }
                var paneIDs: [UUID] = []
                var weights: [Double] = []
                for (index, paneID) in group.paneSessionIDs.enumerated()
                where displayableIDs.contains(paneID) && !placedIDs.contains(paneID) && !paneIDs.contains(paneID) {
                    paneIDs.append(paneID)
                    weights.append(group.widthWeights.indices.contains(index) ? group.widthWeights[index] : 0)
                }
                if paneIDs.count > Self.maximumSplitPaneCount {
                    paneIDs = Array(paneIDs.prefix(Self.maximumSplitPaneCount))
                    weights = Array(weights.prefix(Self.maximumSplitPaneCount))
                }
                placedIDs.formUnion(paneIDs)
                if paneIDs.count >= 2 {
                    restoredGroups.append(TerminalSplitGroup(
                        id: group.id,
                        paneSessionIDs: paneIDs,
                        activeSessionID: paneIDs.contains(group.activeSessionID) ? group.activeSessionID : paneIDs[0],
                        widthWeights: Self.normalizedWidthWeights(weights, count: paneIDs.count)
                    ))
                    restoredItems.append(.split(group.id))
                } else if let paneID = paneIDs.first {
                    restoredItems.append(.single(paneID))
                }
            }
        }
        for session in accepted where displayableIDs.contains(session.id) && !placedIDs.contains(session.id) {
            restoredItems.append(.single(session.id))
        }

        for session in accepted {
            restoredSessionRecords[session.id] = recordsByID[session.id]
        }
        if addingAfterOpenTabs {
            sessions += accepted
            terminalSplitGroups += restoredGroups
            terminalDisplayItems += restoredItems
        } else {
            sessions = accepted + sessions
            terminalSplitGroups = restoredGroups + terminalSplitGroups
            terminalDisplayItems = restoredItems + terminalDisplayItems
        }
        // A tab replaced by a restored one (its program did not run) closes
        // as a user's close would; the selection moves to its replacement.
        for (open, replacement) in replaced {
            closeSessions(
                withIDs: [open.id],
                replacementSelectionID: replacement.id,
                allowEmptyWorkspace: true,
                intent: .userClosedTab
            )
        }

        let savedSelection = selectingSavedTab
            ? record.selectedSessionID.flatMap { selectedID in accepted.first { $0.id == selectedID } }
            : nil
        if let savedSelection {
            select(savedSelection)
        } else if selectedSessionID.flatMap(session(withID:)) == nil,
                  let first = terminalDisplaySessions.first ?? sessions.first {
            select(first)
        }
        for session in accepted where session.id != selectedSessionID {
            session.scheduleAuxiliaryProcessingSuspensionAfterStartupGrace()
        }
        if launchingAdapters {
            launchRestoredAdapters(accepted)
        }
        return setAside
    }

    /// Queues the attach adapters that restored tabs are still waiting for
    /// (`restoredTabLaunchQueue`): the selected tab and the other panes of
    /// its split first. A worktree's workspace calls this when it is shown.
    func launchRestoredAdapters() {
        launchRestoredAdapters(sessions)
    }

    private func launchRestoredAdapters(_ tabs: [TerminalSession]) {
        let waiting = tabs.filter(\.isAwaitingDeferredLaunch)
        guard !waiting.isEmpty else { return }
        var shownIDs: Set<UUID> = []
        if let selectedSessionID {
            shownIDs = Set(splitGroup(containing: selectedSessionID)?.paneSessionIDs ?? [selectedSessionID])
        }
        restoredTabLaunchQueue.enqueue(waiting, shownFirst: shownIDs)
    }

    /// Whether a command tab's program runs, or (for a restored tab not
    /// attached yet) its session does.
    private static func commandProgramRuns(_ tab: TerminalSession) -> Bool {
        tab.isRunning || tab.isAwaitingDeferredLaunch
    }

    // MARK: Commands a restore may bring back

    /// How long a command start waits for a restore that may bring back the
    /// command's tab (`waitUntilRestored(commandNamed:)`).
    static let commandRestoreWaitLimit: Duration = .seconds(10)

    /// Normalized names of the commands whose saved tabs a restore still
    /// under way may bring back (`RepositoryWorkspace` sets them). Starting
    /// one of them now would start a second copy beside the program its
    /// restored tab follows: `waitUntilRestored(commandNamed:)` waits for
    /// the restore first.
    private(set) var commandNamesBeingRestored: Set<String> = []
    private var commandRestoreWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func setCommandNamesBeingRestored(_ names: Set<String>) {
        let normalized = Set(names.map(AgentToolDefinition.normalizedName))
        guard normalized != commandNamesBeingRestored else { return }
        commandNamesBeingRestored = normalized
        resumeCommandRestoreWaiters()
    }

    /// Whether a restore under way may bring back a tab for the named
    /// command (nil: for any command).
    func isRestoringCommand(named name: String?) -> Bool {
        guard let name else { return !commandNamesBeingRestored.isEmpty }
        return commandNamesBeingRestored.contains(AgentToolDefinition.normalizedName(name))
    }

    /// Returns once no restore under way may bring back a tab for the named
    /// command (nil: for any command), or after `timeout`. Sidebar and MCP
    /// command starts wait here, then find the restored tab
    /// (`addCommandSession` returns it) instead of starting a second copy.
    func waitUntilRestored(commandNamed name: String?, timeout: Duration = TerminalWorkspace.commandRestoreWaitLimit) async {
        let deadline = ContinuousClock.now + timeout
        while isRestoringCommand(named: name), !isTornDown, ContinuousClock.now < deadline {
            let id = UUID()
            let timer = Task { @MainActor [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                self?.resumeCommandRestoreWaiter(id)
            }
            await withCheckedContinuation { commandRestoreWaiters[id] = $0 }
            timer.cancel()
        }
    }

    private func resumeCommandRestoreWaiter(_ id: UUID) {
        commandRestoreWaiters.removeValue(forKey: id)?.resume()
    }

    private func resumeCommandRestoreWaiters() {
        let waiters = commandRestoreWaiters
        commandRestoreWaiters.removeAll()
        waiters.values.forEach { $0.resume() }
    }

    /// `tabs` in the same order, except that an agent comes after the agent
    /// it names as parent (when that one is among them).
    static func parentsFirst(_ tabs: [TerminalSession]) -> [TerminalSession] {
        let ids = Set(tabs.map(\.id))
        var placed: Set<UUID> = []
        var ordered: [TerminalSession] = []
        var waiting: [UUID: [TerminalSession]] = [:]
        func place(_ tab: TerminalSession) {
            guard placed.insert(tab.id).inserted else { return }
            ordered.append(tab)
            for child in waiting.removeValue(forKey: tab.id) ?? [] {
                place(child)
            }
        }
        for tab in tabs {
            if let parentID = tab.parentAgentID, parentID != tab.id, ids.contains(parentID), !placed.contains(parentID) {
                waiting[parentID, default: []].append(tab)
            } else {
                place(tab)
            }
        }
        // Parents that name each other: saved order.
        for tab in tabs where !placed.contains(tab.id) {
            place(tab)
        }
        return ordered
    }

    /// This workspace's tabs and layout as workspace persistence saves them.
    func makeStateRecord(root: String, collapsedAgentGroupIDs: Set<UUID>) -> WorktreeStateRecord {
        let sessionIDs = Set(sessions.map(\.id))
        return WorktreeStateRecord(
            root: root,
            sessions: sessions.map { session in
                WorkspaceSessionRecord(session: session, restoredRecord: restoredSessionRecords[session.id])
            },
            displayItems: terminalDisplayItems.map(WorkspaceDisplayItemRecord.init),
            splitGroups: terminalSplitGroups.map(WorkspaceSplitGroupRecord.init),
            selectedSessionID: selectedSessionID.flatMap { sessionIDs.contains($0) ? $0 : nil },
            collapsedAgentGroupIDs: collapsedAgentGroupIDs
                .filter(sessionIDs.contains)
                .sorted { $0.uuidString < $1.uuidString }
        )
    }

    @discardableResult
    func addCommandSession(
        id: UUID = UUID(),
        command: ProjectCommandDefinition,
        projectRoot: String,
        select: Bool = true
    ) -> TerminalSession {
        // A restored hosted tab runs its command as a terminal until hosted
        // tabs carry their kind; it still counts as that command's tab.
        if let session = commandSession(named: command.name) ?? restoredSession(forCommandNamed: command.name) {
            if select {
                self.select(session)
            }
            return session
        }

        let session = Self.makeCommandSession(
            id: unusedSessionID(id),
            index: commandSessions.count + 1,
            command: command,
            workingDirectory: command.resolvedWorkingDirectory(projectRoot: projectRoot),
            projectRoot: projectRoot,
            launchBackend: launchBackend,
            persistentHosting: persistentHostingForNewTab()
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

        let workingDirectory = launchRoot ?? NSHomeDirectory()
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
                parentAgentID: parentAgentID,
                launchBackend: launchBackend
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

    /// A restored tab saved as the named command's tab.
    func restoredSession(forCommandNamed name: String) -> TerminalSession? {
        let normalizedName = AgentToolDefinition.normalizedName(name)
        return sessions.first { session in
            guard let record = restoredSessionRecords[session.id], record.kind == .command else { return false }
            return record.commandName.map { AgentToolDefinition.normalizedName($0) } == normalizedName
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

    /// A local terminal, native or persistent, can be split: the new pane is
    /// a new tab of the same kind in the active pane's directory (for a
    /// persistent tab, a new session in the local host). A tab attached to
    /// a hosted session cannot: its directory is its host's.
    func canAddSplitPane(to sessionID: UUID) -> Bool {
        guard let session = session(withID: sessionID), session.kind == .terminal,
              session.hostedAttachment == nil else { return false }
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
            closeSessions(withIDs: Set([session.id]), intent: .userClosedTab)
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
              // A tab attached to a hosted session stays on its own, as the
              // active pane would (`canAddSplitPane`).
              session.hostedAttachment == nil,
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

    func closeSplitGroup(id groupID: UUID, intent: SessionCloseIntent = .userClosedTab) {
        guard let group = splitGroup(id: groupID),
              canCloseSplitGroup(id: groupID)
        else {
            return
        }
        closeSessions(withIDs: Set(group.paneSessionIDs), intent: intent)
    }

    func close(
        _ session: TerminalSession,
        allowEmptyWorkspace: Bool = false,
        intent: SessionCloseIntent = .userClosedTab
    ) {
        if session.kind == .agent {
            promoteChildAgents(of: session)
        }
        closeSessions(
            withIDs: Set([session.id]),
            replacementSelectionID: replacementPaneSelection(afterClosing: session.id),
            allowEmptyWorkspace: allowEmptyWorkspace,
            intent: intent
        )
    }

    func closeAgentGroup(
        _ session: TerminalSession,
        allowEmptyWorkspace: Bool = false,
        intent: SessionCloseIntent = .userClosedTab
    ) {
        let groupIDs = Set(([session] + descendantAgentSessions(of: session)).map(\.id))
        closeSessions(withIDs: groupIDs, allowEmptyWorkspace: allowEmptyWorkspace, intent: intent)
    }

    func closeAgentPromotingChildren(_ session: TerminalSession, intent: SessionCloseIntent = .userClosedTab) {
        promoteChildAgents(of: session)
        closeSessions(withIDs: Set([session.id]), intent: intent)
    }

    /// Closes every tab. The default is a window teardown; production callers
    /// name the intent. Tabs a quit's teardown left to the app's exit
    /// (`closeSessionsForQuit`) close too.
    func closeAllSessions(intent: SessionCloseIntent = .windowClosed) {
        let removedSessions = removeAllSessions(intent: intent) + tabsLeftToTheExit
        tabsLeftToTheExit.removeAll()
        leavesTabsToTheExit = false
        removedSessions.forEach { finishClosing($0, intent: intent) }
    }

    /// A confirmed quit's teardown (`ProjectWindowRegistry.tearDownForQuit`):
    /// every tab leaves the workspace, as in `closeAllSessions`, but only the
    /// tabs whose close does what the app's exit does not are closed: native
    /// tabs, whose process trees are stopped (the exit only hangs up their
    /// terminals, which a server ignoring SIGHUP outlives), and persistent
    /// tabs whose sessions `intent` ends. The others (persistent tabs a
    /// quit keeping sessions leaves running, tabs attached to sessions they
    /// do not own) are left as they are until the app exits, as a quit that
    /// tears nothing down leaves them: their attach adapters end with the
    /// app, their sessions run on in their holders, and their records,
    /// saved before the teardown, bring them back. A Create under way keeps
    /// the session it makes, which the tab's record names. Stopping each
    /// adapter and freeing each surface would only hold the quit up (about
    /// 20 ms a tab). Returns whether a native tab's program was busy
    /// (`hasRunningProcess`, as the quit counted it) when it was stopped:
    /// the quit then waits for its HUP → TERM → KILL escalation. An idle
    /// shell's HUP goes out at once, and the escalation is not waited for,
    /// as a quit that tears nothing down does not wait for it either.
    func closeSessionsForQuit(intent: SessionCloseIntent) -> Bool {
        leavesTabsToTheExit = true
        var stoppedNativeProgram = false
        for session in removeAllSessions(intent: intent) {
            let action = backendPolicy.closeAction(for: session, intent: intent)
            stoppedNativeProgram = stoppedNativeProgram || (action == .stop && session.hasRunningProcess())
            finishClosingForQuit(session, intent: intent, action: action)
        }
        return stoppedNativeProgram
    }

    /// Empties the workspace for closing every tab with `intent`, and
    /// returns the tabs that were in it.
    private func removeAllSessions(intent: SessionCloseIntent) -> [TerminalSession] {
        if intent.tearsDownWorkspace {
            isTornDown = true
            resumeCommandRestoreWaiters()
        }
        closeAllIntent = intent
        let removedSessions = sessions
        sessions.removeAll()
        restoredSessionRecords.removeAll()
        terminalDisplayItems.removeAll()
        terminalSplitGroups.removeAll()
        selectedSessionID = nil
        return removedSessions
    }

    /// Tabs a quit's teardown left to the app's exit (`closeSessionsForQuit`),
    /// held so that their surfaces are not freed meanwhile.
    private var tabsLeftToTheExit: [TerminalSession] = []
    /// A quit's teardown closed the workspace: tabs a restore finishes
    /// afterwards are left to the exit the same way.
    private var leavesTabsToTheExit = false

    /// `finishClosing` for a quit's teardown, except for a tab whose close
    /// only disconnects it (its action detaches, or it is attached to a
    /// session it does not own): that one is left to the app's exit.
    private func finishClosingForQuit(_ session: TerminalSession, intent: SessionCloseIntent, action: SessionCloseAction) {
        guard action == .detach || session.hostedAttachment != nil else {
            finishClosing(session, intent: intent)
            return
        }
        session.keepSessionUntilExit()
        tabsLeftToTheExit.append(session)
    }

    /// Ends tabs a restore built for this workspace after every tab was
    /// closed, with the intent that closed them (a window close if none did).
    /// Takes out tabs a restore showed before their host answered and then
    /// did not keep (`OptimisticRestore`): their sessions are left as they
    /// are (the restore decided what becomes of them), nothing asks or
    /// counts as a close, and an emptied workspace stays empty for the
    /// restore to fill.
    /// Takes `tabs` out, leaving them running and unclosed, for
    /// `restoreSessions` to put back at once with a saved layout (a
    /// restore that showed some of a window's tabs before its host
    /// answered lays them out again with the others). The selection is
    /// left as it is.
    func takeOutForLayout(_ tabs: [TerminalSession]) {
        let ids = Set(tabs.map(\.id))
        guard !ids.isEmpty else { return }
        sessions.removeAll { ids.contains($0.id) }
        terminalSplitGroups = terminalSplitGroups.compactMap { group in
            var group = group
            let panes = group.paneSessionIDs.filter { !ids.contains($0) }
            guard panes.count >= 2 else { return nil }
            group.paneSessionIDs = panes
            if !panes.contains(group.activeSessionID) { group.activeSessionID = panes[0] }
            group.widthWeights = TerminalSplitGroup.balancedWeights(count: panes.count)
            return group
        }
        let groupIDs = Set(terminalSplitGroups.map(\.id))
        terminalDisplayItems = terminalDisplayItems.compactMap { item in
            switch item {
            case .single(let id): return ids.contains(id) ? nil : item
            case .split(let id): return groupIDs.contains(id) ? item : nil
            }
        }
        // A pane of a split that lost its others stands alone again.
        let placed = Set(terminalDisplayItems.flatMap { item -> [UUID] in
            switch item {
            case .single(let id): return [id]
            case .split(let id): return terminalSplitGroups.first { $0.id == id }?.paneSessionIDs ?? []
            }
        })
        for tab in sessions where tab.kind == .terminal && !placed.contains(tab.id) {
            terminalDisplayItems.append(.single(tab.id))
        }
    }

    /// Whether a restore still decides the record of this id, whose tab it
    /// showed before its host answered (`RepositoryWorkspace`, for ⌘Z of
    /// such a tab: `reopenClosedTab`).
    var awaitsRestoreDecision: (@MainActor (UUID) -> Bool)?

    func withdrawRestoredTabs(_ tabs: [TerminalSession]) {
        let ids = Set(tabs.map(\.id)).intersection(sessions.lazy.filter { tab in tabs.contains { $0 === tab } }.map(\.id))
        closeSessions(withIDs: ids, allowEmptyWorkspace: true, intent: .duplicateWindowTeardown)
    }

    /// Puts `replacement`, a restored tab for the same saved record (same
    /// id), in the place of `tab`, one a restore showed before its host
    /// answered and then did not keep: the same place, layout and
    /// selection; `tab`'s session is left as it is. False when `tab` is not
    /// here (nothing changes).
    @discardableResult
    func replaceRestoredTab(_ tab: TerminalSession, with replacement: TerminalSession) -> Bool {
        guard tab.id == replacement.id, let index = sessions.firstIndex(where: { $0 === tab }) else { return false }
        sessions[index] = replacement
        finishClosing(tab, intent: .duplicateWindowTeardown)
        if selectedSessionID == replacement.id {
            select(replacement)
        } else {
            replacement.scheduleAuxiliaryProcessingSuspensionAfterStartupGrace()
        }
        launchRestoredAdapters([replacement])
        return true
    }

    func discardRestoredSessions(_ restoredSessions: [TerminalSession]) {
        let intent = closeAllIntent ?? .windowClosed
        for session in restoredSessions {
            if leavesTabsToTheExit {
                finishClosingForQuit(session, intent: intent, action: backendPolicy.closeAction(for: session, intent: intent))
            } else {
                finishClosing(session, intent: intent)
            }
        }
    }

    func closeSelectedSession(intent: SessionCloseIntent = .userClosedTab) {
        guard let selectedSession else { return }
        close(selectedSession, intent: intent)
    }

    func closeActivePane(intent: SessionCloseIntent = .userClosedTab) {
        guard let selectedSession else { return }
        close(selectedSession, intent: intent)
    }

    /// Ends a removed tab's program the way `intent` asks for its backend.
    private func finishClosing(_ session: TerminalSession, intent: SessionCloseIntent) {
        // A persistent tab whose program already ended leaves nothing worth
        // keeping when someone closes or detaches it, or it closes because
        // its shell exited: its session goes whatever the intent.
        let removesEndedSession = session.isPersistentLocalSession && !session.isRunning
            && [.userClosedTab, .userDetachedTab, .mcpClose, .programExited].contains(intent)
        if intent == .programExited {
            // Its last lines stay readable once its surface and session are
            // gone, for a wait under way (MCP `wait_for_process_idle`).
            session.keepContentAfterClosing()
        }
        // Snapshot and stop the native process tree while its PTY still
        // exists; releasing the bridge first loses the teardown anchor.
        switch backendPolicy.closeAction(for: session, intent: intent) {
        case .stop:
            session.stop()
        case .detach:
            // A tab the user detached (⌘D, Detach) keeps its own session
            // running in the background, where they know it is. Not one
            // whose Create is under way (no session yet), nor one only
            // attached to a session it does not own.
            let detachedSessionID = intent == .userDetachedTab && !removesEndedSession
                && session.isPersistentLocalSession
                ? session.persistentSession?.sessionID
                : nil
            // For a hosted tab, stopping ends only its local attach client;
            // a persistent tab still creating its session keeps the one its
            // Create makes (its saved record names it).
            session.stop(keepingSession: !removesEndedSession)
            if removesEndedSession {
                endHostedSession(of: session, intent: intent)
            } else if let detachedSessionID {
                backendPolicy.sessionDetached(detachedSessionID)
            }
        case .terminate:
            session.stop()
            endHostedSession(of: session, intent: intent)
        }
        session.persistentTabDidClose()
        // Ports of another Mac forwarded for it (`RemotePortForwards`).
        RemotePortForwards.existing?.release(owner: session.id)
        session.releaseGhosttyBridge()
    }

    /// Ends a closed persistent tab's session for `intent`; or, while
    /// `deferringSessionEnds` runs, leaves the session of a tab a user
    /// closed or detached to its caller.
    private func endHostedSession(of session: TerminalSession, intent: SessionCloseIntent) {
        if sessionEndsLeftForUndo != nil, intent == .userClosedTab || intent == .userDetachedTab,
           session.isPersistentLocalSession, session.persistentSession != nil {
            sessionEndsLeftForUndo?.append(session)
        } else {
            backendPolicy.terminateHostedSession(session, intent)
        }
    }

    // MARK: Closed tabs that come back (⌘Z)

    /// While `deferringSessionEnds` runs: the closed tabs whose sessions were
    /// left to its caller.
    private var sessionEndsLeftForUndo: [TerminalSession]?

    /// Runs `close`, in which a user's close (`userClosedTab`) of this app's
    /// own persistent tab only stops the tab's adapter, as a detach does:
    /// its session, which the close would end (or remove, when its program
    /// ended), is left to the caller, which ends it once the close can no
    /// longer be undone (`ClosedTabHistory`, `PersistentLocalSessions.deferEnd`).
    /// A tab whose Create is under way (no session yet) ends as usual.
    /// Returns the tabs whose sessions were left.
    func deferringSessionEnds(_ close: () -> Void) -> [TerminalSession] {
        let outer = sessionEndsLeftForUndo
        sessionEndsLeftForUndo = []
        close()
        let left = sessionEndsLeftForUndo ?? []
        sessionEndsLeftForUndo = outer
        return left
    }

    /// What undoing a user's close or detach of `session` brings back, read
    /// before the tab closes (`ClosedTab`): its record, the host session it
    /// shows and where it is. Nil for a tab no undo brings back: a native
    /// tab, or a persistent tab whose Create is under way.
    func closedTab(for session: TerminalSession, name: String) -> ClosedTab? {
        guard let index = sessions.firstIndex(where: { $0 === session }) else { return nil }
        let binding: HostedSessionAttachment
        if let attachment = session.hostedAttachment {
            binding = attachment
        } else if session.isPersistentLocalSession, let persistent = session.persistentSession {
            binding = persistent
        } else {
            return nil
        }
        var display: ClosedTabPlacement.Display?
        if let group = splitGroup(containing: session.id),
           let displayIndex = terminalDisplayItems.firstIndex(of: .split(group.id)) {
            display = .pane(
                groupID: group.id,
                displayIndex: displayIndex,
                paneIDs: group.paneSessionIDs,
                widthWeights: group.widthWeights
            )
        } else if let displayIndex = terminalDisplayItems.firstIndex(of: .single(session.id)) {
            display = .standalone(index: displayIndex)
        }
        return ClosedTab(
            record: WorkspaceSessionRecord(session: session, restoredRecord: restoredSessionRecords[session.id]),
            name: name,
            binding: binding,
            ownsSession: session.hostedAttachment == nil,
            placement: ClosedTabPlacement(
                sessionIndex: index,
                display: display,
                wasSelected: selectedSessionID == session.id,
                subAgentIDs: session.kind == .agent ? childAgentSessions(of: session).map(\.id) : []
            )
        )
    }

    /// Brings a closed tab back where it was (`ClosedTab`), for undo: a tab
    /// built as a restore builds one (same id, kind, title, agent, command
    /// and launch settings) for the same host session, which it attaches to
    /// again without a Create: its own again for this app's persistent tab,
    /// else attached. It goes back to its place among the tabs, in the
    /// sidebar and in its split (`ClosedTabPlacement`), and the sub-agents
    /// its close promoted become its sub-agents again. A tab here showing
    /// that session already (Background Sessions → Open brought it back) is
    /// returned instead; for a tab that owned its session, only a tab that
    /// owns it (a tab only attached to it leaves it to come back as the
    /// closed tab's own). Nil when the session is gone, being ended, or
    /// another tab owns it, when its command runs in another tab now (a
    /// command runs in one tab per workspace: it was started again), or
    /// when the workspace was torn down. Not selected.
    func reopenClosedTab(_ closed: ClosedTab) -> TerminalSession? {
        guard !isTornDown else { return nil }
        /// A tab here shows the session as the closed tab did.
        func showsSession(_ open: TerminalSession) -> Bool {
            guard let binding = closed.ownsSession ? open.persistentSession : open.hostedSessionBinding else {
                return false
            }
            return binding.hostID == closed.binding.hostID && binding.sessionID == closed.binding.sessionID
        }
        if let open = session(withID: closed.record.id) {
            return showsSession(open) ? open : nil
        }
        if let open = sessions.first(where: showsSession) {
            return open
        }
        if closed.record.kind == .command, let name = closed.record.commandName,
           commandSession(named: name) ?? restoredSession(forCommandNamed: name) != nil {
            return nil
        }
        let tab: TerminalSession
        if closed.ownsSession {
            let sessionID = closed.binding.sessionID
            guard launchBackend == .nativePTY,
                  let hosting = backendPolicy.localSessions,
                  hosting.owningTab(of: sessionID) == nil,
                  !hosting.isEnding(sessionID)
            else { return nil }
            var provisional = false
            let info: HostedSessionInfo
            if let listed = hosting.sessionInfo(sessionID) {
                info = listed
            } else if !hosting.control.hasListedSessions, let binding = closed.record.hosted {
                // The host has not listed yet (a tab shown before it answered,
                // `OptimisticRestore`): the tab comes back as the record
                // says, provisional while the restore still decides its
                // record, and its session is left running.
                info = OptimisticRestore.assumedInfo(of: closed.record, binding: binding, owner: hosting.owner)
                provisional = awaitsRestoreDecision?(closed.record.id) ?? false
            } else {
                return nil
            }
            tab = makeRestoredPersistentSession(
                PersistentSessionLaunch(attachment: closed.binding, info: info),
                record: closed.record,
                hosting: hosting,
                deferringLaunch: true,
                provisional: provisional
            )
        } else {
            let info = closed.binding.host == .local
                ? backendPolicy.localSessions?.sessionInfo(closed.binding.sessionID)
                : nil
            tab = makeRestoredHostedSession(closed.binding, record: closed.record, info: info)
        }
        insertClosedTab(tab, record: closed.record, placement: closed.placement)
        launchRestoredAdapters([tab])
        return tab
    }

    /// Puts `tab` at `placement`: at its index among the tabs, its display
    /// item where it was (a pane goes back into its split group, which is
    /// made again when only one other pane was left, or when another pane
    /// of it comes back after it), and its promoted sub-agents under it.
    private func insertClosedTab(_ tab: TerminalSession, record: WorkspaceSessionRecord, placement: ClosedTabPlacement) {
        sessions.insert(tab, at: min(placement.sessionIndex, sessions.count))
        restoredSessionRecords[tab.id] = record
        if tab.kind == .terminal {
            switch placement.display {
            case .standalone(let index):
                terminalDisplayItems.insert(.single(tab.id), at: min(index, terminalDisplayItems.count))
            case .pane(let groupID, let displayIndex, let paneIDs, let widthWeights):
                insertClosedPane(
                    tab.id, groupID: groupID, displayIndex: displayIndex, paneIDs: paneIDs, widthWeights: widthWeights
                )
            case nil:
                terminalDisplayItems.append(.single(tab.id))
            }
        }
        for childID in placement.subAgentIDs {
            // Unless another agent took it meanwhile.
            guard let child = session(withID: childID), child.kind == .agent, child.parentAgentID == nil else { continue }
            child.setParentAgentID(tab.id)
        }
    }

    private func insertClosedPane(
        _ paneID: UUID,
        groupID: UUID,
        displayIndex: Int,
        paneIDs: [UUID],
        widthWeights: [Double]
    ) {
        /// The weights `panes` had then, as far as they were in the group.
        func weights(for panes: [UUID]) -> [Double] {
            let known = panes.map { pane in
                paneIDs.firstIndex(of: pane).flatMap { widthWeights.indices.contains($0) ? widthWeights[$0] : nil }
                    ?? 1 / Double(max(paneIDs.count, 1))
            }
            return Self.normalizedWidthWeights(known, count: panes.count) ?? TerminalSplitGroup.balancedWeights(count: panes.count)
        }
        let later = Set(paneIDs.drop { $0 != paneID }.dropFirst())
        if let groupIndex = terminalSplitGroups.firstIndex(where: { $0.id == groupID }) {
            // Its group is still there: it goes back before the panes that
            // followed it.
            var group = terminalSplitGroups[groupIndex]
            guard group.paneSessionIDs.count < Self.maximumSplitPaneCount else {
                let after = terminalDisplayItems.firstIndex(of: .split(groupID)).map { $0 + 1 } ?? terminalDisplayItems.count
                terminalDisplayItems.insert(.single(paneID), at: after)
                return
            }
            let position = group.paneSessionIDs.firstIndex(where: later.contains) ?? group.paneSessionIDs.count
            group.paneSessionIDs.insert(paneID, at: position)
            group.widthWeights = weights(for: group.paneSessionIDs)
            terminalSplitGroups[groupIndex] = group
            return
        }
        if let otherIndex = terminalDisplayItems.firstIndex(where: { item in
            guard case .single(let other) = item else { return false }
            return other != paneID && paneIDs.contains(other)
        }), case .single(let other) = terminalDisplayItems[otherIndex] {
            // The one pane its close left became a tab of its own: they
            // are a split again.
            let panes = paneIDs.filter { $0 == paneID || $0 == other }
            terminalSplitGroups.append(TerminalSplitGroup(
                id: groupID, paneSessionIDs: panes, activeSessionID: other, widthWeights: weights(for: panes)
            ))
            terminalDisplayItems[otherIndex] = .split(groupID)
            return
        }
        // Its whole group closed: a tab of its own where the group was,
        // until another of its panes comes back.
        terminalDisplayItems.insert(.single(paneID), at: min(displayIndex, terminalDisplayItems.count))
    }

    func selectPreviousSession(visibleCommandNames: [String]? = nil) {
        selectSession(offset: -1, visibleCommandNames: visibleCommandNames)
    }

    func selectNextSession(visibleCommandNames: [String]? = nil) {
        selectSession(offset: 1, visibleCommandNames: visibleCommandNames)
    }


    func restartSelectedSession() {
        guard let selectedSession else { return }
        restart(selectedSession)
    }

    /// Relaunches a tab in place: a native tab restarts its program, an
    /// attached tab reconnects its attach client, and a persistent tab ends
    /// its session and starts a new one for the same tab id (its restart
    /// does both, `TerminalSession.restart()`). Returns false when nothing
    /// was relaunched because an attached session ended.
    @discardableResult
    func restart(_ session: TerminalSession) -> Bool {
        switch backendPolicy.closeAction(for: session, intent: .restart) {
        case .stop, .detach, .terminate:
            return session.restart()
        }
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

    func acknowledgeAttentionForSelectedSession() {
        guard let selectedSessionID,
              let session = sessions.first(where: { $0.id == selectedSessionID })
        else {
            return
        }
        session.acknowledgeAttentionAlert()
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
        allowEmptyWorkspace: Bool = false,
        intent: SessionCloseIntent
    ) {
        guard !removedIDs.isEmpty,
              allowEmptyWorkspace || sessions.count > removedIDs.count
        else {
            return
        }

        let removedIndex = sessions.firstIndex { removedIDs.contains($0.id) }
        let removedSessions = sessions.filter { removedIDs.contains($0.id) }
        sessions.removeAll { removedIDs.contains($0.id) }
        removedSessions.forEach { restoredSessionRecords[$0.id] = nil }
        removeClosedSessionsFromTerminalDisplay(removedIDs)
        removedSessions.forEach { finishClosing($0, intent: intent) }

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
        id: UUID = UUID(),
        index: Int,
        title: String? = nil,
        workingDirectory: String? = nil,
        projectRoot: String? = nil,
        launchBackend: TerminalSessionLaunchBackend,
        persistentHosting: PersistentLocalSessions? = nil
    ) -> TerminalSession {
        let explicitTitle = title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        return TerminalSession(
            id: id,
            title: explicitTitle ?? "Shell \(index)",
            titleSource: explicitTitle == nil ? .system : .explicit,
            subtitle: "\(ShellProcessController.defaultShellName) login shell",
            tint: palette[(index - 1) % palette.count],
            workingDirectory: Self.startingDirectory(workingDirectory, hosting: persistentHosting),
            projectRoot: projectRoot,
            launchBackend: launchBackend,
            persistentHosting: persistentHosting
        )
    }

    /// Where a new tab starts: an existing directory of This Mac (else the
    /// home directory), or, for a tab of another Mac's host, the path as
    /// given (that host refuses one that does not exist; `~` without one).
    private static func startingDirectory(_ path: String?, hosting: PersistentLocalSessions?) -> String {
        if let hosting, !hosting.profile.isThisMac {
            return path?.nilIfEmpty ?? "~"
        }
        return resolvedWorkingDirectory(path)
    }

    private static func makeAgentSession(
        id: UUID,
        index: Int,
        agent: AgentToolDefinition,
        workingDirectory: String,
        projectRoot: String,
        title requestedTitle: String?,
        parentAgentID: UUID?,
        launchBackend: TerminalSessionLaunchBackend,
        persistentHosting: PersistentLocalSessions?
    ) -> TerminalSession {
        let baseTitle = agent.name.isEmpty ? "Agent" : agent.name
        let explicitTitle = requestedTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        return TerminalSession(
            id: id,
            title: explicitTitle ?? baseTitle,
            titleSource: explicitTitle == nil ? .system : .explicit,
            subtitle: agent.commandLine,
            tint: palette[(index - 1) % palette.count],
            workingDirectory: Self.startingDirectory(workingDirectory, hosting: persistentHosting),
            projectRoot: projectRoot,
            kind: .agent,
            agentName: agent.name,
            parentAgentID: parentAgentID,
            launchCommand: agent.commandLine,
            launchBackend: launchBackend,
            persistentHosting: persistentHosting
        )
    }

    private static func makeCommandSession(
        id: UUID,
        index: Int,
        command: ProjectCommandDefinition,
        workingDirectory: String,
        projectRoot: String,
        launchBackend: TerminalSessionLaunchBackend,
        persistentHosting: PersistentLocalSessions?
    ) -> TerminalSession {
        TerminalSession(
            id: id,
            title: command.name.isEmpty ? "Command \(index)" : command.name,
            subtitle: command.commandLine,
            tint: palette[(index - 1) % palette.count],
            workingDirectory: Self.startingDirectory(workingDirectory, hosting: persistentHosting),
            projectRoot: projectRoot,
            kind: .command,
            commandName: command.name,
            launchCommand: command.commandLine,
            launchEnvironment: command.environment,
            restartOnExit: command.autoRestart,
            launchBackend: launchBackend,
            persistentHosting: persistentHosting
        )
    }

    private static func makePreviewAgentSession(
        index: Int,
        title: String,
        subtitle: String,
        agentName: String,
        workingDirectory: String,
        projectRoot: String?,
        parentAgentID: UUID? = nil,
        launchBackend: TerminalSessionLaunchBackend
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
            parentAgentID: parentAgentID,
            launchBackend: launchBackend
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

/// Production sessions use Ghostty's EXEC backend. The host-managed case is an
/// explicit dependency for deterministic shell/renderer tests; it is not exposed
/// as an app preference or environment switch.
enum TerminalSessionLaunchBackend {
    case nativePTY
    case hostManaged
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
        /// The launch failed. For a hosted tab, the attach client could not
        /// attach; the message says why and reconnecting retries.
        case failed(String)
        /// A hosted tab whose attach client stopped. The program may still be
        /// running on its host, so this is never an exit and has no exit code.
        case disconnected

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
            case .disconnected:
                "disconnected"
            }
        }

        var failureMessage: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    /// The tab's identity: `CHERRY_PROCESS_ID`/`CHERRY_AGENT_ID` in its
    /// processes, the MCP process id, deep links, notifications, split panes
    /// and agent parents. Saved with the workspace, so a restored tab keeps it.
    let id: UUID
    @Published private(set) var title: String
    @Published private(set) var titleSource: TitleSource
    @Published private(set) var subtitle: String
    @Published private(set) var resolvedCommandLine: String?
    @Published private(set) var workingDirectory: String
    @Published private(set) var state: SessionState = .launching
    @Published private(set) var hasUnreadNotification = false
    @Published private(set) var lastNotification: TerminalNotificationRequest?
    @Published private(set) var agentActivityState: AgentActivityState = .unknown
    @Published private(set) var attentionClassifierPrediction: TerminalAttentionPrediction?
    @Published private(set) var attentionAlertGeneration = 0
    @Published private(set) var hasUnacknowledgedAttention = false
    @Published private(set) var currentAttentionScreenTag: TerminalAttentionCorrection?
    @Published private(set) var startedAt: Date?
    /// When the program the tab runs now started: at its launch
    /// (`startedAt`), or later, once its persistent session's Create
    /// answered or the tab ran natively because the session could not
    /// start. A restored or adopted session keeps the launch's time. What
    /// `cleanExitMinimumRunTime` is measured from.
    private(set) var programStartedAt: Date?
    @Published private(set) var exitedAt: Date?
    @Published private(set) var lastOutputAt: Date?
    @Published private(set) var outputVersion = 0
    @Published private(set) var lastInputOutputVersion: Int?
    @Published private(set) var lastContentChangeAt: Date?
    @Published private(set) var contentVersion = 0
    @Published private(set) var childProcessID: Int32?
    @Published private(set) var exitCode: Int32?
    @Published private(set) var nixShellEnvironment: NixShellEnvironment?
    let hostedAttachment: HostedSessionAttachment?
    @Published private(set) var hostedAttachmentStatus: HostedAttachmentStatus?
    /// The ended hosted session was deleted on its host; the tab only shows its output.
    @Published private(set) var hostedSessionRemovedFromHost = false
    /// `--status-file` of the latest adapter launch. It stays in the exec
    /// command after the outcome is read: a changed surface configuration
    /// rebuilds the surface, which would start another adapter.
    private var hostedLaunchStatusFile: URL?
    /// That launch's private directory while its outcome is still unread.
    private var hostedPendingStatusDirectory: URL?
    /// The running adapter's live state, as its status file reports it
    /// (`HostedAdapterStatusWatcher`): nil until this launch attached (and
    /// once it ended). A persistent tab takes the adapter to show its
    /// program, and to pass the program's bells, notifications, title and
    /// directory through, only while this says so; while it reconnects or
    /// shows a viewport, the tab reads the program's screen from the host.
    @Published private(set) var adapterLiveStatus: HostedAdapterLiveStatus?
    private var adapterStatusWatcher: HostedAdapterStatusWatcher?
    /// The adapter has reported itself reconnecting (its host restarted)
    /// for longer than the notice delay: an attached tab's connection bar
    /// says so, and a persistent tab shows its reconnect bar
    /// (`.disconnected`). The adapter keeps its surface meanwhile.
    @Published private(set) var isAdapterReconnecting = false
    private var adapterReconnectingNotice: DispatchWorkItem?
    /// For a tab without persistent hosting (attached tabs).
    private static let adapterReconnectingNoticeDelay: TimeInterval = 2
    private var hostedTakeoverForNextLaunch = false
    private var hostedLaunchTakesOver = false
    /// The SSH master the latest adapter launch of an SSH-hosted tab shares,
    /// registered once for that launch in `startShell`; nil for its own ssh.
    private var hostedLaunchSSHControlPath: String?
    /// `--size-file` of the latest adapter launch, in its private directory:
    /// where the tab tells the adapter which grid its window settled at
    /// (`HostedAttachmentSizeFile`, `announceAdapterWindowSize`), and what
    /// it said last.
    private var hostedLaunchSizeFile: URL?
    private var announcedAdapterWindowSize: HostedAttachmentSizeFile.Content?
    /// The latest adapter's outcome may be resumed by launching it again
    /// (`HostedAttachmentStatusFile.isRetryable`).
    private var hostedLaunchRetryable = false
    /// Brings this tab back when its adapter gave up while attached to an
    /// SSH host's session (`HostedReconnects`): the workspace's
    /// `SessionBackendPolicy.hostReconnects`. Nil: a disconnected tab waits
    /// for Reconnect.
    var hostReconnects: HostedReconnects?
    /// Waiting for its host to answer (`HostedReconnects`), after its adapter
    /// lost the connection or could not attach.
    @Published private(set) var isWaitingForHost = false

    // MARK: Persistent local session (docs/specs/multiplexer-default.md)

    /// Runs this local tab's program as a persistent session in the local
    /// cherry-host; the tab's surface runs the session's attach adapter.
    /// Nil for a native tab and for one attached to a session from
    /// Persistent Sessions without adopting it (`hostedAttachment`). Cleared
    /// when the host could not start the program: the tab then runs it
    /// natively, and `persistentFallbackHosting` keeps it for the next
    /// launch.
    private(set) var persistentHosting: PersistentLocalSessions?
    /// The host of a tab that was to run as a persistent session and runs
    /// natively because the host could not start it (`persistentLaunchFailed`).
    /// Its next launch (Restart, a command's restart, the fallback bar's
    /// Retry) tries the host again: always for Retry, otherwise while the
    /// host takes new tabs (`canHostNewTabs`).
    private var persistentFallbackHosting: PersistentLocalSessions?
    /// Why this tab's program could not start on another Mac's host, which
    /// never falls back to a native shell (`failPersistentLaunchWithoutFallback`):
    /// "Couldn't start on <Mac>: <reason>". Nil once it starts again.
    @Published private(set) var persistentLaunchFailureReason: String?
    /// The launch that failed that way, whose Create may still answer with
    /// the host's own reason.
    private var persistentFailedLaunchID: UUID?
    /// Why this tab runs natively instead of as a persistent session (the
    /// host's rejection, or no answer in time), for the tab's fallback bar;
    /// nil once it runs in the host again.
    @Published private(set) var persistentFallbackReason: String?
    /// The next launch tries the host even while it takes no new tabs.
    private var persistentRetryRequested = false
    /// The host session the tab's program runs in. Set once Create answers
    /// (or a restore adopts a session), replaced by a restart, and kept after
    /// the program exits: the host keeps its final screen until the tab
    /// closes or restarts. Saved with the workspace.
    @Published private(set) var persistentSession: HostedSessionAttachment?
    /// How many clients its host reports attached to the tab's session (its
    /// own adapter included) and the size of the session's shared screen;
    /// nil when the tab shows no hosted session or the host did not say.
    @Published private(set) var hostSessionSharing: HostSessionSharing?
    /// Its session's holder died (`HostSessionEnd.holderLost`): the tab says
    /// "The session host crashed" (with the log) instead of its exit status,
    /// and a command that restarts on exit is not restarted by it. Cleared
    /// by the next launch.
    @Published private(set) var hostSessionEnd: HostSessionEnd?
    /// The name the tab's session has on its host, as far as the tab knows
    /// (`syncHostSessionName`).
    private var hostSessionName: String?
    /// An agent's task title waiting to reach its host.
    private var hostSessionNameSync: DispatchWorkItem?
    private var persistentPhase: PersistentPhase = .idle
    /// A running or exited session the next launch attaches to instead of
    /// creating one (a restored or adopted tab).
    private var persistentSessionToAdopt: PersistentSessionLaunch?
    /// Input sent while the session was being created, delivered once it is.
    /// MCP's input carries a delivery its caller waits on
    /// (`sendControlInput`); the keyboard's none.
    private var pendingPersistentInput: [(data: Data, delivery: PersistentInputDelivery?)] = []
    /// The `request_id` (lowercased) of the Create that started the tab's
    /// session, or is starting it: chosen before the Create is sent and
    /// saved with the tab (`WorkspaceSessionRecord.launchRequestID`), so a
    /// relaunch finds the session even when the answer was never saved.
    private(set) var persistentLaunchRequestID: String?
    /// The latest launch's work (ending the previous session, Create): the
    /// next launch waits for it (`startPersistentLaunch`).
    private var persistentLaunchTask: Task<Void, Never>?
    /// What the latest launch does with the session its Create makes when
    /// the tab no longer follows it by the time Create answers.
    private var persistentLaunchClaim: PersistentLaunchClaim?
    private var persistentReconnectFailures = 0
    private var persistentReconnectMisses = 0
    private var persistentReconnect: DispatchWorkItem?
    /// A device's tab waits for its host's control connection before its
    /// adapter is launched again (`schedulePersistentReconnect`).
    private var remoteHostWait: AnyCancellable?
    /// When keys typed into a device's tab were last not sent because its
    /// Mac could not be reached (`noteInputNotSentWhileOffline`): the
    /// offline bar says so for a moment.
    @Published private(set) var offlineInputRejectedAt: Date?
    /// Checks whether a session missing from the host's list is really gone.
    private var persistentDisappearanceCheck: Task<Void, Never>?
    /// Where this tab was registered as an open persistent tab (it stays
    /// registered after a fallback to native, until it closes).
    private var persistentTabRegistry: PersistentLocalSessions?
    /// The program's process id as the local host reports it
    /// (`SessionInfo.pid`: the login shell, or the program it became),
    /// while a persistent tab's program runs. It routes MCP callers to
    /// their tab, is the pid MCP reports and roots port detection. Nothing
    /// signals it: the program is the host's child, and `stop()` only hangs
    /// up on the tab's own attach adapter. A tab attached to a session of
    /// This Mac (`hostedAttachment`, host `.local`) has it too, from the
    /// session as listed, while its adapter runs
    /// (`noteAttachedLocalSession`); one attached to another machine's
    /// session never does, so no other machine's pid is used.
    @Published private(set) var hostedProgramProcessID: Int32?
    /// The program pid of the session of This Mac this tab is attached to
    /// (`SessionInfo.pid`, fixed for the session's life), as last listed.
    private var attachedLocalProgramProcessID: Int32?
    /// The latest progress the program reported (OSC 9;4) through its host;
    /// nil when none or removed.
    @Published private(set) var progressReport: TerminalProgressReport?
    /// The title and directory the host last reported for the program (raw),
    /// so a report is applied once, when it changes.
    private var lastHostReportedTitle: String?
    private var lastHostReportedDirectory: String?
    /// Bells and notifications shown lately, and whether they came from the
    /// surface or the host: the adapter passes to the surface what the host
    /// also reports, and each is shown once.
    private var recentSignalDeliveries: [(key: String, fromHost: Bool, at: Date)] = []
    /// When the attach adapter last started passing the program's signals
    /// through, and the local host's control connection that was up then
    /// (`PersistentLocalSessions.connectionGeneration`; nil when none was):
    /// bells and notifications the host kept while no app was subscribed
    /// (its daemon restarted) and hands to a later connection may predate
    /// that adapter, which then never showed them.
    private var adapterFollowingSince: Date?
    private var adapterFollowingControlGeneration: Int?
    /// Bells and notifications the surface showed since then that no host
    /// report matched yet (its copy of one the host may still hand over).
    private var surfaceSignalsWhileFollowing: [(key: String, at: Date)] = []
    private static let notificationDeduplicationWindow: TimeInterval = 3
    private static let bellDeduplicationWindow: TimeInterval = 1
    /// Plays the terminal bell (Ghostty's, or one the host reported).
    /// Tests replace it.
    var bellHandler: @MainActor (TerminalSession) -> Void = { _ in NSSound.beep() }
    /// The screen read from the host is in `nativeContentLines`, read at
    /// this time; nil when it came from the surface.
    private var hostContentReadAt: Date?
    private var hostContentUsesAlternateScreen = false
    private var hostContentRead: Task<Void, Never>?
    /// Whether the read under way asks for the whole history.
    private var hostContentReadIsWhole = false
    private var hostContentReadGeneration = 0
    /// The lines read from the host hold its whole history (the last read
    /// did, or a later recent one showed nothing new); otherwise only its
    /// last `hostScreenRecentLines`.
    private var hostContentHasHistory = false
    /// Identifies the last lines read from the host (see
    /// `hostContentChangeKey`): a new read that has the same ones shows
    /// nothing new, whether it read the whole history or only recent lines.
    private var hostContentTailKey: Int?

    // MARK: Restored tabs (deferred attach)
    //
    // A restore builds every saved tab at once but launches their attach
    // adapters a few at a time (`RestoredTabLaunchQueue`), the shown tabs
    // first; showing a tab launches its adapter at once. Until then a
    // persistent tab follows its program through the host (title, pwd,
    // bells, exit, input and screen, as while its adapter reconnects), and
    // an attached tab follows its session's events through its host's
    // control connection.

    /// A restored persistent tab whose program runs but whose attach adapter
    /// was not launched yet.
    private var persistentAdapterDeferred = false
    /// A tab a launch's restore showed for its saved session before the
    /// host answered (`OptimisticRestore`): until the restore confirms it
    /// (`confirmProvisionalRestore`) or withdraws it, what its adapter and
    /// the host say of its program's end is held, not acted on, since the
    /// restore decides what a session gone or ended while Cherry was closed
    /// becomes (`SystemEndedSessions`, *close on exit*).
    private(set) var isProvisionalRestore = false
    private var provisionalExit: (status: Int32, end: HostSessionEnd?)?
    private var provisionalAdapterEnded = false
    /// The tab started the program it runs now (a native launch, or a new
    /// session it created), rather than following one that was already
    /// running: a restored or adopted session, or one attached from its
    /// host. Only a program the tab just started can be at its startup
    /// prompt; one it follows may be anywhere, a permission prompt
    /// included, so MCP input never answers a prompt for it.
    private(set) var startedCurrentProgram = false
    /// A restored attached tab whose attach adapter was not launched yet.
    private var hostedLaunchDeferred = false
    /// An attached tab's host events while its launch is deferred.
    private var deferredHostEvents: AnyCancellable?
    private var deferredHostLease: HostControlLease?
    /// The control connection an attached tab follows while its launch is
    /// deferred; MCP input goes through it (`SendInput`) meanwhile.
    private weak var deferredHostControl: HostControl?
    /// Where this tab was registered as an open tab attached to a session.
    private var isRegisteredAsAttachedTab = false
    /// The ended program's final screen was read from its host (no adapter
    /// showed it); the read under way, if any.
    private var finalScreenRead: Task<Void, Never>?

    private enum PersistentPhase: Equatable {
        case idle
        /// The session is being created (or adopted); input is queued.
        case creating
        /// The attach adapter runs in the surface; its status file says
        /// whether it attached (`adapterLiveStatus`).
        case attached
        /// The adapter ended while the program runs: it is launched again
        /// with backoff, and input goes through the host's control connection.
        case reconnecting
    }

    /// Signals a native-PTY session's processes when the tab stops. Tests
    /// wrap it to answer the hangup the way a hosted attach adapter does.
    var terminateNativeSession: (pid_t) -> Void = { ShellProcessController.terminateNativeShellSession(anchorPID: $0) }
    /// The kitty keyboard flags the program set, parsed from its output
    /// (the host-managed path); see `keyboardProtocolFlags`.
    private var streamKeyboardProtocolFlags = 0
    /// The session a tab attached to a hosted session (`hostedAttachment`)
    /// was last reported as (its host's list, or its events while its
    /// launch is deferred): its alternate screen and keyboard flags until
    /// its adapter launches.
    private var attachedSessionInfo: HostedSessionInfo?
    /// The control connection of the host a tab attached to a hosted
    /// session (`hostedAttachment`) runs it on: while it is connected, it
    /// reports the program's modes, and it takes MCP input while the
    /// adapter reconnects. The workspace sets it for the tabs it builds;
    /// otherwise the app's registry's control for that host.
    var attachedHostControlProvider: (@MainActor (HostedSessionHost) -> HostControl)?

    private var attachedHostControl: HostControl? {
        guard let hostedAttachment else { return nil }
        if let attachedHostControlProvider { return attachedHostControlProvider(hostedAttachment.host) }
        return HostControlRegistry.shared.control(for: hostedAttachment.host)
    }

    /// The kitty keyboard protocol flags the program enabled: as its host
    /// reports them for a hosted tab (Ghostty's surface parses them for the
    /// adapter, not for Cherry), else as parsed from its output.
    var keyboardProtocolFlags: Int {
        if let flags = hostReportedSessionInfo?.kittyKeyboardFlags { return Int(flags) }
        return streamKeyboardProtocolFlags
    }

    var isEnhancedKeyboardProtocolActive: Bool {
        keyboardProtocolFlags > 0
    }

    /// The running program's session as its host last reported it, for a
    /// persistent tab or one attached to a hosted session; nil for a native
    /// tab, or when not known.
    ///
    /// An attached tab follows its session's events only until its adapter
    /// launches (`followDeferredHostEvents`). From then on the session is
    /// known only while its host's control connection is up and follows
    /// the host's events (`HostControl.currentSession`), which keep it
    /// current; a report from before (its modes may have changed since)
    /// never applies.
    /// The program's pid on the other Mac a device tab runs on
    /// (`SessionInfo.pid`), only to ask that Mac which ports it listens on
    /// (`RemotePortScanner`): never a pid of This Mac (rule 4 of
    /// docs/specs/remote-devices.md). Nil for This Mac's tabs.
    var remoteProgramProcessID: Int32? {
        guard let persistentHosting, !persistentHosting.profile.isThisMac,
              let pid = hostReportedSessionInfo?.pid
        else { return nil }
        return Int32(bitPattern: pid)
    }

    /// What the tab's host last reported of its running session (its
    /// foreground program, modes); nil while it does not run there.
    var hostReportedSession: HostedSessionInfo? { hostReportedSessionInfo }

    private var hostReportedSessionInfo: HostedSessionInfo? {
        if let persistentHosting {
            guard isRunning, persistentPhase != .creating,
                  let sessionID = persistentSession?.sessionID,
                  let info = persistentHosting.sessionInfo(sessionID), info.isRunning
            else { return nil }
            return info
        }
        guard let hostedAttachment else { return nil }
        if hostedLaunchDeferred {
            guard let info = attachedSessionInfo, info.isRunning else { return nil }
            return info
        }
        guard isRunning,
              let info = attachedHostControl?.currentSession(hostedAttachment.sessionID, hostID: hostedAttachment.hostID),
              info.isRunning
        else { return nil }
        return info
    }

    let projectRoot: String?
    let tint: NSColor
    let maxScrollback: Int?
    private(set) var launchWorkingDirectory: String
    let kind: SessionKind
    private let launchBackend: TerminalSessionLaunchBackend
    let agentName: String?
    @Published private(set) var parentAgentID: UUID?
    private(set) var commandName: String?
    private(set) var launchCommand: String?
    private(set) var launchEnvironment: [String: String]
    private(set) var restartOnExit: Bool
    /// Set by the owning workspace: called after a rename, a managed command
    /// edit or a new agent parent, which workspace persistence saves.
    var persistentStateDidChange: (@MainActor () -> Void)?
    /// Set by the workspace showing the tab: its own program ended by
    /// itself while the tab followed it (`finishProcessExit`). Never for a
    /// stop, restart or close (they stop following it first), a program
    /// that had ended before the tab followed it, or an attached tab's.
    var programDidExit: (@MainActor (TerminalSession) -> Void)?
    /// Set by the workspace showing the tab: the size, in points, of a
    /// terminal its window shows now (`TerminalWorkspace.mountedTerminalSize`),
    /// for a surface built while no view shows it (a restored tab's attach
    /// adapter launching in the background): its program, or the persistent
    /// session it attaches to, gets the size the tab will have when shown,
    /// instead of Ghostty's default for a detached surface and then the
    /// window's when shown (two resizes, each redrawn by the program).
    var detachedSurfaceSize: (@MainActor () -> CGSize?)?
    /// Set by the workspace showing the tab, as `detachedSurfaceSize`: the
    /// cell size, in pixels, a terminal of the given grid its window shows
    /// reports to its program (`TerminalWorkspace.terminalCell(forGrid:)`).
    /// A persistent tab's Create passes it on (`PersistentSessionRequest.cell`),
    /// so the program's PTY has the pixels its adapter will report, and the
    /// adapter attaching changes nothing (new pixels alone signal the
    /// program, which may redraw).
    var windowTerminalCell: (@MainActor (TerminalViewportSize) -> TerminalCellSize?)?
    /// Set by the workspace showing the tab, as `detachedSurfaceSize`: this
    /// tab's surface, laid out in a window, has a grid
    /// (`TerminalWindowGrid.note`).
    var surfaceShowedWindowGrid: (@MainActor (TerminalViewportSize, NSWindow) -> Void)?
    /// Set by the workspace showing the tab, as `detachedSurfaceSize`: how
    /// long a persistent tab's Create waits for the terminal grid of the
    /// window that shows it to settle (`SessionBackendPolicy.windowGridWait`),
    /// and that grid now (`TerminalWindowGrid.observation`). Nil: the Create
    /// takes the grid the tab has.
    var windowGridForCreate: (
        wait: TerminalWindowGridWait,
        observe: @MainActor () -> TerminalWindowGridWait.Observation?
    )?

    /// This tab's surface, laid out in `window`, has `grid`
    /// (`GhosttySessionBridge.reportWindowGrid`).
    func surfaceDidShowWindowGrid(_ grid: TerminalViewportSize, in window: NSWindow) {
        surfaceShowedWindowGrid?(grid, window)
    }

    /// The cell size this tab's terminal reports to a program at `grid`
    /// (`GhosttySessionBridge.terminalWindowSize`), while its surface has
    /// that grid.
    func terminalCell(forGrid grid: TerminalViewportSize) -> TerminalCellSize? {
        guard let size = ghosttyBridgeStorage?.terminalWindowSize,
              size.columns == grid.columns, size.rows == grid.rows
        else { return nil }
        return size.cell
    }

    /// Tells the running attach adapter which size its window settled at,
    /// or that it is changing (`HostedAttachmentSizeFile`); its surface's
    /// bridge calls this as the surface's grid or its window changes. A tab
    /// without an adapter launch says nothing.
    func announceAdapterWindowSize(_ content: HostedAttachmentSizeFile.Content) {
        guard let file = hostedLaunchSizeFile, content != announcedAdapterWindowSize else { return }
        if HostedAttachmentSizeFile.write(content, to: file) {
            announcedAdapterWindowSize = content
        }
    }

    /// The grid of this tab's terminal while a window shows it.
    var mountedTerminalGrid: TerminalViewportSize? {
        guard mountedTerminalSize != nil, let metrics = ghosttyBridgeStorage?.gridMetrics,
              metrics.columns > 0, metrics.rows > 0
        else { return nil }
        return TerminalViewportSize(columns: Int(metrics.columns), rows: Int(metrics.rows))
    }

    /// The size, in points, of this tab's terminal while a window shows it.
    var mountedTerminalSize: CGSize? {
        guard let bridge = ghosttyBridgeStorage, bridge.terminalView.window != nil else { return nil }
        let size = bridge.terminalView.bounds.size
        return size.width > 0 && size.height > 0 ? size : nil
    }
    /// The system ended this tab's session while Cherry was closed (a
    /// restart or log out): the tab came back ended, with no session, and
    /// says so (`PersistentSessionEndedBar`). Any launch (Restart,
    /// auto-start, auto-restart, MCP) clears it. Saved with the tab
    /// (`WorkspaceSessionRecord.systemEnd`).
    @Published private(set) var systemSessionEnd: SystemSessionEnd?
    /// How the program of a tab the system ended had exited before that
    /// (`WorkspaceSessionRecord.exitStatus`): the tab shows "Session ended
    /// (exit N)", and nothing restarts it by itself.
    private(set) var systemEndExitStatus: Int32?
    /// True when auto-restart gave up on a crash-looping command (see
    /// `CommandAutoRestartPolicy`); cleared by a manual restart.
    @Published private(set) var isAutoRestartPaused = false
    private var pendingAutoRestart: DispatchWorkItem?
    private var consecutiveRapidExitCount = 0
    private var systemTitle: String
    private var automaticTitle: String?
    private var pendingResolvedCommandLine: String?

    @Published private(set) var revision = 0
    /// `ghosttyBridge` is launching a restored tab's adapter for a view
    /// being built: `bumpRevision` publishes on the next turn instead.
    private var isBuildingBridgeForView = false
    private var isRevisionBumpScheduled = false

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
    /// The lines a tab closed because its shell exited showed last
    /// (`keepContentAfterClosing`): what a caller still holding it (MCP
    /// `wait_for_process_idle`) reads once its surface and session are gone.
    private var closedTabContentLines: [String]?
    private var isRefreshingNativeContent = false
    private var nativeContentHash = 0
    private var nativeContentRefreshScheduled = false
    private var lastNativeContentReadAt: Date?
    /// Unit/integration fixtures can inject a deterministic VT stream even when
    /// the session owns a live native surface. Once injected, data-layer reads use
    /// the processor snapshot and ignore unrelated shell redraws for that fixture.
    private var usesInjectedTestingContent = false
    /// OSC 133 command-end signal (native). A precise "back at prompt / command
    /// done" marker for non-TUI commands; published so idle detection can use it.
    @Published private(set) var lastNativeCommandFinishedAt: Date?
    private(set) var lastNativeCommandExitCode: Int32?
    let hostInputWriter = TerminalInputWriter()
    private var shellProcess: ShellProcessController?
    private var activeLaunchID: UUID?
    private var viewportSize = TerminalViewportSize(columns: 120, rows: 32)
    /// The surface reported its grid (`resize`): a seed no longer applies.
    private var viewportWasReported = false
    private var traceRecorder: TerminalTraceRecorder?
    private let attentionObservationDirectoryProvider: @MainActor () -> URL?
    private let attentionCorrectionDirectoryProvider: @MainActor () -> URL
    private let attentionNotificationHandler: @MainActor (TerminalAttentionPrediction, TerminalSession) -> Void
    private var attentionObservationRecorder: TerminalAttentionObservationRecorder?
    private var attentionCorrectionRecorder: TerminalAttentionObservationRecorder?
    private var attentionObservationTask: Task<Void, Never>?
    private var acknowledgedAttentionAlertGeneration = 0
    private var isAttentionEpisodeActive = false
    private var hasHarnessNotificationForAttentionEpisode = false
    private var attentionNotificationGate = TerminalAttentionNotificationGate()
    private var currentAttentionScreenTagObservationID: UUID?
    private var latestAttentionObservationEvent: TerminalAttentionObservationEvent = .contentChanged
    /// Where the agent's current turn stands (read by tests).
    private(set) var agentTurnState: TerminalAttentionTurnState = .notStarted
    private var outputHoldUntil: Date?
    private var isOutputPausedForInteraction = false
    private var isOutputPausedForBackgroundThrottle = false
    private var backgroundOutputThrottleTask: Task<Void, Never>?
    private var backgroundOutputBytesSinceThrottle = 0
    private var keyboardProtocolFlagStack: [Int] = []
    private var ghosttyBridgeStorage: GhosttySessionBridge?
    private var renderedReplayCache: RenderedReplayCache?
    private var lastHumanInputLine: Int?
    private var lastHumanInputAt: Date?
    private var lastHumanKeystrokeAt: Date?
    private var hasUnsubmittedHumanInput = false
    /// Someone is typing into the agent's composer (keys not submitted
    /// yet), or typed into it within `interval`: nothing else may type
    /// into it then (MCP monitor wake lines).
    func humanIsComposing(within interval: TimeInterval) -> Bool {
        if hasUnsubmittedHumanInput { return true }
        guard let lastHumanKeystrokeAt else { return false }
        return Date().timeIntervalSince(lastHumanKeystrokeAt) < interval
    }
    private var humanInputGeneration = 0
    private var agentActivitySource: AgentActivitySource = .none
    private var titleIndicatesAgentWorking = false
    private var lastTitleSpinnerAt: Date?
    /// The last working marker or title spinner pulse seen (read by MCP
    /// waits and monitors: did a turn start after its submit?).
    private(set) var lastStrongWorkingEvidenceAt: Date?
    /// Turns Cherry saw submitted to this agent (an Enter typed or sent by
    /// MCP), over the tab's life in this run of Cherry.
    private(set) var agentSubmittedTurnCount = 0
    /// Turns the agent began by itself after one ended (it answered a
    /// background agent's or task's result, woke up on a schedule, a hook
    /// continued it): `AgentResumedWorkDetector`, over the tab's life in
    /// this run of Cherry.
    private(set) var agentSelfResumedTurnCount = 0
    /// MCP's `agent_turn`: every turn Cherry saw start, submitted or begun
    /// by the agent itself. It only grows.
    var agentTurnCount: Int { agentSubmittedTurnCount &+ agentSelfResumedTurnCount }
    /// Watches a finished turn's agent for work it resumes by itself.
    private var resumedWorkDetector = AgentResumedWorkDetector()
    /// The last key or input sent to the agent (any key, a paste, MCP
    /// input): a screen change right after one may be its own effect.
    private var lastAgentInputAt: Date?
    /// When the latest of those turns was submitted.
    private(set) var lastAgentSubmitAt: Date?
    /// The agent showed it was at work (strong evidence) when that turn was
    /// submitted: a message the CLI queues behind the running turn.
    private(set) var agentWasWorkingAtLastSubmit = false
    /// The agent's screen showed recognizable activity (its composer, a
    /// working marker, a title spinner or a notification) when that turn
    /// was submitted: Cherry can read this CLI, so it can tell when the
    /// turn starts.
    private(set) var agentWasReadableAtLastSubmit = false
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
        // A permission or question menu on screen
        // (`AgentScreenActivity.answerMenu`): the state follows the menu
        // and ends when it goes.
        case answerMenu
    }

    private enum AgentDraftInputEffect: Equatable {
        case none
        case inserted
        case edited
        case cleared
        case submitted
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

    init(
        id: UUID = UUID(),
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
        launchBackend: TerminalSessionLaunchBackend = .nativePTY,
        hostedAttachment: HostedSessionAttachment? = nil,
        hostedTakeover: Bool = false,
        persistentHosting: PersistentLocalSessions? = nil,
        adoptingPersistentSession: PersistentSessionLaunch? = nil,
        deferredLaunch: Bool = false,
        provisionalRestore: Bool = false,
        attentionObservationDirectoryProvider: @escaping @MainActor () -> URL? = {
            TerminalAttentionObservationRecorder.configuredDirectoryURL
        },
        attentionCorrectionDirectoryProvider: @escaping @MainActor () -> URL = {
            TerminalAttentionStudy.correctionsDirectoryURL()
        },
        attentionNotificationHandler: @escaping @MainActor (
            TerminalAttentionPrediction,
            TerminalSession
        ) -> Void = { _, session in
            TerminalNotificationCenter.shared.postAttention(for: session)
        }
    ) {
        self.id = id
        self.title = title
        self.titleSource = titleSource
        self.subtitle = subtitle
        self.tint = tint
        self.workingDirectory = workingDirectory
        self.launchWorkingDirectory = workingDirectory
        self.projectRoot = projectRoot
        self.maxScrollback = maxScrollback
        self.kind = kind
        self.launchBackend = launchBackend
        self.hostedAttachment = hostedAttachment
        self.hostedAttachmentStatus = hostedAttachment.map { _ in .disconnected(nil) }
        // Only a local Ghostty EXEC tab runs its program in the local host.
        let persistentHosting = launchBackend == .nativePTY && hostedAttachment == nil ? persistentHosting : nil
        self.persistentHosting = persistentHosting
        self.persistentSessionToAdopt = persistentHosting == nil ? nil : adoptingPersistentSession
        self.hostedTakeoverForNextLaunch = (hostedAttachment != nil || adoptingPersistentSession != nil) && hostedTakeover
        self.agentName = agentName
        self.parentAgentID = kind == .agent ? parentAgentID : nil
        self.commandName = commandName
        self.launchCommand = launchCommand?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.launchEnvironment = launchEnvironment
        self.restartOnExit = restartOnExit
        self.attentionObservationDirectoryProvider = attentionObservationDirectoryProvider
        self.attentionCorrectionDirectoryProvider = attentionCorrectionDirectoryProvider
        self.attentionNotificationHandler = attentionNotificationHandler
        self.systemTitle = title
        let processorMaxScrollback = Self.processorMaxScrollback(for: kind, configuredMaxScrollback: maxScrollback)
        let processorBuffer = buffer ?? LiveTerminalOutputBuffer(maxScrollback: processorMaxScrollback)
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
        // What the in-memory surface encodes while no process takes it: a
        // persistent tab's keys while its session is created or restarted.
        // Ghostty writes it from the key event on the main thread, where it
        // is queued at once, in order with the keys the tab's key monitor
        // sends (`send(data:)`).
        self.hostInputWriter.setFallbackWriteHandler { [weak self] data in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.surfaceInputWithoutProcess(data) }
            } else {
                DispatchQueue.main.async { self?.surfaceInputWithoutProcess(data) }
            }
        }

        if let persistentHosting {
            // A tab adopting a session owns it from now on (the workspace
            // checked no open tab does): another tab or restore sees that
            // at once, before the adapter attaches.
            if let adoptingPersistentSession {
                persistentSession = adoptingPersistentSession.attachment
                persistentLaunchRequestID = PersistentLocalSessions.launchRequestID(of: adoptingPersistentSession.info)
                // Before it follows the session (`startShell` binds it).
                isProvisionalRestore = provisionalRestore
            }
            persistentHosting.register(self)
            persistentTabRegistry = persistentHosting
        }
        if hostedAttachment != nil {
            OpenHostedTabs.shared.register(self)
            isRegisteredAsAttachedTab = true
        }
        if launchShell, deferredLaunch, hostedAttachment != nil {
            // `launchDeferredAdapterIfNeeded` (the restore's queue, or
            // showing the tab) starts it.
            hostedLaunchDeferred = true
            hostedAttachmentStatus = nil
        } else if launchShell {
            // A restored persistent tab follows its session at once; only its
            // adapter waits.
            persistentAdapterDeferred = deferredLaunch && persistentSessionToAdopt != nil
            startShell()
        } else {
            // A tab that is not launched only names its session.
            persistentSessionToAdopt = nil
            state = hostedAttachment == nil ? .exited(0) : .disconnected
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
        if let closedTabContentLines { return closedTabContentLines.count }
        // Lines read from the host (a persistent tab no surface shows, such
        // as a restored one whose adapter waits) are the ones MCP output
        // numbers, as `lineCount` counts them.
        return readsContentFromHost || (ghosttyBridgeStorage?.isNativePTYBacked == true && !usesInjectedTestingContent)
            ? nativeContentLines.count
            : processor.lineCount
    }

    var cursorState: TerminalCursorState {
        processor.cursorState
    }

    /// Whether the program shows its alternate screen: as its host reports
    /// it for a hosted tab, else as the screen read from the host or the
    /// parsed output shows.
    var usesAlternateScreen: Bool {
        if let alternate = hostReportedSessionInfo?.alternateScreen { return alternate }
        return readsContentFromHost ? hostContentUsesAlternateScreen : processor.usesAlternateScreen
    }

    /// Whether the program gets application cursor keys (`ESC O x` for
    /// unmodified arrows, Home and End): as its host reports it for a
    /// hosted tab (`hostReportedApplicationCursorKeys`; Ghostty's surface
    /// parses the mode for the adapter, not for Cherry), else as parsed
    /// from its output. Keys typed while an adapter is away
    /// (`HostRoutedKeyEncoder`) and MCP input the host types
    /// (`hostTypedInputData`) are encoded for it.
    var usesApplicationCursorKeys: Bool {
        hostReportedApplicationCursorKeys ?? processor.usesApplicationCursorKeys
    }

    /// Whether a terminal types the program's cursor keys in application
    /// form, as its host reports its modes: DECCKM is on
    /// (`HostedSessionInfo.applicationCursorKeys`) and the program uses
    /// legacy key encoding. Under the kitty keyboard protocol (flags not
    /// 0) they are always CSI (`ESC [ x`). Nil when the host does not
    /// report DECCKM (an older host) or reports nothing now.
    private var hostReportedApplicationCursorKeys: Bool? {
        guard let info = hostReportedSessionInfo, let application = info.applicationCursorKeys else { return nil }
        return application && (info.kittyKeyboardFlags ?? 0) == 0
    }

    /// Whether the program turned on bracketed paste: as its host reports
    /// it for a hosted tab (`HostedSessionInfo.bracketedPaste`; the surface
    /// parses the mode for the adapter, not for Cherry), else as parsed from
    /// its output. False while a hosted tab's host does not report it.
    var usesBracketedPasteMode: Bool {
        hostReportedSessionInfo?.bracketedPaste ?? processor.usesBracketedPasteMode
    }

    /// Whether a paste of `text` that Cherry types for the program (a
    /// persistent tab's ⌘V while its attach adapter is away, or the
    /// host-managed surface's) is wrapped in `ESC [ 200 ~` … `ESC [ 201 ~`.
    /// A tab whose program runs in a host (persistent or attached) follows
    /// its host's report (`usesBracketedPasteMode`). When the host cannot
    /// tell (a session whose holder predates holder link 7), a paste that
    /// holds a line break is bracketed anyway, a trade-off: shells, editors
    /// and agents at their prompts turn the mode on, and to one that did,
    /// an unbracketed paste is typed lines, each run as it arrives. To a
    /// program that did not, the markers arrive as input: `cat > file`
    /// writes them into the file, and a vi-mode line editor takes the ESC
    /// as a key. A single line is left as it is.
    func bracketsPaste(_ text: String) -> Bool {
        guard persistentHosting != nil || hostedAttachment != nil else {
            return processor.usesBracketedPasteMode
        }
        if let reported = hostReportedSessionInfo?.bracketedPaste { return reported }
        return text.contains { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
    }

    var mouseState: TerminalMouseState {
        processor.mouseState
    }

    var statusLine: String {
        "\(state.label) · \(lineSummary)"
    }

    /// Whether MCP input (`sendControlInput`) can reach the program: when
    /// the tab takes input, and also for a restored attached tab whose
    /// adapter is not launched yet (its host's control connection takes the
    /// input then).
    var acceptsControlInput: Bool {
        acceptsInput || (hostedLaunchDeferred && deferredHostControl != nil)
    }

    var acceptsInput: Bool {
        if case .live = state {
            return true
        }
        // A persistent tab's program takes input while its session is being
        // created (queued) and while its adapter reconnects (sent through
        // the host's control connection).
        if isPersistentLocalSession, isRunning {
            switch state {
            case .launching, .disconnected:
                return true
            case .live, .exited, .failed:
                break
            }
        }

        return false
    }

    var isRunning: Bool {
        activeLaunchID != nil
    }

    /// Whether the tab's program runs. A persistent tab's program runs from
    /// its launch until its host reports the exit, whether or not its attach
    /// adapter is connected; an exit the host listed before the tab heard of
    /// it counts. A tab attached to a hosted session only knows while its
    /// adapter runs.
    var isProgramRunning: Bool {
        guard isRunning else { return false }
        guard let persistentHosting, persistentPhase != .creating,
              let sessionID = persistentSession?.sessionID,
              let info = persistentHosting.sessionInfo(sessionID)
        else { return true }
        return info.isRunning
    }

    /// A Ghostty EXEC surface runs this tab's process: its shell, or for a
    /// hosted tab its attach adapter. Not while a persistent tab's session is
    /// still being created (a surface made meanwhile shows nothing yet).
    var usesNativePTYBackend: Bool {
        launchBackend == .nativePTY && isRunning && persistentPhase != .creating
    }

    /// The tab runs its program as a persistent session in the local host
    /// (it looks and behaves like a native tab).
    var isPersistentLocalSession: Bool {
        persistentHosting != nil
    }

    /// The home folder `~` stands for in this tab's paths: the device's
    /// for a tab of another Mac (from its check; "" when not known, so no
    /// path is shortened with This Mac's), else This Mac's.
    var pathHomeDirectory: String {
        guard let hosting = persistentHosting, !hosting.profile.isThisMac else { return NSHomeDirectory() }
        return hosting.profile.homeDirectory ?? ""
    }

    /// The device this tab's program runs on (docs/specs/remote-devices.md),
    /// by its name; nil for This Mac's tabs.
    var remoteMachineName: String? {
        persistentHosting.flatMap { $0.profile.isThisMac ? nil : $0.profile.displayName }
    }

    /// The directories the program reports (OSC 7) are on This Mac: a
    /// native or persistent tab, or one attached to a local session. A tab
    /// attached to an SSH host's session keeps its home directory.
    var reportsLocalWorkingDirectory: Bool {
        if persistentHosting?.profile.isThisMac == false { return false }
        return hostedAttachment.map { $0.host == .local } ?? true
    }

    /// The process id of the tab's program: its shell's session leader for
    /// a native tab, the local host's report for a persistent tab or one
    /// attached to a session of This Mac (see `hostedProgramProcessID`).
    /// For MCP caller routing, the pid MCP reports and port detection only;
    /// never signalled through this.
    var programProcessID: Int32? {
        childProcessID ?? hostedProgramProcessID
    }

    /// The tab's state as MCP reports it: a persistent tab whose attach
    /// adapter reconnects is `live`, because its program runs (its input
    /// and screen go through the host meanwhile).
    var programStateLabel: String {
        if case .disconnected = state, isPersistentLocalSession, isRunning {
            return SessionState.live.label
        }
        return state.label
    }

    /// A persistent tab's session is still being created (or adopted): its
    /// program has not started, input is queued.
    var isStartingPersistentSession: Bool {
        persistentPhase == .creating
    }

    /// The hosted session this tab shows, attached or persistent.
    var hostedSessionBinding: HostedSessionAttachment? {
        hostedAttachment ?? persistentSession
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
        // Closing a hosted tab only stops its disposable attach client.
        guard hostedAttachment == nil else { return false }
        guard isRunning else { return false }
        switch kind {
        case .command, .agent:
            return true
        case .terminal:
            if let persistentHosting {
                // The host reports the terminal's foreground job; the shell
                // is the session leader, so busy means another job runs.
                guard let sessionID = persistentSession?.sessionID else { return false }
                return persistentHosting.sessionInfo(sessionID)?.isBusy ?? false
            }
            if usesNativePTYBackend {
                // The native session leader can be /usr/bin/login, whose child
                // is the idle shell itself. Counting its children marks every
                // terminal busy; Ghostty already tracks the actual prompt. It
                // cannot see a shell without its shell integration at one
                // (or any shell before its first prompt), though: the PTY's
                // foreground job settles those.
                guard let bridge = ghosttyBridgeStorage, bridge.terminalView.needsConfirmQuit else { return false }
                guard let leader = bridge.nativeSessionLeaderPID() else { return true }
                return ShellProcessController.nativeShellHasForegroundJob(sessionLeaderPID: leader)
            }
            guard let shellPID = childProcessID else { return false }
            return ShellProcessController.shellHasForegroundProcess(shellPID: shellPID)
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
        if let hostedAttachment {
            guard !isRunning, let label = hostedAttachmentStatus?.sidebarLabel else {
                return hostedAttachment.host.displayName
            }
            return "\(hostedAttachment.host.displayName) · \(label)"
        }
        guard kind != .terminal else { return "" }
        return subtitle
    }

    /// A hosted session that ended on its host has nothing to reconnect to.
    var hostedSessionEnded: Bool {
        hostedAttachmentStatus?.sessionEnded == true
    }

    var canRestart: Bool { !hostedSessionEnded }

    func noteHostedSessionRemovedFromHost() {
        guard hostedSessionEnded else { return }
        hostedSessionRemovedFromHost = true
    }

    var restartActionTitle: String {
        hostedAttachment == nil ? "Restart" : "Reconnect"
    }

    var closeActionTitle: String {
        hostedAttachment == nil || hostedSessionEnded ? "Close" : "Disconnect & Close"
    }

    func snapshot(range: Range<Int>) -> [String] {
        contentSnapshot(range: range)
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
        let changed = self.parentAgentID != parentAgentID
        self.parentAgentID = parentAgentID
        if changed {
            persistentStateDidChange?()
        }
    }

    func send(text: String) {
        guard acceptsInput else { return }
        let data = Data(text.utf8)
        if !data.isEmpty {
            noteInputBurst(data)
        }
        if inputDebugEnabled {
            SessionLog.debugContent("[send text] \(text.debugDescription)")
        }
        if routePersistentInput(data) { return }
        if ghosttyBridgeStorage?.isNativePTYBacked == true && !usesInjectedTestingContent {
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
        // Ghostty's surface encodes the keys it is given for the program's
        // current modes (kitty flags, application cursor keys), so it gets
        // the input as sent. Only bytes that reach the program as they are
        // (the host's `SendInput`, a host-managed PTY) are normalized for
        // the kitty flags the program set.
        let toSurface = ghosttyBridgeStorage?.isNativePTYBacked == true && !usesInjectedTestingContent
            && !persistentInputGoesThroughHost
        let outboundData = normalize && !toSurface ? normalizedInputData(data) : data
        if !outboundData.isEmpty {
            noteInputBurst(outboundData)
            discardPendingOutputForInterrupt(in: outboundData)
        }
        if inputDebugEnabled {
            let rendered = outboundData.map { String(format: "%02x", $0) }.joined(separator: " ")
            SessionLog.debugContent("[send data] \(rendered) shellProcess=\(shellProcess != nil)")
        }
        if routePersistentInput(outboundData) { return }
        if toSurface {
            // Raw input's printable bytes are typed as they are, not pasted.
            ghosttyBridgeStorage?.sendNativeInput(outboundData, raw: !normalize)
            return
        }
        shellProcess?.write(outboundData)
    }

    /// Keys typed into the tab's EXEC surface reach no program now: a
    /// persistent tab whose attach adapter ended and is being launched
    /// again (`.reconnecting`, with backoff), or reconnects to its host by
    /// itself (it discards input meanwhile). The window's key monitor
    /// (`GhosttyTerminalContainerView`) sends them through the host
    /// instead, keeping the last screen shown. While the session is created
    /// the tab shows an in-memory surface, whose keys come to the tab
    /// anyway (`surfaceInputWithoutProcess`).
    var keyboardInputGoesThroughHost: Bool {
        persistentInputGoesThroughHost && persistentPhase != .creating
    }

    /// `routePersistentInput` takes a persistent tab's input now (queued
    /// or sent through its host), not its surface.
    private var persistentInputGoesThroughHost: Bool {
        guard persistentHosting != nil, isRunning else { return false }
        switch persistentPhase {
        case .creating, .reconnecting:
            return true
        case .attached:
            return adapterLiveStatus?.reconnecting == true && persistentSession != nil
        case .idle:
            return false
        }
    }

    enum ControlInputError: Error, Equatable {
        /// The tab takes no input now (its program ended or failed to start,
        /// or an attached session is disconnected): nothing was sent.
        case notAccepting(state: String)
        /// A persistent tab's host did not take the input for its program
        /// (the session ended, the host cannot be reached): nothing was sent.
        case notDelivered(String)
        /// The host took only the first part of the input: it went in
        /// several requests (longer than `HostProtocol.maxInputBytes`), and
        /// one after the first failed (`HostInputPartiallyDelivered`). The
        /// first `deliveredBytes` bytes of what was sent reached the
        /// program. The `unconfirmedBytes` after them (the part that
        /// failed, when its answer was lost; 0 when the host refused it)
        /// may or may not have; the rest was not sent. Resending all of it
        /// would type the first part twice.
        case partiallyDelivered(deliveredBytes: Int, reason: String, unconfirmedBytes: Int = 0)
        /// A persistent tab's host may have typed the input: it was sent,
        /// and the host's answer was lost (a transport failure after the
        /// request went out; input longer than one host request: its first
        /// part's). Nothing after that part was sent.
        case maybeDelivered(String)
    }

    /// Input on behalf of MCP, as `send(data:)` (`raw` false) or
    /// `sendRaw(data:)` types it, that says whether it reached the program.
    /// A persistent tab whose adapter is not known to be attached (it
    /// reconnects, or was just launched and the host has not reported it
    /// attached: `adapterPassesSignalsThrough`) sends it through the host's
    /// control connection and returns once the host took it. One whose
    /// session is still being created queues it and returns once the host
    /// took it after the session was created (or the native shell the tab
    /// fell back to got it). A tab attached to a hosted session sends it
    /// through its host's control connection too while its adapter is not
    /// launched yet (a restore) or reconnects by itself (the adapter
    /// discards what reaches it then). Throws, having sent nothing, when
    /// the tab cannot take input or the input did not reach the program;
    /// `partiallyDelivered` when the host typed only a first part of it.
    func sendControlInput(_ data: Data, raw: Bool) async throws {
        guard acceptsControlInput else { throw ControlInputError.notAccepting(state: state.label) }
        if hostedLaunchDeferred, let control = deferredHostControl, let binding = hostedAttachment {
            if Self.containsCursorModeKeys(data), !hostEncodesCursorKeys, await adapterTakesModeDependentInput() {
                sendInputData(data, normalize: !raw)
                return
            }
            // A restored attached tab whose adapter waits for its turn: the
            // host takes the input for its program now.
            try await sendAttachedInputThroughHost(data, raw: raw, control: control, binding: binding)
            return
        }
        if persistentHosting == nil, isRunning, adapterLiveStatus?.reconnecting == true,
           let binding = hostedAttachment, let control = attachedHostControl {
            // An attached tab whose adapter lost its host and reconnects by
            // itself: it discards input meanwhile (its screen is stale),
            // so the host takes it for the program, or says it could not.
            try await sendAttachedInputThroughHost(data, raw: raw, control: control, binding: binding)
            return
        }
        guard let persistentHosting, isRunning else {
            sendInputData(data, normalize: !raw)
            return
        }
        let throughHost: Bool
        switch persistentPhase {
        case .creating:
            try await queueControlInputUntilCreated(data, raw: raw, hosting: persistentHosting)
            return
        case .reconnecting:
            throughHost = true
        case .attached:
            throughHost = !adapterPassesSignalsThrough
        case .idle:
            throughHost = false
        }
        guard throughHost, let binding = persistentSession else {
            sendInputData(data, normalize: !raw)
            return
        }
        if Self.containsCursorModeKeys(data), !hostEncodesCursorKeys, await adapterTakesModeDependentInput() {
            sendInputData(data, normalize: !raw)
            return
        }
        let outboundData = hostTypedInputData(data, raw: raw)
        guard !outboundData.isEmpty else { return }
        noteInputBurst(outboundData)
        discardPendingOutputForInterrupt(in: outboundData)
        do {
            try await persistentHosting.sendInput(outboundData, to: binding).value
        } catch {
            throw Self.controlInputError(error)
        }
    }

    /// How long MCP input with cursor keys waits for the tab's attach
    /// adapter (`adapterTakesModeDependentInput`) before it goes through
    /// the host as sent. Only while the host does not report the program's
    /// cursor key mode (`hostEncodesCursorKeys`).
    var modeDependentInputAdapterWait: TimeInterval = 3

    /// The program's host reports its application cursor keys mode
    /// (DECCKM): MCP input the host types has its cursor keys encoded for
    /// that mode (`hostTypedInputData`), as a surface would, so it need not
    /// wait for an attach adapter. An older host does not report it.
    private var hostEncodesCursorKeys: Bool {
        hostReportedApplicationCursorKeys != nil
    }

    /// MCP input as the host types it: normalized for the program's kitty
    /// flags (unless `raw`), and its unmodified arrow, Home and End keys in
    /// the form the program's cursor key mode takes, when its host reports
    /// that mode. A surface re-encodes those keys for the mode too
    /// (`NativeInputTranslator`), raw or not.
    private func hostTypedInputData(_ data: Data, raw: Bool) -> Data {
        let outboundData = raw ? data : normalizedInputData(data)
        guard let application = hostReportedApplicationCursorKeys else { return outboundData }
        return TerminalInputNormalizer.encodingCursorKeys(outboundData, applicationCursorKeys: application)
    }

    /// Arrow, Home and End keys without modifiers (`ESC [ A`…, `ESC O A`…):
    /// how a terminal encodes them depends on the program's application
    /// cursor keys mode (DECCKM; `less` and `vim` turn it on), which only a
    /// host of this version reports (`HostedSessionInfo.applicationCursorKeys`).
    nonisolated static func containsCursorModeKeys(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0x1B, bytes[index + 1] == 0x5B || bytes[index + 1] == 0x4F,
               [0x41, 0x42, 0x43, 0x44, 0x46, 0x48].contains(bytes[index + 2]) {
                return true
            }
            index += 1
        }
        return false
    }

    /// Input whose encoding depends on the program's key modes (cursor
    /// keys) goes through the attach adapter's surface, whose Ghostty
    /// encodes keys for the modes the program set, as for a tab shown now.
    /// A restored tab whose adapter waits for its turn launches it now; an
    /// adapter just launched is waited for until it attached, at most
    /// `modeDependentInputAdapterWait`. False when no adapter takes the
    /// input then (it reconnects, or did not attach in time): the host
    /// types it as sent.
    private func adapterTakesModeDependentInput() async -> Bool {
        if isAwaitingDeferredLaunch {
            launchDeferredAdapterIfNeeded()
        }
        let deadline = Date().addingTimeInterval(modeDependentInputAdapterWait)
        while true {
            if persistentHosting != nil {
                guard isRunning, case .attached = persistentPhase else { return false }
                if adapterPassesSignalsThrough { return true }
            } else {
                guard hostedAttachment != nil, isRunning else { return false }
                if adapterLiveStatus?.followsProgram == true { return true }
            }
            if adapterLiveStatus?.reconnecting == true || Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// MCP input for a tab attached to a hosted session, sent through its
    /// host's control connection; returns once the host took it.
    private func sendAttachedInputThroughHost(
        _ data: Data,
        raw: Bool,
        control: HostControl,
        binding: HostedSessionAttachment
    ) async throws {
        let outboundData = hostTypedInputData(data, raw: raw)
        guard !outboundData.isEmpty else { return }
        noteInputBurst(outboundData)
        do {
            try await control.sendInput(binding.sessionID, outboundData, expectedHostID: binding.hostID)
        } catch {
            throw Self.controlInputError(error)
        }
    }

    /// MCP input while the session is being created: queued with the
    /// keyboard's, in order, and waited for until it reached the program
    /// (`PersistentInputDelivery`), at most `queuedInputTimeout`; input
    /// still queued then is dropped, so what the caller hears is true.
    private func queueControlInputUntilCreated(_ data: Data, raw: Bool, hosting: PersistentLocalSessions) async throws {
        let outboundData = raw ? data : normalizedInputData(data)
        guard !outboundData.isEmpty else { return }
        noteInputBurst(outboundData)
        discardPendingOutputForInterrupt(in: outboundData)
        let delivery = PersistentInputDelivery()
        pendingPersistentInput.append((outboundData, delivery))
        let timeout = hosting.configuration.queuedInputTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard !delivery.isResolved else { return }
            if let self {
                // Sent already (the host's answer resolves it), or still
                // queued: then it never will be.
                guard self.pendingPersistentInput.contains(where: { $0.delivery === delivery }) else { return }
                self.pendingPersistentInput.removeAll { $0.delivery === delivery }
            }
            delivery.resolve(.failure(ControlInputError.notDelivered(
                "its session was not started within \(Int(timeout)) seconds"
            )))
        }
        try await delivery.value()
    }

    /// Resolves the deliveries of input still queued for a session that
    /// will not be created (the tab stopped or started again): nothing of
    /// it was sent.
    private func dropPendingPersistentInput(because reason: String) {
        let dropped = pendingPersistentInput
        pendingPersistentInput.removeAll()
        for entry in dropped {
            entry.delivery?.resolve(.failure(ControlInputError.notDelivered(reason)))
        }
    }

    private static func inputFailureReason(_ error: Error) -> String {
        if let error = error as? ControlInputError, case .notDelivered(let reason) = error { return reason }
        return (error as? HostedSessionError)?.errorDescription ?? error.localizedDescription
    }

    /// What MCP hears when its input did not (all) reach the program
    /// through the host: a first part typed (`HostInputPartiallyDelivered`)
    /// is not "nothing was sent".
    private static func controlInputError(_ error: Error) -> ControlInputError {
        if let error = error as? ControlInputError { return error }
        if let error = error as? HostedSessionError, error.isTransportFailure {
            return .maybeDelivered(inputFailureReason(error))
        }
        if let partial = error as? HostInputPartiallyDelivered {
            return .partiallyDelivered(
                deliveredBytes: partial.deliveredBytes,
                reason: partial.failure.errorDescription ?? partial.failure.localizedDescription,
                unconfirmedBytes: partial.unconfirmedBytes
            )
        }
        return .notDelivered(inputFailureReason(error))
    }

    func sendInterrupt() {
        guard acceptsInput else { return }
        if inputDebugEnabled {
            SessionLog.debug("[send interrupt] shellProcess=\(shellProcess != nil)")
        }
        noteAgentDraftCleared()
        noteAgentTurnInterrupted()
        processor.discardPendingOutput()
        if routePersistentInput(Data([0x03])) { return }
        if ghosttyBridgeStorage?.isNativePTYBacked == true && !usesInjectedTestingContent {
            ghosttyBridgeStorage?.sendNativeInput(Data([0x03]))
            return
        }
        shellProcess?.writeUrgent(Data([0x03]))
    }

    func noteNativeHostInput(event: NSEvent?) {
        clearCurrentAttentionScreenTag()
        noteInputOutputBaseline()
        guard kind == .agent, let event else { return }
        if event.type == .keyDown {
            lastAgentInputAt = Date()
        }
        applyAgentDraftInputEffect(Self.appKitDraftInputEffect(event))
        if Self.appKitKeyEventInterruptsAgentTurn(event) {
            noteAgentTurnInterrupted()
        }
    }

    /// Mirror the kernel tty's flush-on-INTR for Cherry's own pipeline:
    /// when host input carries ^C, drop output we've already queued
    /// internally so the interrupt takes effect immediately even when a
    /// flooding process has megabytes buffered ahead of it. Kitty-protocol
    /// encodings of ^C don't match the raw byte — protocol-aware apps
    /// manage their own interrupt handling.
    private func discardPendingOutputForInterrupt(in outboundData: Data) {
        guard outboundData.contains(0x03) else { return }
        noteAgentTurnInterrupted()
        processor.discardPendingOutput()
    }

    /// Clear Scrollback (⌘K) and MCP `clear_output`: the tab's screen and
    /// history, and for a persistent tab its host's copy of the history too
    /// (`clearHostHistory`), which reads through the host (MCP output and
    /// search) and the next attach adapter would otherwise bring back.
    /// Returns the host's clear, for a caller that waits for it: nil when
    /// the host cleared it, else why it kept it.
    @discardableResult
    func clearScrollback() -> Task<String?, Never>? {
        clearScrollback(preservingTerminalState: true)
        return clearHostHistory()
    }

    /// Asks a persistent tab's host to clear its session's history
    /// (`ClearHistory`). The screen read from the host before is forgotten,
    /// and a read under way no longer applies. When the host keeps it (the
    /// alternate screen shows, the session's holder predates holder link 7
    /// or is not connected now, or the host cannot be reached), the task
    /// says why, and that is logged.
    private func clearHostHistory() -> Task<String?, Never>? {
        guard let persistentHosting, let binding = persistentSession else { return nil }
        forgetHostContent()
        let tabID = id
        return Task { @MainActor in
            do {
                try await persistentHosting.clearHistory(of: binding)
                return nil
            } catch {
                let reason = (error as? HostedSessionError)?.errorDescription ?? error.localizedDescription
                SessionLog.notice("the host kept the history of tab \(tabID.uuidString): \(reason)")
                return reason
            }
        }
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

    /// A bell or notification the user has not seen reached this tab's
    /// program while no tab showed it (its saved record, or its session in
    /// the background): the tab shows it unread.
    func markUnread() {
        guard !hasUnreadNotification else { return }
        hasUnreadNotification = true
        bumpRevision()
        persistentStateDidChange?()
    }

    func clearUnreadNotification() {
        guard hasUnreadNotification || lastNotification != nil else { return }
        hasUnreadNotification = false
        lastNotification = nil
        bumpRevision()
    }

    /// Returns false when nothing was relaunched because the hosted session
    /// ended. A live hosted tab learns that from `stop()`: the adapter may
    /// have written its `exited` outcome before the tab saw it exit.
    @discardableResult
    func restart() -> Bool {
        guard canRestart else { return false }
        resetAutoRestartPolicy()
        stop()
        guard canRestart else { return false }
        clearScrollback(preservingTerminalState: false)
        startShell()
        return true
    }

    /// `takeover` also relaunches a connected tab so it replaces the
    /// session's other clients.
    @discardableResult
    func reconnectHostedSession(takeover: Bool = false) -> Bool {
        if isPersistentLocalSession {
            return reconnectPersistentAdapterNow(takeover: takeover)
        }
        guard hostedAttachment != nil, takeover || !isRunning else { return false }
        hostedTakeoverForNextLaunch = takeover
        let relaunched = restart()
        hostedTakeoverForNextLaunch = false
        return relaunched
    }

    func disconnectHostedSession() {
        guard hostedAttachment != nil else { return }
        stop()
        releaseGhosttyBridge()
    }

    func restartManagedCommandIfNeeded() {
        guard kind == .command else { return }
        resetAutoRestartPolicy()

        switch state {
        case .launching, .live:
            return
        case .disconnected where isPersistentLocalSession && isRunning:
            // The program still runs on its host; only its adapter is
            // reconnecting. Starting it again would end it.
            reconnectHostedSession()
        case .exited, .failed, .disconnected:
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
            persistentStateDidChange?()
            syncHostSessionName(title)
            return
        }

        title = trimmedTitle
        titleSource = .explicit
        bumpRevision()
        persistentStateDidChange?()
        syncHostSessionName(title)
    }

    /// An agent's task title reaches its session's host name this long
    /// after it last changed.
    static let hostSessionNameDelay: TimeInterval = 1

    /// Names this tab's persistent session on its host `name` (an explicit
    /// rename, or clearing one), so the host's list (`cherry list`,
    /// Background Sessions, the Persistent Sessions sheet) names it as the
    /// tab does. Only a session this tab owns; nothing when the host has
    /// that name already. A tab whose session is still being created sends
    /// it once bound (`bindPersistentSession`).
    private func syncHostSessionName(_ name: String) {
        hostSessionNameSync?.cancel()
        hostSessionNameSync = nil
        guard isPersistentLocalSession, let persistentHosting, let persistentSession,
              let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else { return }
        // As the host keeps it: a long name is not sent again at each bind.
        let name = PersistentLocalSessions.truncated(trimmed, toBytes: PersistentLocalSessions.maxSessionNameBytes)
        guard name != hostSessionName else { return }
        hostSessionName = name
        persistentHosting.rename(persistentSession, to: name)
    }

    /// The task title an agent's tab shows changed: it names the session on
    /// its host once it has settled (`hostSessionNameDelay`), unless the
    /// user named the tab.
    private func scheduleHostSessionNameSync() {
        guard isPersistentLocalSession, titleSource == .automatic else { return }
        hostSessionNameSync?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.titleSource == .automatic else { return }
            self.syncHostSessionName(self.title)
        }
        hostSessionNameSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hostSessionNameDelay, execute: work)
    }

    /// `keepingSession`: the tab closes detaching from its program
    /// (`SessionCloseAction.detach`: a window close or quit that keeps
    /// sessions running, or a detach), which keeps running on its host. A persistent tab whose
    /// Create is still under way then keeps the session it makes too: the
    /// tab's saved record names it (`launchRequestID`) and brings it back.
    /// Otherwise (a stop, restart, or a close that ends sessions) that
    /// session is ended when Create answers.
    func stop(keepingSession: Bool = false) {
        pendingAutoRestart?.cancel()
        pendingAutoRestart = nil
        hostReconnects?.stopWaiting(self)
        // A restored tab stopped before its adapter launched: it never will.
        let wasAwaitingAttach = hostedLaunchDeferred
        hostedLaunchDeferred = false
        persistentAdapterDeferred = false
        stopFollowingDeferredHostEvents()
        finalScreenRead?.cancel()
        finalScreenRead = nil
        let launchID = activeLaunchID
        activeLaunchID = nil
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
        lastHumanKeystrokeAt = nil
        hasUnsubmittedHumanInput = false
        outputHoldUntil = nil
        pendingResolvedCommandLine = nil
        resolvedCommandLine = nil
        processor.endLaunch(launchID)
        updateShellOutputPauseState()
        hostInputWriter.set(nil)
        // Stopping kills only the local adapter. A close reported before the
        // exit callback may follow an outcome the adapter already wrote, so
        // read it before signalling: what the adapter writes while handling
        // this hangup ("interrupted by signal 1") describes this stop, not
        // the session. That late write is why the directory stays a while.
        let hostedStatus = hostedAttachment != nil && launchID != nil
            ? consumeHostedLaunchStatus(removingAfter: 2) ?? .disconnected(nil)
            : nil
        if let persistentHosting {
            // Only the adapter stops: the program keeps running on its host
            // unless the caller ends the session (`endPersistentSession`).
            cancelPersistentReconnect()
            persistentDisappearanceCheck?.cancel()
            persistentDisappearanceCheck = nil
            if persistentPhase == .creating {
                if keepingSession {
                    // Left running for the tab's saved record, which names
                    // it by its Create's request id.
                    persistentLaunchClaim?.keepsSession = true
                } else {
                    // The session being created is ended when Create answers
                    // (even if a quit's teardown had left it to the exit).
                    persistentLaunchClaim?.keepsSession = false
                    persistentLaunchRequestID = nil
                }
            }
            persistentPhase = .idle
            dropPendingPersistentInput(because: "the tab stopped before its session started")
            _ = consumeHostedLaunchStatus(removingAfter: 2)
            if let persistentSession {
                persistentHosting.unbind(self, from: persistentSession.sessionID)
            }
        }
        if ghosttyBridgeStorage?.isNativePTYBacked == true {
            // Native-PTY: ghostty owns the PTY and there is no shellProcess to
            // terminate, so signal the whole controlling-terminal session. A
            // server that ignores SIGHUP and moved into its own process group can
            // otherwise survive both the PTY close and a shell-only kill.
            // A hosted tab's own process is its attach adapter. Its program
            // (`hostedProgramProcessID`) is the host's child, which a stop
            // must never signal; `childProcessID` stays nil for it, and is
            // only trusted here for a tab that owns its process tree.
            let ownsProgram = hostedAttachment == nil && !isPersistentLocalSession
            if let anchorPID = (ownsProgram ? childProcessID : nil)
                ?? ghosttyBridgeStorage?.nativeSessionLeaderPID() {
                terminateNativeSession(anchorPID)
            }
        }
        if isPersistentLocalSession {
            // The tab no longer follows the program (it may keep running).
            hostedProgramProcessID = nil
            hostSessionSharing = nil
            progressReport = nil
            forgetHostContent()
        } else if hostedAttachment != nil {
            hostedProgramProcessID = nil
        }
        shellProcess?.terminate()
        shellProcess = nil
        if let hostedStatus {
            applyHostedStatus(hostedStatus)
        } else if wasAwaitingAttach {
            applyHostedStatus(.disconnected(nil))
        }
    }

    /// Stops the tab's program (MCP `stop_process`): a native tab's process
    /// tree, or a persistent tab's host session. The tab then shows its
    /// program ended cleanly (`exit 0`, exit code 0, `exitedAt` now), as a
    /// stopped command does, whatever signal ended it: it stopped because
    /// it was asked to, and starting it again relaunches it. A tab attached
    /// to a hosted session only disconnects.
    func stopProgram() {
        let wasRunning = isRunning
        stop()
        endPersistentSession()
        guard wasRunning, hostedAttachment == nil else { return }
        switch state {
        case .exited, .failed:
            break
        case .launching, .live, .disconnected:
            markStoppedOnRequest()
        }
    }

    /// The program was stopped on request: a clean exit, reported as one
    /// (a program that had ended already keeps its exit time).
    private func markStoppedOnRequest() {
        state = .exited(0)
        exitCode = 0
        exitedAt = exitedAt ?? Date()
        bumpRevision()
    }

    /// Ends a persistent tab's host session: Kill, then Remove once it
    /// exited (bounded; see `PersistentLocalSessions.end`). The tab no
    /// longer names it. Close intents that terminate call this after
    /// `stop()`; a tab still creating its session ends it when Create answers.
    func endPersistentSession() {
        guard let persistentHosting, let binding = persistentSession else { return }
        persistentSession = nil
        persistentLaunchRequestID = nil
        persistentHosting.end(binding)
        persistentStateDidChange?()
    }

    /// A quit keeping sessions leaves the tab as it is until the app exits
    /// (`TerminalWorkspace.closeSessionsForQuit`): a Create under way keeps
    /// the session it makes, as `stop(keepingSession: true)` would, so the
    /// quit does not wait for it (`waitForPersistentLaunches`).
    func keepSessionUntilExit() {
        persistentLaunchClaim?.keepsSession = true
    }

    /// The tab closed (after its close action ran): it no longer owns the
    /// session it names. A session it kept running can then be attached as
    /// another tab's own, or restored.
    func persistentTabDidClose() {
        persistentDisappearanceCheck?.cancel()
        persistentDisappearanceCheck = nil
        persistentTabRegistry?.unregister(self)
        persistentTabRegistry = nil
        if isRegisteredAsAttachedTab {
            OpenHostedTabs.shared.unregister(self)
            isRegisteredAsAttachedTab = false
        }
        stopFollowingDeferredHostEvents()
    }

    /// Ghostty asked to close the surface (after its process exited and a key
    /// was pressed). A persistent tab's surface belongs to its adapter; its
    /// program's fate comes from its host, so this never stops it.
    func nativeSurfaceDidClose() {
        guard !isPersistentLocalSession else { return }
        stop()
    }

    /// A tab attached to a hosted session (not owning it) takes what its
    /// host reports about the program: its alternate screen and keyboard
    /// flags until its adapter launches (then only its host's control
    /// connection, while up, reports them: `hostReportedSessionInfo`),
    /// and, for a session of This Mac, its pid, which MCP caller
    /// routing, the pid MCP reports and port detection use while the
    /// adapter runs. Nothing signals it (`stop()` hangs up only on the
    /// adapter). Another machine's session never gives a pid.
    func noteAttachedLocalSession(_ info: HostedSessionInfo) {
        guard let hostedAttachment, info.id == hostedAttachment.sessionID else { return }
        attachedSessionInfo = info
        noteHostSessionSharing(info)
        guard hostedAttachment.host == .local else { return }
        attachedLocalProgramProcessID = info.isRunning ? info.pid.map { Int32(bitPattern: $0) } : nil
        if isRunning, hostedAttachmentStatus == .active {
            hostedProgramProcessID = attachedLocalProgramProcessID
        }
    }

    /// The hosted program's state as the adapter reported it. Only an
    /// `exited` outcome is an exit. An attach that failed is a failed launch,
    /// not a disconnect: nothing was attached, and its message says why.
    private func applyHostedStatus(_ status: HostedAttachmentStatus) {
        hostedAttachmentStatus = status
        if status != .active {
            // Only known while the adapter runs.
            hostedProgramProcessID = nil
        }
        switch status {
        case .exited(let code, let signal):
            // The program is gone; its pid may be reused.
            attachedLocalProgramProcessID = nil
            let reportedCode = code ?? signal.map { 128 + $0 } ?? 0
            exitCode = reportedCode
            exitedAt = Date()
            state = .exited(reportedCode)
        case .failed(let message):
            exitCode = nil
            exitedAt = nil
            state = .failed(message)
        case .active, .disconnected, .takenOver:
            exitCode = nil
            exitedAt = nil
            state = .disconnected
        }
        bumpRevision()
    }

    /// The ended launch's final outcome (nil when it wrote none); the
    /// launch's live state is forgotten.
    private func consumeHostedLaunchStatus(removingAfter delay: TimeInterval) -> HostedAttachmentStatus? {
        stopWatchingAdapterStatus()
        hostedLaunchRetryable = false
        guard let directory = hostedPendingStatusDirectory else { return nil }
        hostedPendingStatusDirectory = nil
        let ending = HostedAttachmentStatusFile.readEnding(from: directory)
        hostedLaunchRetryable = ending?.retryable ?? false
        HostedAttachmentStatusFile.removeLaunchDirectory(directory, after: delay)
        return ending?.status
    }

    /// `HostedReconnects` put this tab in (or took it out of) its wait for
    /// the host.
    func setWaitingForHost(_ waiting: Bool) {
        guard isWaitingForHost != waiting else { return }
        isWaitingForHost = waiting
        bumpRevision()
    }

    /// Its host answered in a way connecting again cannot resolve (another
    /// identity, a protocol this app cannot use, a session it no longer
    /// has): the tab stops waiting and says why; Reconnect tries again.
    func stopWaitingForHost(because reason: String) {
        setWaitingForHost(false)
        guard hostedAttachment != nil, !isRunning else { return }
        applyHostedStatus(.failed(reason))
    }

    private func stopWatchingAdapterStatus() {
        adapterStatusWatcher?.cancel()
        adapterStatusWatcher = nil
        adapterReconnectingNotice?.cancel()
        adapterReconnectingNotice = nil
        if adapterLiveStatus != nil { adapterLiveStatus = nil }
        if isAdapterReconnecting { isAdapterReconnecting = false }
    }

    /// Follows the live state the adapter of the launch in `directory`
    /// writes to its status file.
    private func watchAdapterStatus(in directory: URL) {
        stopWatchingAdapterStatus()
        adapterStatusWatcher = HostedAdapterStatusWatcher(directory: directory) { [weak self] status in
            self?.adapterLiveStatusDidChange(status, launchDirectory: directory)
        }
    }

    /// The running adapter reported a new live state: attached (following
    /// the program, possibly as a viewport) or reconnecting by itself. The
    /// adapter keeps its surface either way: nothing is relaunched. A
    /// persistent tab's reconnects start over once it follows the program,
    /// and the host's title and directory apply while it reconnects.
    private func adapterLiveStatusDidChange(_ status: HostedAdapterLiveStatus, launchDirectory: URL) {
        guard launchDirectory == hostedPendingStatusDirectory, isRunning else { return }
        let wasFollowing = adapterLiveStatus?.followsProgram ?? false
        adapterLiveStatus = status
        if hostedAttachment != nil, status.followsProgram {
            hostReconnects?.tabAttached(self)
        }
        if status.reconnecting {
            scheduleAdapterReconnectingNotice()
        } else {
            adapterReconnectingNotice?.cancel()
            adapterReconnectingNotice = nil
            if isAdapterReconnecting { isAdapterReconnecting = false }
        }
        if let persistentHosting, case .attached = persistentPhase {
            if status.followsProgram, !wasFollowing {
                adapterFollowingSince = Date()
                adapterFollowingControlGeneration = persistentHosting.control.state == .connected
                    ? persistentHosting.connectionGeneration
                    : nil
                surfaceSignalsWhileFollowing.removeAll()
            }
            if status.followsProgram {
                persistentReconnectFailures = 0
                if case .disconnected = state { state = .live }
            } else if wasFollowing, let binding = persistentSession,
                      let info = persistentHosting.sessionInfo(binding.sessionID), info.isRunning {
                applyHostReportedTitleAndDirectory(of: info, resynchronizing: true)
            }
        }
        bumpRevision()
    }

    /// Shows that the adapter reconnects once it has for the notice delay.
    private func scheduleAdapterReconnectingNotice() {
        guard adapterReconnectingNotice == nil, !isAdapterReconnecting else { return }
        let delay = persistentHosting?.configuration.adapterReconnectingNoticeDelay ?? Self.adapterReconnectingNoticeDelay
        let directory = hostedPendingStatusDirectory
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.hostedPendingStatusDirectory == directory,
                  self.adapterLiveStatus?.reconnecting == true
            else { return }
            self.adapterReconnectingNotice = nil
            self.isAdapterReconnecting = true
            if self.isPersistentLocalSession, case .attached = self.persistentPhase, case .live = self.state {
                self.state = .disconnected
            }
            self.bumpRevision()
        }
        adapterReconnectingNotice = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
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
            stopProgram()
            return
        }

        stopProgram()
        if state != .exited(0) || exitCode != 0 {
            markStoppedOnRequest()
        }
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
        persistentStateDidChange?()
    }

    /// Until its surface reports its grid, the tab assumes `size`: the grid
    /// of a terminal its window shows now (`TerminalWorkspace`), which a new
    /// tab shown there gets too. A persistent tab's Create, which goes out
    /// before the surface is laid out, then starts the program at that size
    /// rather than at a default it is resized from a moment later.
    func seedViewportSize(_ size: TerminalViewportSize) {
        guard !viewportWasReported, size.columns > 0, size.rows > 0, size != viewportSize else { return }
        viewportSize = size
        renderedReplayCache = nil
        processor.resize(to: size)
    }

    func resize(columns: Int, rows: Int, forceShellResize: Bool = false) {
        let nextSize = TerminalViewportSize(columns: columns, rows: rows)
        guard nextSize.columns > 0, nextSize.rows > 0 else { return }
        viewportWasReported = true
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
        usesInjectedTestingContent = true
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
        discardPendingOutputForInterrupt(in: data)
    }
#endif

    func rawOutput(maxBytes: Int) -> (data: Data, truncated: Bool) {
        if readsContentFromHost || (ghosttyBridgeStorage?.isNativePTYBacked == true && !usesInjectedTestingContent) {
            // Native-PTY: the host owns no byte stream, so the surface IS the
            // source of truth. NOTE: this is rendered text, not raw VT bytes — a
            // deliberate semantic change for native panes (no escape sequences, no
            // exact byte fidelity). A persistent tab whose surface does not
            // show its program gives the host's screen instead.
            let text = readsContentFromHost
                ? nativeContentLines.joined(separator: "\n")
                : readNativeSurfaceText() ?? ""
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
        // A restored tab being shown attaches now, ahead of the restore's
        // queue: its adapter's surface is the one to show. The surface view
        // asks from inside a SwiftUI view update, where publishing is not
        // allowed: the revision bump waits for the next turn.
        isBuildingBridgeForView = true
        let launched = launchDeferredAdapterIfNeeded()
        isBuildingBridgeForView = false
        if launched, let ghosttyBridgeStorage {
            return ghosttyBridgeStorage
        }

        let bridge = GhosttySessionBridge(session: self)
        ghosttyBridgeStorage = bridge
        return bridge
    }

    /// Launch configuration for the Ghostty EXEC surface.
    private func shellLaunchConfiguration(workingDirectory: String? = nil) -> ShellProcessController.Configuration {
        ShellProcessController.Configuration(
            shellPath: ShellProcessController.defaultShellPath,
            workingDirectory: workingDirectory ?? self.workingDirectory,
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
        if let attachment = hostedAttachment ?? (isPersistentLocalSession ? persistentSession : nil) {
            // Pure: the launch was registered with the SSH master (if any)
            // when it started, so a rebuilt surface keeps the same command.
            return (
                attachment.execCommand(
                    statusFile: hostedLaunchStatusFile,
                    takeover: hostedLaunchTakesOver,
                    sshControlPath: hostedLaunchSSHControlPath,
                    // Every launch of this tab's adapter attaches as the same
                    // client: the host replaces the tab's previous attachment,
                    // and the replaced adapter exits with outcome "replaced"
                    // instead of reconnecting. Only the active launch's exit
                    // leads to a reconnect, so two adapters of one tab settle
                    // after one swap. A surface is freed (its adapter killed
                    // and waited for) before the next one launches
                    // (`GhosttySessionBridge.relaunchNativeSurface`).
                    clientID: id.uuidString,
                    sizeFile: hostedLaunchSizeFile
                ),
                attachment.adapterEnvironment
            )
        }
        if isPersistentLocalSession {
            // No session yet: a surface is never launched before the session
            // exists, but must not fall back to a native shell if it were.
            return ("/usr/bin/true", [:])
        }
        let resolved = ShellProcessController.nativeExecLaunch(for: shellLaunchConfiguration())
        return (resolved.command, resolved.environment)
    }

    /// Where the Ghostty surface starts its process. A hosted or persistent
    /// tab's surface runs its attach adapter, which needs no directory of
    /// the program's: a stable one keeps the adapter launchable when the
    /// program's directory (which the tab follows) is deleted.
    var nativeSurfaceWorkingDirectory: String {
        hostedAttachment != nil || isPersistentLocalSession ? NSHomeDirectory() : workingDirectory
    }

    /// A fresh status file (and SSH master registration) for the next
    /// adapter launch; the previous launch's directory goes after a delay.
    private func prepareHostedAdapterLaunch(for attachment: HostedSessionAttachment) {
        hostedLaunchTakesOver = hostedTakeoverForNextLaunch
        hostedTakeoverForNextLaunch = false
        stopWatchingAdapterStatus()
        if let previous = hostedPendingStatusDirectory {
            HostedAttachmentStatusFile.removeLaunchDirectory(previous, after: 2)
        }
        // Each adapter launch reports through its own fresh status file.
        hostedPendingStatusDirectory = try? HostedAttachmentStatusFile.makeLaunchDirectory()
        hostedLaunchStatusFile = hostedPendingStatusDirectory.map(HostedAttachmentStatusFile.statusFileURL(in:))
        // The new surface says its grid as it is built; a window whose size
        // is changing says so first, so that the adapter waits for it.
        hostedLaunchSizeFile = hostedPendingStatusDirectory.map(HostedAttachmentStatusFile.sizeFileURL(in:))
        announcedAdapterWindowSize = nil
        ghosttyBridgeStorage?.announceAdapterWindowSize()
        if let directory = hostedPendingStatusDirectory {
            watchAdapterStatus(in: directory)
        }
        // Registered once per launch, here: computing the command again (a
        // surface rebuild) must neither register it again nor change it.
        hostedLaunchSSHControlPath = hostedLaunchStatusFile.flatMap { attachment.registerAdapterLaunch(statusFile: $0) }
    }

    private func startShell() {
        resumePersistentHostingAfterFallback()
        if hostSessionEnd != nil { hostSessionEnd = nil }
        if systemSessionEnd != nil {
            // Started again: no longer the tab the system ended.
            systemSessionEnd = nil
            systemEndExitStatus = nil
            persistentStateDidChange?()
        }
        let launchID = UUID()
        activeLaunchID = launchID
        // A restored or adopted session (`persistentSessionToAdopt`, taken
        // by `startPersistentLaunch`) and an attached one were running
        // before this launch.
        startedCurrentProgram = hostedAttachment == nil
            && (persistentHosting == nil || persistentSessionToAdopt == nil)
        cancelPersistentReconnect()
        if let hostedAttachment {
            hostedAttachmentStatus = .active
            prepareHostedAdapterLaunch(for: hostedAttachment)
        }
        resetAutomaticTitleForNewAgentLaunch()
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
        programStartedAt = startedAt
        exitedAt = nil
        lastOutputAt = nil
        lastHumanInputAt = nil
        lastHumanKeystrokeAt = nil
        hasUnsubmittedHumanInput = false
        usesInjectedTestingContent = false
        attentionClassifierPrediction = nil
        attentionAlertGeneration = 0
        acknowledgedAttentionAlertGeneration = 0
        hasUnacknowledgedAttention = false
        isAttentionEpisodeActive = false
        hasHarnessNotificationForAttentionEpisode = false
        attentionNotificationGate = TerminalAttentionNotificationGate()
        clearCurrentAttentionScreenTag()
        latestAttentionObservationEvent = .contentChanged
        agentTurnState = .notStarted
        resumedWorkDetector.disarm()
        lastAgentInputAt = nil
        childProcessID = nil
        // A session of This Mac's program, while the adapter runs; never
        // another machine's.
        hostedProgramProcessID = hostedAttachment?.host == .local ? attachedLocalProgramProcessID : nil
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

        if launchBackend == .nativePTY {
            if let persistentHosting {
                startPersistentLaunch(launchID, hosting: persistentHosting)
            } else {
                launchNativeSurface()
            }
            return
        }

        // Deterministic shell/renderer tests use the explicit host-managed
        // dependency. No app setting or environment variable selects this path.
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
                        guard let self, self.activeLaunchID == launchID else { return }
                        self.finishProcessExit(status: status, launchID: launchID)
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
            processor.appendPlainLines(["launch failed: \(error.localizedDescription)"])
            bumpRevision()
        }
    }

    /// The Ghostty surface is the sole production PTY owner. Reach `.live`
    /// before constructing it so the bridge selects EXEC, then eagerly create
    /// it: background work must start before its tab is opened.
    private func launchNativeSurface() {
        shellProcess = nil
        hostInputWriter.set(nil)
        childProcessID = nil
        // The shell starts now, also after a persistent session could not.
        programStartedAt = Date()
        state = .live
        bumpRevision()
        if let bridge = ghosttyBridgeStorage {
            bridge.relaunchNativeSurface()
        } else {
            _ = ghosttyBridge
        }
        // A hosted tab's local process is only the attach adapter; the
        // hosted program has no local PID to report.
        if hostedAttachment == nil {
            captureNativeShellIdentity()
        }
    }

    // MARK: Persistent local session

    /// Starts the tab's program in the local host: ends the previous session
    /// (a restart or auto-restart; bounded), creates a new one with the tab's
    /// launch configuration, or adopts a restored one, then runs its attach
    /// adapter in the surface. Until then the tab is `.launching` and input
    /// is queued. When the host cannot start it, the tab runs natively.
    private func startPersistentLaunch(_ launchID: UUID, hosting: PersistentLocalSessions) {
        persistentFailedLaunchID = nil
        if persistentLaunchFailureReason != nil { persistentLaunchFailureReason = nil }
        persistentPhase = .creating
        persistentReconnectFailures = 0
        persistentReconnectMisses = 0
        dropPendingPersistentInput(because: "the tab started again before its session existed")
        shellProcess = nil
        hostInputWriter.set(nil)
        childProcessID = nil
        hostedProgramProcessID = nil
        progressReport = nil
        lastHostReportedTitle = nil
        lastHostReportedDirectory = nil
        recentSignalDeliveries.removeAll()
        forgetHostContent()
        state = .launching
        bumpRevision()

        let adopted = persistentSessionToAdopt
        persistentSessionToAdopt = nil
        if adopted == nil {
            // Started again (a restart): it runs its own new session now.
            clearProvisionalRestore()
        }
        if adopted == nil, let bridge = ghosttyBridgeStorage, bridge.isNativePTYBacked {
            // A restart: the previous adapter's surface shows a program that
            // is gone, and keys typed into it would reach nothing. Until the
            // new session's adapter launches, an in-memory surface takes
            // them, and they are queued for the new program.
            bridge.relaunchInMemorySurface()
        }
        if let adopted, persistentAdapterDeferred {
            // A restored tab follows its session from now on, before any
            // other tab or restore could claim it; its adapter waits.
            bindPersistentSession(adopted, launchID: launchID, hosting: hosting)
            return
        }
        persistentAdapterDeferred = false
        let previous = persistentSession.flatMap { $0.sessionID == adopted?.attachment.sessionID ? nil : $0 }
        if let previous {
            hosting.unbind(sessionID: previous.sessionID)
        }
        let request = PersistentSessionRequest(
            tabID: id,
            name: title,
            kind: kind,
            agentName: agentName,
            commandName: commandName,
            projectRoot: projectRoot,
            columns: viewportSize.columns,
            rows: viewportSize.rows
        )
        if adopted == nil {
            // Recorded with the tab now, so a relaunch can find the session
            // this Create starts even if its answer is never saved (the
            // record's launch request id matches the session's). The save
            // is not synchronous: the workspace saves a newly added tab on
            // the next main-loop turn and a restart after its usual delay,
            // and the store writes in the background, while the Create goes
            // out only after this launch's awaits below. So the record
            // usually, not always, lands first. A crash in between leaves
            // a session no record names; the next restore still finds it
            // by its `cherry.tab` tag (WorkspaceRestore's `taggedSession`
            // for a saved tab that restarted, RepositoryWorkspace's orphan
            // scan for a new tab).
            persistentLaunchRequestID = request.requestID.uuidString.lowercased()
            persistentStateDidChange?()
        }
        // What the program starts with is decided now, as for a native tab.
        // The host refuses a directory that no longer exists (the tab's
        // last one was deleted): the program starts where the tab started,
        // or in the project, instead.
        let configuration = shellLaunchConfiguration(
            workingDirectory: hosting.profile.isThisMac
                ? [workingDirectory, launchWorkingDirectory, projectRoot]
                    .compactMap { $0 }
                    .first(where: Self.isExistingDirectory) ?? NSHomeDirectory()
                // Another Mac's directories are not looked for here: its
                // host refuses one that does not exist.
                : [workingDirectory, launchWorkingDirectory, projectRoot.map(ProjectLocation.launchPath(forKey:))]
                    .compactMap { $0?.nilIfEmpty }
                    .first ?? "~"
        )
        let earlierLaunch = persistentLaunchTask
        let restartExitTimeout = hosting.configuration.restartExitTimeout
        let launchKey = UUID()
        let claim = PersistentLaunchClaim(tab: self, launchID: launchID, hosting: hosting, creates: adopted == nil)
        persistentLaunchClaim = claim
        defer {
            if let task = persistentLaunchTask {
                Self.persistentLaunchesInFlight[launchKey] = (task, claim)
                Task { @MainActor in
                    await task.value
                    Self.persistentLaunchesInFlight[launchKey] = nil
                }
            }
        }
        persistentLaunchTask = Task { @MainActor [weak self] in
            let launch: PersistentSessionLaunch
            do {
                if let adopted {
                    launch = adopted
                } else {
                    // One launch at a time: an earlier launch of this tab
                    // still waiting for its program to exit or for its
                    // Create (a restart pressed twice, or while a Create is
                    // under way) finishes first, having ended the session
                    // it no longer needs, so two programs of the tab never
                    // run at once (a server releases its port). Bounded: a
                    // host that does not answer delays this launch no more.
                    if let earlierLaunch {
                        await Self.wait(
                            for: earlierLaunch,
                            upTo: restartExitTimeout * 2 + .seconds(hosting.configuration.creationTimeout)
                        )
                    }
                    if let previous {
                        await hosting.end(previous, waitingForExitUpTo: restartExitTimeout).value
                    }
                    // Stopped, closed or started again while the previous
                    // program exited: this launch starts nothing.
                    guard let self, self.activeLaunchID == launchID, self.persistentHosting === hosting else { return }
                    self.schedulePersistentCreationDeadline(launchID, hosting: hosting)
                    // At the grid the window that shows the tab settled at,
                    // asked for only once the host is reached and the launch
                    // spec is ready: a new window settles meanwhile.
                    let startedAt = ContinuousClock.now
                    launch = try await hosting.create(request, configuration: configuration) { [weak self] in
                        guard let self else { throw CancellationError() }
                        return try await self.persistentCreateGrid(
                            launchID: launchID, hosting: hosting, claim: claim, startedAt: startedAt
                        )
                    }
                }
            } catch {
                guard let self else { return }
                if self.persistentFailedLaunchID == launchID, self.persistentHosting === hosting {
                    // It failed already (no answer in time); the host's own
                    // reason, arriving late, says more.
                    self.showPersistentLaunchFailure(error, hosting: hosting)
                    return
                }
                guard self.activeLaunchID == launchID else { return }
                if self.persistentHosting === hosting {
                    self.persistentLaunchFailed(error, launchID: launchID)
                } else if self.persistentFallbackHosting === hosting, self.persistentFallbackReason != nil {
                    // It already runs natively (no answer in time); the
                    // host's own reason, arriving late, says more.
                    self.persistentFallbackReason = PersistentLocalSessions.launchFailureReason(error)
                    hosting.noteLaunchFailure(error)
                }
                return
            }
            guard let self, self.activeLaunchID == launchID, self.persistentHosting === hosting else {
                // The tab closed, stopped or started again meanwhile: nothing
                // will ever show a session created for this launch. A later
                // launch of the tab waits until it exited. A tab that closed
                // detaching from its program keeps it: its saved record
                // names it, and brings it back.
                if adopted == nil, !claim.keepsSession {
                    await hosting.end(launch.attachment, waitingForExitUpTo: restartExitTimeout).value
                }
                return
            }
            self.bindPersistentSession(launch, launchID: launchID, hosting: hosting)
        }
    }

    /// What a launch does with the session its Create makes when, by the
    /// time Create answers, its tab no longer follows it (it closed,
    /// stopped or started again). Shared with the launch's task, which
    /// outlives a closed tab.
    @MainActor
    private final class PersistentLaunchClaim {
        /// The tab closed detaching from its program (`stop(keepingSession:)`):
        /// the session is left running for the tab's saved record, instead
        /// of ended.
        var keepsSession = false
        private weak var tab: TerminalSession?
        private let launchID: UUID
        let hosting: PersistentLocalSessions
        /// It sends a Create (else it adopts a session that runs already).
        private let creates: Bool

        init(tab: TerminalSession, launchID: UUID, hosting: PersistentLocalSessions, creates: Bool) {
            self.tab = tab
            self.launchID = launchID
            self.hosting = hosting
            self.creates = creates
        }

        /// The session its Create makes is ended once Create answers: its
        /// tab no longer follows it (the tab closed, stopped, started again
        /// or runs natively after the Create took too long; the launch's
        /// task checks the same) and did not keep it.
        var endsWhatItCreates: Bool {
            guard creates, !keepsSession else { return false }
            guard let tab else { return true }
            return tab.activeLaunchID != launchID || tab.persistentHosting !== hosting
        }
    }

    /// Every tab's launch still ending a previous session or waiting for
    /// its Create, closed tabs' included: a Create that answers after its
    /// tab closed ends the session it made (`startPersistentLaunch`),
    /// unless the tab closed keeping it.
    private static var persistentLaunchesInFlight: [UUID: (task: Task<Void, Never>, claim: PersistentLaunchClaim)] = [:]

    /// Waits until every tab's launch under way that will end what its
    /// Create makes finished (at most `timeout`): quit waits for this, so a
    /// session created for a tab that closed ending its session (a quit
    /// answered End Sessions, a stop) is ended before the app goes, not
    /// left running with no tab and no saved record. A launch whose tab
    /// closed keeping its session (a quit answered Keep Running, or one
    /// that asked nothing) is not waited for: its session runs on, and the
    /// tab's saved record brings it back at the next launch.
    static func waitForPersistentLaunches(upTo timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while let (key, entry) = persistentLaunchesInFlight.first(where: { !$0.value.claim.keepsSession }) {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { return }
            await wait(for: entry.task, upTo: remaining)
            persistentLaunchesInFlight[key] = nil
        }
    }

    /// Whether a launch on `hosting` still waiting for its Create will end
    /// the session it makes (`PersistentLaunchClaim.endsWhatItCreates`): a
    /// tab closed (⌘W) or stopped while its Create was under way. A quit
    /// that keeps sessions waits for it (`CherryAppDelegate.confirmedQuitPlan`)
    /// instead of quitting at once: the host would create that session
    /// after the app exited, with no tab and no saved record to end it, and
    /// the next launch would adopt it as an orphan.
    static func hasLaunchesEndingTheirSessions(on hosting: PersistentLocalSessions) -> Bool {
        persistentLaunchesInFlight.values.contains { $0.claim.hosting === hosting && $0.claim.endsWhatItCreates }
    }

    /// A session the host has not started within `creationTimeout` (the
    /// helper, the daemon or the login environment hangs) is not waited for:
    /// the tab runs its program natively, and a session Create returns later
    /// is ended.
    private func schedulePersistentCreationDeadline(_ launchID: UUID, hosting: PersistentLocalSessions) {
        // Longer while this app's other Creates wait ahead of it.
        let timeout = hosting.creationDeadline
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self,
                  self.activeLaunchID == launchID,
                  self.persistentHosting === hosting,
                  self.persistentPhase == .creating
            else { return }
            self.persistentLaunchFailed(
                HostedSessionError.unavailable(
                    "\(PersistentHostSessions.capitalizedFirst(hosting.profile.hostPhrase)) did not start a session within \(Int(timeout)) seconds."
                ),
                launchID: launchID
            )
        }
    }

    /// The grid, and the pixels of its cells, a persistent tab's Create
    /// starts its program at (`PersistentHostSessions.create`): the grid of
    /// the window that shows the tab once it settled
    /// (`TerminalWindowGridWait`, when its workspace waits), so the program
    /// starts at the size it is shown at instead of being resized a moment
    /// later (a new window's first tab has no grid until its window lays it
    /// out, and a tiling window manager may then move the window), which an
    /// inline program such as Claude Code redraws for. The tab's attach
    /// adapter attaches at that grid too (`HostedAttachmentSizeFile`).
    /// Throws `CancellationError` when the tab stopped, closed or started
    /// again meanwhile: no Create goes out, unless the tab keeps what its
    /// Create makes (`PersistentLaunchClaim.keepsSession`: it closed or
    /// detached keeping its session, which its saved record names), which
    /// then goes out at once.
    private func persistentCreateGrid(
        launchID: UUID,
        hosting: PersistentLocalSessions,
        claim: PersistentLaunchClaim,
        startedAt: ContinuousClock.Instant
    ) async throws -> (grid: TerminalViewportSize, cell: TerminalCellSize?) {
        let grid: TerminalViewportSize
        if let source = windowGridForCreate {
            var observation = source.observe()
            var sawSettling = observation?.settling == true
            var decision = source.wait.decision(for: observation, startedAt: startedAt, now: .now, sawSettling: sawSettling)
            while case .wait(let until) = decision {
                let pause = min(until - ContinuousClock.now, source.wait.pollInterval)
                try await Task.sleep(for: max(pause, .milliseconds(1)))
                guard activeLaunchID == launchID, persistentHosting === hosting else {
                    guard claim.keepsSession else { throw CancellationError() }
                    decision = .giveUp
                    break
                }
                observation = source.observe()
                sawSettling = sawSettling || observation?.settling == true
                decision = source.wait.decision(for: observation, startedAt: startedAt, now: .now, sawSettling: sawSettling)
            }
            // The window's grid as last seen (a tab detached meanwhile is
            // no longer its window's).
            observation = source.observe() ?? observation
            grid = TerminalWindowGridWait.grid(own: mountedTerminalGrid, window: observation?.grid, tab: viewportSize)
            let waited = (ContinuousClock.now - startedAt).components
            let milliseconds = waited.seconds * 1_000 + waited.attoseconds / 1_000_000_000_000_000
            if decision == .giveUp {
                SessionLog.notice(
                    "tab \(id.uuidString) creates its session at \(grid.columns)x\(grid.rows): its window's terminal grid did not settle within \(milliseconds) ms"
                )
            } else {
                SessionLog.debug("tab \(id.uuidString) creates its session at its window's grid \(grid.columns)x\(grid.rows) after \(milliseconds) ms")
            }
        } else {
            // At the size the tab has now: its surface may have reported its
            // grid since the launch began.
            grid = viewportSize
        }
        // With the pixels its window's terminal of that grid reports, which
        // its adapter will.
        return (grid, windowTerminalCell?(grid))
    }

    private static func isExistingDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func bindPersistentSession(
        _ launch: PersistentSessionLaunch,
        launchID: UUID,
        hosting: PersistentLocalSessions
    ) {
        let binding = launch.attachment
        persistentSession = binding
        if startedCurrentProgram {
            // Its Create answered: the program started now, however long
            // the host took (a daemon starting cold).
            programStartedAt = Date()
        }
        if let requestID = PersistentLocalSessions.launchRequestID(of: hosting.sessionInfo(binding.sessionID) ?? launch.info) {
            persistentLaunchRequestID = requestID
        }
        hosting.bind(self, to: binding.sessionID)
        // A bell or notification of its session while it was in the
        // background (`BackgroundSessionsModel.backgroundSessionDidSignal`).
        if hosting.takeUnread(binding) { markUnread() }
        persistentStateDidChange?()
        // Input sent while the session was created, in order, before the
        // adapter attaches. MCP's callers learn whether the host took it;
        // a failure of the keyboard's is logged (the program ended at once,
        // or the host could not be reached).
        let queued = pendingPersistentInput
        pendingPersistentInput.removeAll()
        let tabID = id
        for (data, delivery) in queued {
            let sent = hosting.sendInput(data, to: binding)
            Task { @MainActor in
                switch await sent.result {
                case .success:
                    delivery?.resolve(.success(()))
                case .failure(let error):
                    let reason = Self.inputFailureReason(error)
                    if let delivery {
                        delivery.resolve(.failure(Self.controlInputError(error)))
                    } else {
                        SessionLog.error("input typed into tab \(tabID.uuidString) while its session started did not reach it: \(reason)")
                    }
                }
            }
        }
        // Events may have arrived before the binding: the host's list is
        // current, the Create answer may not be.
        let latest = hosting.sessionInfo(binding.sessionID) ?? launch.info
        // Only This Mac's pid: another Mac's would name some unrelated local
        // process to MCP caller routing and port detection.
        hostedProgramProcessID = latest.isRunning && hosting.profile.isThisMac
            ? latest.pid.map { Int32(bitPattern: $0) }
            : nil
        noteHostSessionSharing(latest)
        // A restored or adopted session's program set its title and
        // directory before this tab followed it.
        applyHostReportedTitleAndDirectory(of: latest, resynchronizing: true)
        // A name the user or the agent gave the tab (before its Create
        // answered, or while Cherry was closed) reaches the host.
        hostSessionName = latest.name
        if titleSource != .system {
            syncHostSessionName(title)
        }
        if persistentAdapterDeferred {
            guard latest.isRunning else {
                // It ended while Cherry was closed: no adapter; the tab shows
                // the host's final screen and its exit, and stays open to
                // show them.
                finishPersistentProgram(
                    status: PersistentLocalSessions.exitStatus(of: latest), launchID: launchID, reportsExit: false
                )
                return
            }
            // Followed through the host (input, screen, title, bells, exit)
            // as while an adapter reconnects, until the adapter launches.
            persistentPhase = .reconnecting
            if case .launching = state {
                state = .live
            }
            bumpRevision()
            if ghosttyBridgeStorage != nil {
                // Shown already.
                launchDeferredAdapterIfNeeded()
            }
            return
        }
        launchPersistentAdapter(binding)
        if !latest.isRunning {
            // It ended already (or a restore found it ended): the adapter
            // shows its final screen, and the tab stays open to show it.
            finishPersistentProgram(
                status: PersistentLocalSessions.exitStatus(of: latest), launchID: launchID, reportsExit: false
            )
        }
    }

    private func launchPersistentAdapter(_ binding: HostedSessionAttachment) {
        persistentAdapterDeferred = false
        prepareHostedAdapterLaunch(for: binding)
        // Attached from now on for the surface's configuration (the EXEC
        // backend); the passthrough waits for the adapter to report itself
        // attached in its status file. Only that report resets the
        // reconnect failures and shows a disconnected tab live again
        // (`adapterLiveStatusDidChange`): the app's own `cherry` always
        // writes it, so an adapter that runs for a while without it (a
        // daemon that hangs) is no sign that reconnecting worked.
        persistentPhase = .attached
        shellProcess = nil
        hostInputWriter.set(nil)
        if case .launching = state {
            state = .live
        }
        bumpRevision()
        if let bridge = ghosttyBridgeStorage {
            bridge.relaunchNativeSurface()
        } else {
            _ = ghosttyBridge
        }
    }

    /// The host could not start the program: this tab runs it natively, as
    /// new tabs do until the host works again (Settings › Sessions says why).
    /// The tab says so (`persistentFallbackReason`: its fallback bar) and
    /// keeps its host, so Restart or the bar's Retry tries it again.
    private func persistentLaunchFailed(_ error: Error, launchID: UUID) {
        guard activeLaunchID == launchID else { return }
        if let hosting = persistentHosting, !hosting.profile.allowsNativeFallback {
            failPersistentLaunchWithoutFallback(error, launchID: launchID, hosting: hosting)
            return
        }
        persistentHosting?.noteLaunchFailure(error)
        SessionLog.error("tab \(id.uuidString) runs natively; its persistent session could not start: \(error.localizedDescription)")
        persistentFallbackHosting = persistentHosting
        persistentFallbackReason = PersistentLocalSessions.launchFailureReason(error)
        persistentHosting = nil
        persistentPhase = .idle
        persistentSession = nil
        persistentLaunchRequestID = nil
        let queued = pendingPersistentInput
        pendingPersistentInput.removeAll()
        launchNativeSurface()
        persistentStateDidChange?()
        for (data, delivery) in queued {
            guard let bridge = ghosttyBridgeStorage else {
                delivery?.resolve(.failure(ControlInputError.notDelivered("the tab has no terminal to type into")))
                continue
            }
            bridge.sendNativeInput(data)
            delivery?.resolve(.success(()))
        }
    }

    /// Another Mac's host could not start the program: nothing runs on This
    /// Mac instead (docs/specs/remote-devices.md). The tab ends failed,
    /// saying why ("Couldn't start on <Mac>: <reason>",
    /// `persistentLaunchFailureReason`), and keeps its host, so Restart and
    /// Retry (`retryPersistentSession`) try it again. Input queued for the
    /// program is reported undelivered. A session a Create makes after this
    /// is ended (the launch no longer runs).
    private func failPersistentLaunchWithoutFallback(_ error: Error, launchID: UUID, hosting: PersistentLocalSessions) {
        SessionLog.error("tab \(id.uuidString) could not start on \(hosting.profile.displayName): \(error.localizedDescription)")
        activeLaunchID = nil
        persistentFailedLaunchID = launchID
        persistentPhase = .idle
        persistentSession = nil
        persistentLaunchRequestID = nil
        processor.endLaunch(launchID)
        showPersistentLaunchFailure(error, hosting: hosting)
        let queued = pendingPersistentInput
        pendingPersistentInput.removeAll()
        let reason = persistentLaunchFailureReason ?? error.localizedDescription
        for (_, delivery) in queued {
            delivery?.resolve(.failure(ControlInputError.notDelivered(reason)))
        }
        persistentStateDidChange?()
    }

    private func showPersistentLaunchFailure(_ error: Error, hosting: PersistentLocalSessions) {
        hosting.noteLaunchFailure(error)
        let reason = "Couldn't start on \(hosting.profile.displayName): \(PersistentHostSessions.launchFailureReason(error))"
        persistentLaunchFailureReason = reason
        state = .failed(reason)
        bumpRevision()
    }

    /// The fallback bar's Retry: starts the tab's program again as a
    /// persistent session (ending the one that runs natively), even while
    /// the host takes no new tabs (`canHostNewTabs`). For a tab of another
    /// Mac's host that failed to start (`persistentLaunchFailureReason`),
    /// tries that host again.
    @discardableResult
    func retryPersistentSession() -> Bool {
        if persistentHosting?.profile.allowsNativeFallback == false {
            guard persistentLaunchFailureReason != nil, !isRunning else { return false }
            return restart()
        }
        guard persistentHosting == nil, persistentFallbackHosting != nil else { return false }
        persistentRetryRequested = true
        defer { persistentRetryRequested = false }
        return restart()
    }

    /// A tab running natively after its persistent session could not start
    /// runs in the host again at its next launch: when asked to
    /// (`retryPersistentSession`), or when the host takes new tabs.
    private func resumePersistentHostingAfterFallback() {
        guard persistentHosting == nil,
              let hosting = persistentFallbackHosting,
              launchBackend == .nativePTY,
              hostedAttachment == nil,
              persistentRetryRequested || hosting.canHostNewTabs()
        else { return }
        persistentFallbackHosting = nil
        persistentFallbackReason = nil
        persistentHosting = hosting
        persistentStateDidChange?()
    }

    /// The adapter ended. Its outcome says whether the program did; if not,
    /// the adapter is launched again (backoff), and after repeated failures
    /// the tab shows it is disconnected while it keeps trying.
    private func persistentAdapterDidExit(launchID: UUID) {
        guard case .attached = persistentPhase,
              let persistentHosting,
              let binding = persistentSession
        else { return }
        // An adapter that attached did its job: its end (it gave up
        // reconnecting, say) is a first failure. One that never reported
        // itself attached failed, however long it ran.
        let attached = adapterLiveStatus != nil
        let outcome = consumeHostedLaunchStatus(removingAfter: 0) ?? .disconnected(nil)
        persistentPhase = .reconnecting
        if isProvisionalRestore {
            // Its session may be gone or ended: the restore decides, and
            // launches it again once it confirms the session runs. It shows
            // it reconnects meanwhile.
            provisionalAdapterEnded = true
            bumpRevision()
            return
        }
        if case .exited(let code, let signal) = outcome {
            // An exit without a status is never taken for a clean one.
            finishPersistentProgram(status: code ?? signal.map { 128 + $0 } ?? 1, launchID: launchID)
            return
        }
        // The host's title and directory are the current ones until an
        // adapter passes them through again.
        if let info = persistentHosting.sessionInfo(binding.sessionID), info.isRunning {
            applyHostReportedTitleAndDirectory(of: info, resynchronizing: true)
        }
        if attached {
            persistentReconnectFailures = 0
        }
        persistentReconnectFailures += 1
        if persistentReconnectFailures > persistentHosting.configuration.reconnectAttemptsBeforeDisconnected,
           case .live = state {
            state = .disconnected
            bumpRevision()
        }
        schedulePersistentReconnect(launchID: launchID, binding: binding, hosting: persistentHosting, immediately: false)
    }

    private func schedulePersistentReconnect(
        launchID: UUID,
        binding: HostedSessionAttachment,
        hosting: PersistentLocalSessions,
        immediately: Bool
    ) {
        persistentReconnect?.cancel()
        let delays = hosting.configuration.reconnectDelay
        let delay = immediately
            ? 0
            : min(delays.initial * pow(2, Double(max(0, persistentReconnectFailures - 1))), delays.maximum)
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.activeLaunchID == launchID,
                  self.persistentPhase == .reconnecting,
                  self.persistentSession == binding
            else { return }
            self.persistentReconnect = nil
            // A device's adapter is launched again only while its Mac
            // answers: an ssh per attempt to a Mac that is offline only
            // fails (and a login refused on a timer can get the address
            // blocked). The tab waits for the control connection, which its
            // lease keeps trying (backoff, wake and network changes).
            if !hosting.profile.isThisMac, hosting.control.state != .connected {
                self.waitForRemoteHost(launchID: launchID, binding: binding, hosting: hosting)
                return
            }
            switch hosting.programState(of: binding) {
            case .exited(let status):
                self.finishPersistentProgram(status: status, launchID: launchID)
            case .gone:
                // Seen twice in a row: a daemon that just restarted lists
                // every session whose holder came back, so it is gone.
                self.persistentReconnectMisses += 1
                if self.persistentReconnectMisses >= 2 {
                    self.finishPersistentProgram(status: 1, launchID: launchID)
                } else {
                    self.launchPersistentAdapter(binding)
                }
            case .running, .unknown:
                self.persistentReconnectMisses = 0
                self.launchPersistentAdapter(binding)
            }
        }
        persistentReconnect = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelPersistentReconnect() {
        persistentReconnect?.cancel()
        persistentReconnect = nil
        remoteHostWait = nil
    }

    /// Launches the adapter again once the device's control connection is
    /// up (`schedulePersistentReconnect`).
    private func waitForRemoteHost(launchID: UUID, binding: HostedSessionAttachment, hosting: PersistentLocalSessions) {
        if case .live = state {
            state = .disconnected
            bumpRevision()
        }
        let control = hosting.control
        if case .failed = control.state {
            // Nothing leases it into trying again by itself: ask once.
            Task { _ = try? await control.connect() }
        }
        remoteHostWait = control.$state
            .dropFirst()
            .filter { $0 == .connected }
            .first()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.remoteHostWait = nil
                    guard self.activeLaunchID == launchID, self.persistentSession == binding else { return }
                    // A few at a time: every tab of the device waited.
                    hosting.enqueueAdapterRelaunch { [weak self] in
                        guard let self, self.activeLaunchID == launchID, self.persistentSession == binding,
                              self.persistentPhase == .reconnecting
                        else { return }
                        self.persistentReconnectFailures = 0
                        self.schedulePersistentReconnect(launchID: launchID, binding: binding, hosting: hosting, immediately: true)
                    }
                }
            }
    }

    /// Keys typed into a device's tab while its Mac cannot be reached are
    /// not sent (nothing would take them, and sending them later would type
    /// them into whatever runs then): the Mac beeps and the tab's offline
    /// bar says so.
    private func noteInputNotSentWhileOffline() {
        // Only for someone typing into the app (not a test run in the
        // background).
        if NSApp?.isActive == true { NSSound.beep() }
        offlineInputRejectedAt = Date()
    }

    /// Whether this is a device's tab whose Mac cannot be reached now.
    var isRemoteHostUnreachable: Bool {
        guard let persistentHosting, !persistentHosting.profile.isThisMac else { return false }
        return persistentHosting.control.state != .connected
    }

    /// Asks the tab's attach adapter, which reconnects by itself, to try
    /// again now (SIGUSR1: `cherry attach` starts its next attempt at once
    /// and resets its backoff). The adapter process is the one its status
    /// file names (`HostedAdapterProcess`: pid and start time, checked
    /// first), never the login(1) wrapper the surface runs it under, which
    /// does not pass the signal on. False when the adapter does not report
    /// reconnecting, names no process, or the signal could not be sent: the
    /// caller then launches a new adapter. Tests replace it.
    var pokeReconnectingAdapter: @MainActor (TerminalSession) -> Bool = { session in
        guard let status = session.adapterLiveStatus, status.reconnecting, let process = status.process else { return false }
        return process.requestReconnect()
    }

    /// Reconnect Now, Start on a command whose adapter reconnects, MCP
    /// `start_process`, or taking the session over from its other clients:
    /// launch the adapter now. An adapter that reconnects by itself (its
    /// status says so) is kept, with its surface and screen, and asked to
    /// try again at once (`pokeReconnectingAdapter`); only a takeover
    /// replaces it. Any other adapter that runs is replaced only when the
    /// tab still shows it is disconnected (it has not reported itself
    /// attached since) or for a takeover.
    private func reconnectPersistentAdapterNow(takeover: Bool) -> Bool {
        guard let persistentHosting,
              let launchID = activeLaunchID,
              let binding = persistentSession
        else { return false }
        switch persistentPhase {
        case .reconnecting:
            hostedTakeoverForNextLaunch = takeover
            persistentReconnectFailures = 0
            schedulePersistentReconnect(launchID: launchID, binding: binding, hosting: persistentHosting, immediately: true)
            return true
        case .attached:
            guard takeover || state == .disconnected else { return false }
            if !takeover, adapterLiveStatus?.reconnecting == true, pokeReconnectingAdapter(self) {
                persistentReconnectFailures = 0
                return true
            }
            cancelPersistentReconnect()
            hostedTakeoverForNextLaunch = takeover
            persistentReconnectFailures = 0
            launchPersistentAdapter(binding)
            return true
        case .idle, .creating:
            return false
        }
    }

    /// The program ended: the same exit handling a native tab gets (agent
    /// idle/error, command auto-restart, attention). The adapter prints the
    /// final screen and exits by itself. `reportsExit`: see `finishProcessExit`.
    private func finishPersistentProgram(
        status: Int32,
        launchID: UUID,
        reportsExit: Bool = true,
        end: HostSessionEnd? = nil
    ) {
        guard activeLaunchID == launchID else { return }
        // The host's own report of how it ended (its holder died), else
        // what the list says of the session.
        let end = end ?? persistentSession.flatMap { persistentHosting?.sessionInfo($0.sessionID)?.end }
        if let end, end.isHolderLost, hostSessionEnd != end {
            hostSessionEnd = end
            SessionLog.notice("tab \(id.uuidString): \(end.message)")
        }
        // A restored tab whose adapter never ran: no surface showed the
        // program, so its final screen comes from the host.
        let showsHostFinalScreen = persistentAdapterDeferred
        persistentAdapterDeferred = false
        cancelPersistentReconnect()
        persistentPhase = .idle
        _ = consumeHostedLaunchStatus(removingAfter: 2)
        if let persistentHosting, let persistentSession {
            // Nothing more to follow; the tab still names the session, whose
            // final screen the host keeps until the tab closes or restarts.
            persistentHosting.unbind(self, from: persistentSession.sessionID)
        }
        finishProcessExit(
            status: status, launchID: launchID, appendsExitNotice: !showsHostFinalScreen, reportsExit: reportsExit
        )
        if showsHostFinalScreen, let persistentHosting, let binding = persistentSession {
            showFinalScreen(of: binding) { try await persistentHosting.screen(of: binding) }
        }
    }

    /// The host reported the program exited (`PersistentLocalSessions`).
    /// `end`: the host ended it (its holder died, `HostSessionEnd`).
    func persistentProgramDidExit(sessionID: String, status: Int32, end: HostSessionEnd? = nil) {
        guard persistentSession?.sessionID == sessionID,
              let launchID = activeLaunchID,
              persistentPhase != .creating
        else { return }
        if isProvisionalRestore {
            // Maybe it ended while Cherry was closed: the restore decides.
            provisionalExit = (status, end)
            return
        }
        finishPersistentProgram(status: status, launchID: launchID, end: end)
    }

    /// The restore that showed this tab before its host answered found the
    /// session in the host's list (`OptimisticRestore`): the tab takes what
    /// the host reports of it, as a tab the restore built would have. One
    /// that ended while Cherry was closed shows its exit and reports
    /// nothing; one that ended since, or whose adapter ended meanwhile, is
    /// handled as any.
    func confirmProvisionalRestore(_ info: HostedSessionInfo) {
        guard isProvisionalRestore else { return }
        let heldExit = provisionalExit
        let adapterEnded = provisionalAdapterEnded
        clearProvisionalRestore()
        guard let hosting = persistentHosting,
              let binding = persistentSession,
              binding.sessionID == info.id,
              let launchID = activeLaunchID,
              persistentPhase != .creating
        else { return }
        if let requestID = PersistentLocalSessions.launchRequestID(of: info), requestID != persistentLaunchRequestID {
            persistentLaunchRequestID = requestID
            persistentStateDidChange?()
        }
        guard info.isRunning else {
            finishPersistentProgram(
                status: PersistentLocalSessions.exitStatus(of: info), launchID: launchID, reportsExit: false, end: info.end
            )
            return
        }
        if let heldExit {
            finishPersistentProgram(status: heldExit.status, launchID: launchID, end: heldExit.end)
            return
        }
        hostedProgramProcessID = hosting.profile.isThisMac ? info.pid.map { Int32(bitPattern: $0) } : nil
        noteHostSessionSharing(info)
        applyHostReportedTitleAndDirectory(of: info, resynchronizing: true)
        hostSessionName = info.name
        if titleSource != .system {
            syncHostSessionName(title)
        }
        bumpRevision()
        if adapterEnded, persistentPhase == .reconnecting, !persistentAdapterDeferred {
            schedulePersistentReconnect(launchID: launchID, binding: binding, hosting: hosting, immediately: true)
        }
    }

    private func clearProvisionalRestore() {
        isProvisionalRestore = false
        provisionalExit = nil
        provisionalAdapterEnded = false
    }

    /// The host changed what it reports about the running program: its pid,
    /// and its title and directory, which the tab takes from here while its
    /// adapter does not pass them to its surface.
    func persistentSessionDidChange(_ info: HostedSessionInfo) {
        guard persistentSession?.sessionID == info.id, isRunning, persistentPhase != .creating else { return }
        noteHostSessionSharing(info)
        // Another Mac's pid names no process here.
        let pid = persistentHosting?.profile.isThisMac == false ? nil : info.pid.map { Int32(bitPattern: $0) }
        if hostedProgramProcessID != pid {
            hostedProgramProcessID = pid
        }
        // What the host reports up to the adapter's attach still applies:
        // the snapshot the adapter gets carries no title or directory.
        applyHostReportedTitleAndDirectory(of: info, resynchronizing: false)
    }

    private func noteHostSessionSharing(_ info: HostedSessionInfo) {
        let sharing = info.isRunning ? HostSessionSharing(clients: info.clients, columns: info.cols, rows: info.rows) : nil
        if hostSessionSharing != sharing { hostSessionSharing = sharing }
    }

    /// The slim bar that says the tab's session is shared: shown at the
    /// size another, smaller client gives it, or also open in other
    /// clients; nil when it is this tab's alone (`SharedSessionBarState`).
    var sharedSessionBar: SharedSessionBarState? {
        guard isPersistentLocalSession || hostedAttachment != nil else { return nil }
        return SharedSessionBarState(
            sharing: hostSessionSharing,
            viewport: adapterLiveStatus?.viewport == true,
            isRunning: isRunning
        )
    }

    /// Takes the tab's session over from its other clients (the shared bar's
    /// Take Over): its screen then follows this tab's size.
    @discardableResult
    func takeOverSharedSession() -> Bool {
        reconnectHostedSession(takeover: true)
    }

    /// The directory `info` reports on its own machine: This Mac's for a
    /// tab of This Mac's host, the device's for another Mac's
    /// (`PersistentHostSessions.reportedWorkingDirectory(of:)`).
    private func hostReportedWorkingDirectory(of info: HostedSessionInfo) -> String? {
        if let persistentHosting, !persistentHosting.profile.isThisMac {
            return persistentHosting.reportedWorkingDirectory(of: info)
        }
        return info.localWorkingDirectory
    }

    /// Takes the title and directory the host reports for the program when
    /// they changed since its last report, unless the attach adapter passes
    /// them to the surface (which reports them itself, in order with the
    /// program's output). `resynchronizing`: the tab starts following a
    /// session whose program set them earlier, or its adapter just ended
    /// (the host's are the current ones from now on), so they are taken
    /// whatever was reported before. A directory on another machine (the
    /// program ran ssh) is ignored, as Ghostty ignores such an OSC 7.
    private func applyHostReportedTitleAndDirectory(of info: HostedSessionInfo, resynchronizing: Bool) {
        let passesThrough = !resynchronizing && adapterPassesSignalsThrough
        // A device's tab takes its directory from the host even while the
        // adapter passes signals through: the surface ignores an OSC 7 of
        // another machine (`ingestNativeWorkingDirectory`).
        let directoryPassesThrough = passesThrough && reportsLocalWorkingDirectory
        var didChange = false
        if resynchronizing || info.pwd != lastHostReportedDirectory {
            lastHostReportedDirectory = info.pwd
            if !directoryPassesThrough, let path = hostReportedWorkingDirectory(of: info) {
                if workingDirectory != path {
                    workingDirectory = path
                    didChange = true
                }
                if restoreShellTitle(from: path) {
                    didChange = true
                }
            }
        }
        if resynchronizing || info.title != lastHostReportedTitle {
            lastHostReportedTitle = info.title
            if !passesThrough, let title = info.title?.nilIfEmpty {
                if kind == .agent {
                    // A title reported earlier is no sign of what the agent
                    // does now.
                    didChange = (resynchronizing ? applyAutomaticAgentTitle(from: title) : recordAgentTitleActivity(title)) || didChange
                } else if systemTitle != title {
                    updateSystemTitle(title)
                    didChange = true
                }
            }
        }
        if didChange { bumpRevision() }
    }

    /// The attach adapter reports that it is attached and follows the
    /// program (`adapterLiveStatus`): it passes the program's bells,
    /// notifications, title and directory through to the surface (Ghostty
    /// reports them), and takes the program's input.
    private var adapterPassesSignalsThrough: Bool {
        guard case .attached = persistentPhase else { return false }
        return adapterLiveStatus?.followsProgram ?? false
    }

    /// A bell, notification or progress report the host passed on for the
    /// program. Bells and notifications take the same path as the surface's
    /// (unread dot, desktop notification, agent attention), unless the
    /// attach adapter passes them to the surface; each shows once either
    /// way. Progress only comes from here.
    func persistentHostDidSignal(_ signal: PersistentHostSignal) {
        guard isPersistentLocalSession, persistentSession != nil else { return }
        switch signal {
        case .progress(let state, let value):
            let report: TerminalProgressReport? = state == .remove ? nil : TerminalProgressReport(state: state, value: value)
            if progressReport != report {
                progressReport = report
                bumpRevision()
            }
        case .bell:
            guard hostSignalMissedTheAdapter(key: "bell"),
                  noteSignalDelivery(key: "bell", fromHost: true, window: Self.bellDeduplicationWindow)
            else { return }
            bellHandler(self)
        case .notification(let title, let body):
            let key = Self.notificationKey(title: title, body: body)
            guard hostSignalMissedTheAdapter(key: key),
                  noteSignalDelivery(key: key, fromHost: true, window: Self.notificationDeduplicationWindow)
            else { return }
            handleIncomingNotification(TerminalNotificationRequest(title: title.nilIfEmpty, body: body, source: .osc777))
            bumpRevision()
        }
    }

    /// Whether a bell or notification the host reports did not reach the
    /// surface: always while the attach adapter does not pass them through.
    /// While it does, the surface showed it, unless the host kept it while
    /// no app was subscribed (its daemon was down: the holder, then the new
    /// daemon, kept it) and hands it to a control connection that came up
    /// after the adapter started following the program, which it may
    /// predate: a snapshot replays no bells or notifications. Then it
    /// counts as missed unless the surface showed the same one since.
    private func hostSignalMissedTheAdapter(key: String) -> Bool {
        guard adapterPassesSignalsThrough else { return true }
        guard let persistentHosting, let since = adapterFollowingSince,
              Date().timeIntervalSince(since) <= persistentHosting.configuration.pendingSignalLifetime,
              persistentHosting.connectionGeneration != adapterFollowingControlGeneration
        else { return false }
        if let index = surfaceSignalsWhileFollowing.firstIndex(where: { $0.key == key }) {
            // The surface's copy of this one.
            surfaceSignalsWhileFollowing.remove(at: index)
            return false
        }
        return true
    }

    /// A bell or notification the surface showed while its adapter passes
    /// them through: the host may report it later (see above).
    private func noteSurfaceSignalWhileFollowing(key: String) {
        guard isPersistentLocalSession, adapterPassesSignalsThrough, let persistentHosting else { return }
        let oldest = Date().addingTimeInterval(-persistentHosting.configuration.pendingSignalLifetime)
        surfaceSignalsWhileFollowing.removeAll { $0.at < oldest }
        surfaceSignalsWhileFollowing.append((key, Date()))
        if surfaceSignalsWhileFollowing.count > persistentHosting.configuration.pendingSignalLimit {
            surfaceSignalsWhileFollowing.removeFirst(
                surfaceSignalsWhileFollowing.count - persistentHosting.configuration.pendingSignalLimit
            )
        }
    }

    /// Records a bell or notification about to be shown; false when the
    /// other source (surface or host) showed the same one within `window`.
    /// Only a persistent tab gets both.
    private func noteSignalDelivery(key: String, fromHost: Bool, window: TimeInterval) -> Bool {
        guard isPersistentLocalSession else { return true }
        let now = Date()
        recentSignalDeliveries.removeAll { now.timeIntervalSince($0.at) > Self.notificationDeduplicationWindow }
        if let index = recentSignalDeliveries.firstIndex(where: {
            $0.key == key && $0.fromHost != fromHost && now.timeIntervalSince($0.at) <= window
        }) {
            // That copy is accounted for.
            recentSignalDeliveries.remove(at: index)
            return false
        }
        recentSignalDeliveries.append((key, fromHost, now))
        return true
    }

    private static func notificationKey(title: String?, body: String) -> String {
        "notification\u{0}\(title ?? "")\u{0}\(body)"
    }

    /// The host's list no longer has the running program's session, but
    /// that may be a list taken before its holder registered again with a
    /// restarted daemon: the tab takes it as gone only when a later list
    /// agrees (`PersistentLocalSessions.confirmedProgramState`). Until then
    /// nothing changes: no exit, no auto-restart.
    func persistentSessionMayHaveDisappeared(sessionID: String) {
        // The restore that showed it decides.
        guard !isProvisionalRestore else { return }
        guard persistentSession?.sessionID == sessionID,
              let binding = persistentSession,
              let hosting = persistentHosting,
              persistentPhase != .creating,
              persistentDisappearanceCheck == nil
        else { return }
        persistentDisappearanceCheck = Task { @MainActor [weak self] in
            let state = await hosting.confirmedProgramState(of: binding)
            guard let self, !Task.isCancelled else { return }
            self.persistentDisappearanceCheck = nil
            guard self.persistentSession == binding else { return }
            switch state {
            case .gone:
                self.persistentSessionDidDisappear(sessionID: sessionID)
            case .exited(let status):
                if let launchID = self.activeLaunchID {
                    self.finishPersistentProgram(status: status, launchID: launchID)
                }
            case .running(let info):
                self.persistentSessionDidChange(info)
            case .unknown:
                // The host cannot be listed now; the adapter's reconnects
                // decide (a session missing twice in a row is gone).
                break
            }
        }
    }

    /// The host no longer has the session. A running program is gone with it
    /// (a session is removed only after it exited).
    func persistentSessionDidDisappear(sessionID: String) {
        guard persistentSession?.sessionID == sessionID, persistentPhase != .creating else { return }
        persistentHosting?.unbind(sessionID: sessionID)
        if let launchID = activeLaunchID {
            finishPersistentProgram(status: exitCode ?? 1, launchID: launchID)
        }
        persistentSession = nil
        persistentLaunchRequestID = nil
        persistentStateDidChange?()
    }

    /// Input for a persistent tab whose adapter is not attached: queued
    /// while its session is created, then sent through the host's control
    /// connection. False when the surface takes it.
    private func routePersistentInput(_ data: Data) -> Bool {
        guard let persistentHosting, isRunning, !data.isEmpty else { return false }
        switch persistentPhase {
        case .creating:
            queueKeyboardInputUntilCreated(data)
            return true
        case .reconnecting:
            guard let binding = persistentSession else { return false }
            sendKeyboardInputThroughHost(data, to: binding, hosting: persistentHosting)
            return true
        case .attached:
            // An adapter that reconnects by itself does not reach the
            // program meanwhile; the host does.
            guard adapterLiveStatus?.reconnecting == true, let binding = persistentSession else { return false }
            sendKeyboardInputThroughHost(data, to: binding, hosting: persistentHosting)
            return true
        case .idle:
            return false
        }
    }

    /// Typed keys for the program through its host. A device's keys fail
    /// visibly when its Mac cannot be reached (`noteInputNotSentWhileOffline`),
    /// now or when the host did not take them.
    private func sendKeyboardInputThroughHost(_ data: Data, to binding: HostedSessionAttachment, hosting: PersistentLocalSessions) {
        guard !hosting.profile.isThisMac else {
            hosting.sendInput(data, to: binding)
            return
        }
        guard hosting.control.state == .connected else {
            noteInputNotSentWhileOffline()
            return
        }
        // Over the connection that is up only, briefly: keys must never
        // reach the program long after they were typed.
        let task = hosting.sendKeys(data, to: binding)
        Task { @MainActor [weak self] in
            if case .failure = await task.result { self?.noteInputNotSentWhileOffline() }
        }
    }

    /// The most keyboard input a tab queues while its session is created
    /// or restarted (typed or pasted; MCP's has its own bound): more is
    /// dropped, and the program gets what came first.
    static let maxQueuedKeyboardInputBytes = 64 * 1_024

    /// Keys typed (or pasted) while the session is created: queued, in
    /// order with MCP's input, for the program once the session exists.
    private func queueKeyboardInputUntilCreated(_ data: Data) {
        let queued = pendingPersistentInput.reduce(0) { $0 + ($1.delivery == nil ? $1.data.count : 0) }
        guard queued + data.count <= Self.maxQueuedKeyboardInputBytes else {
            if queued < Self.maxQueuedKeyboardInputBytes {
                SessionLog.error("tab \(id.uuidString) queues no more than \(Self.maxQueuedKeyboardInputBytes) bytes of input while its session starts; the rest was dropped.")
            }
            return
        }
        pendingPersistentInput.append((data, nil))
    }

    /// Input the tab's in-memory surface encoded (Ghostty's keyboard
    /// encoding) while no process takes it: a persistent tab shows one
    /// while its session is created or restarted. The keys go to its
    /// program (queued until the session exists); any other tab without a
    /// process drops them, as before.
    private func surfaceInputWithoutProcess(_ data: Data) {
        guard isPersistentLocalSession, isRunning, !data.isEmpty else { return }
        _ = routePersistentInput(data)
    }

    private func resetAutomaticTitleForNewAgentLaunch() {
        guard kind == .agent else { return }
        automaticTitle = nil
        if titleSource == .automatic {
            title = systemTitle
            titleSource = .system
        }
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

    /// `appendsExitNotice`: a terminal's exit line follows the output; false
    /// when the final screen is still to come (read from the host), which
    /// then adds it. `reportsExit`: tell the workspace (`programDidExit`),
    /// which may close the tab; false for a program that had ended before
    /// the tab followed it (a restored or adopted session that ended), whose
    /// tab was opened to show that exit.
    private func finishProcessExit(
        status: Int32,
        launchID: UUID,
        appendsExitNotice: Bool = true,
        reportsExit: Bool = true
    ) {
        guard activeLaunchID == launchID else { return }

        activeLaunchID = nil
        hostInputWriter.set(nil)
        shellProcess = nil
        childProcessID = nil
        hostedProgramProcessID = nil
        progressReport = nil
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
        if hostedAttachment != nil {
            // The adapter's own exit status does not say whether the hosted
            // program ended; its status file does.
            applyHostedStatus(consumeHostedLaunchStatus(removingAfter: 0) ?? .disconnected(nil))
            // It gave up on its host, which may answer later: wait for it.
            if hostedLaunchRetryable {
                hostReconnects?.wait(self)
            }
            return
        }
        state = .exited(status)
        if kind == .agent || kind == .command {
            let hideCursor = Data("\u{1B}[?25l".utf8)
            renderedReplayCache = nil
            rawOutputStore.append(hideCursor)
            processor.ingestTestingData(hideCursor)
            if kind == .command, restartOnExit {
                if let hostSessionEnd {
                    // Not the command's own failure: restarting it would
                    // hide the crash. Its bar says so, with Restart.
                    SessionLog.notice("command tab \(id.uuidString) is not restarted: \(hostSessionEnd.message)")
                } else {
                    scheduleAutoRestartAfterExit()
                }
            }
        } else if appendsExitNotice {
            processor.appendPlainLines([
                "",
                hostSessionEnd.map { "[\($0.message)]" } ?? "[shell exited with status \(status)]"
            ])
        }
        scheduleAttentionObservation(event: .processExited)
        bumpRevision()
        if isPersistentLocalSession {
            // Saved with its exit (`savedExitStatus`): a relaunch that finds
            // the session gone knows it had ended.
            persistentStateDidChange?()
        }
        if reportsExit {
            programDidExit?(self)
        }
    }

    // MARK: Restored tabs (deferred attach)

    /// "Session ended (exit N)" for a persistent terminal or agent whose
    /// program ended while its session (and final screen) is still on the
    /// host; nil otherwise. Closing the tab removes that session. A terminal
    /// whose shell exited with status 0 closes instead, unless Settings ›
    /// Sessions keeps such tabs (`TerminalWorkspace.tabProgramDidExit`).
    ///
    /// For a tab whose session the system ended while Cherry was closed
    /// (`systemSessionEnd`), of any kind, what ended it: "Ended when the
    /// Mac restarted".
    var persistentSessionEndedMessage: String? {
        if let systemSessionEnd, !isRunning {
            return systemEndExitStatus.map { HostedAttachmentStatus.exited(code: $0, signal: nil).summary }
                ?? systemSessionEnd.message(machine: remoteMachineName)
        }
        guard isPersistentLocalSession, kind != .command, !isRunning, persistentSession != nil,
              case .exited(let status) = state
        else { return nil }
        if let hostSessionEnd { return hostSessionEnd.message }
        return HostedAttachmentStatus.exited(code: status, signal: nil).summary
    }

    /// Shows that the system ended this tab's session while Cherry was
    /// closed: a tab built for a saved record that is not launched
    /// (`TerminalWorkspace.makeSystemEndedSession`). A command that
    /// restarts when it exits restarts by its policy, as a restored command
    /// whose session ended does.
    ///
    /// `exitStatus`: its program had exited before (the saved record's): the
    /// tab shows that exit, and does not restart by itself (a command whose
    /// auto-restart gave up stays stopped).
    func showSystemSessionEnd(_ end: SystemSessionEnd, exitStatus: Int32? = nil) {
        guard !isRunning else { return }
        systemSessionEnd = end
        systemEndExitStatus = exitStatus
        if let exitStatus {
            state = .exited(exitStatus)
            exitCode = exitStatus
        } else if kind == .command, restartOnExit {
            scheduleAutoRestartAfterExit()
        }
        bumpRevision()
    }

    /// How this tab's program ended, as its saved record keeps it
    /// (`WorkspaceSessionRecord.exitStatus`): the exit of this app's own
    /// persistent tab whose session its host reported exited, or of a tab
    /// the system ended that had exited before. Nil while it runs, and for
    /// any other tab.
    var savedExitStatus: Int32? {
        guard !isRunning else { return nil }
        if systemSessionEnd != nil { return systemEndExitStatus }
        guard isPersistentLocalSession, persistentSession != nil, case .exited(let status) = state else { return nil }
        return status
    }

    /// Whether this restored tab's attach adapter is still to be launched
    /// (`launchDeferredAdapterIfNeeded`).
    var isAwaitingDeferredLaunch: Bool {
        hostedLaunchDeferred || (persistentAdapterDeferred && isRunning && persistentPhase == .reconnecting)
    }

    /// Launches the attach adapter a restore deferred: an attached tab
    /// attaches, a persistent tab whose program runs attaches its adapter.
    /// True when something was launched; false when nothing was deferred
    /// (or the program ended, or the tab stopped, meanwhile).
    @discardableResult
    func launchDeferredAdapterIfNeeded() -> Bool {
        if hostedLaunchDeferred {
            hostedLaunchDeferred = false
            stopFollowingDeferredHostEvents()
            startShell()
            return true
        }
        guard persistentAdapterDeferred else { return false }
        guard isRunning, persistentPhase == .reconnecting, let binding = persistentSession else {
            persistentAdapterDeferred = false
            return false
        }
        cancelPersistentReconnect()
        launchPersistentAdapter(binding)
        return true
    }

    /// While its launch is deferred, an attached tab follows its session's
    /// events from `control` (its host's control connection, kept up
    /// meanwhile): the program's title, bells, notifications and exit. Its
    /// adapter passes them through once it runs.
    func followDeferredHostEvents(from control: HostControl) {
        guard hostedLaunchDeferred, let hostedAttachment else { return }
        stopFollowingDeferredHostEvents()
        let sessionID = hostedAttachment.sessionID
        deferredHostLease = control.retain()
        deferredHostControl = control
        // HostControl publishes on the main actor.
        deferredHostEvents = control.events.sink { [weak self, weak control] event in
            MainActor.assumeIsolated {
                guard let self, event.sessionID == sessionID else { return }
                self.handleDeferredHostEvent(event, control: control)
            }
        }
    }

    private func stopFollowingDeferredHostEvents() {
        deferredHostEvents?.cancel()
        deferredHostEvents = nil
        deferredHostControl = nil
        deferredHostLease?.release()
        deferredHostLease = nil
    }

    private func handleDeferredHostEvent(_ event: HostSessionEvent, control: HostControl?) {
        guard hostedLaunchDeferred else { return }
        switch event {
        case .exited(_, let exitCode, let signal, _):
            showEndedHostedSession(exitCode: Int32(clamping: exitCode), signal: signal, control: control)
        case .added(let info), .changed(let info):
            guard info.isRunning else {
                showEndedHostedSession(
                    exitCode: info.exitCode.map { Int32(clamping: $0) },
                    signal: info.exitSignal,
                    control: control
                )
                return
            }
            noteAttachedLocalSession(info)
            if let title = info.title?.nilIfEmpty {
                ingestNativeTitle(title)
            }
        case .removed:
            // Removed, or missing from a list taken before a restarted
            // daemon heard from its holder again: the adapter finds out.
            launchDeferredAdapterIfNeeded()
        case .bell:
            bellHandler(self)
        case .notification(_, let title, let body):
            handleIncomingNotification(TerminalNotificationRequest(title: title.nilIfEmpty, body: body, source: .osc777))
            bumpRevision()
        case .progress, .resync:
            break
        }
    }

    /// An attached tab whose session ended before its adapter attached (a
    /// restore found it ended, or it ended while the tab waited): no
    /// adapter; the tab shows "Session ended" with the host's final screen,
    /// read through `control` when given.
    func showEndedHostedSession(exitCode: Int32?, signal: Int32?, control: HostControl?) {
        guard let hostedAttachment, !isRunning else { return }
        hostedLaunchDeferred = false
        stopFollowingDeferredHostEvents()
        hostedProgramProcessID = nil
        attachedLocalProgramProcessID = nil
        applyHostedStatus(.exited(code: exitCode, signal: signal))
        guard let control else { return }
        showFinalScreen(of: hostedAttachment) {
            try await control.screen(
                hostedAttachment.sessionID, scrollback: true, expectedHostID: hostedAttachment.hostID
            )
        }
    }

    /// Reads an ended program's final screen (with its history) from its
    /// host into the tab's lines, which the in-memory surface and MCP show
    /// while no adapter does. Dropped if the tab starts again first.
    private func showFinalScreen(
        of binding: HostedSessionAttachment,
        read: @escaping @MainActor () async throws -> HostScreenText
    ) {
        finalScreenRead?.cancel()
        finalScreenRead = Task { @MainActor [weak self] in
            let screen = try? await read()
            guard let self, !Task.isCancelled else { return }
            self.finalScreenRead = nil
            guard !self.isRunning, self.hostedSessionBinding == binding else { return }
            var lines = screen.map { $0.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) } ?? []
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeLast()
            }
            if self.kind == .terminal, case .exited(let status) = self.state {
                lines += ["", "[shell exited with status \(status)]"]
            }
            guard !lines.isEmpty else { return }
            let data = Data(lines.joined(separator: "\r\n").utf8)
            self.renderedReplayCache = nil
            self.rawOutputStore.append(data)
            self.processor.ingestTestingData(data)
            self.outputVersion &+= 1
            self.contentVersion &+= 1
            self.lastContentChangeAt = Date()
            self.bumpRevision()
        }
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
            SessionLog.debugContent("[buffer tail] \(tail.map(\.debugDescription).joined(separator: " | "))")
        }
        if case .launching = state {
            state = .live
        }
        outputVersion &+= 1
        let contentChanged = updateContentFingerprint()
        if contentChanged {
            clearCurrentAttentionScreenTag()
            lastContentChangeAt = Date()
            contentVersion &+= 1
        }
        if kind == .agent, contentChanged {
            recordAgentActivitySignal()
            if agentActivityState == .working {
                scheduleAgentIdleRecheck()
            }
            scheduleAttentionObservation(event: .contentChanged)
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
        clearCurrentAttentionScreenTag()
        ghosttyBridgeStorage?.noteHostInputForOutputLatency()
        noteInputOutputBaseline()
        guard kind == .agent else { return }
        lastAgentInputAt = Date()
        applyAgentDraftInputEffect(Self.agentDraftInputEffect(input))
        if input == Data([0x1B]) {
            noteAgentTurnInterrupted()
        }
    }

    /// Assigns only a changed value: every keystroke comes here, and
    /// publishing an unchanged one would re-render every view observing
    /// the tab once per key.
    private func noteInputOutputBaseline() {
        guard lastInputOutputVersion != outputVersion else { return }
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
                handleIncomingNotification(notification)
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
                keyboardProtocolFlagStack.append(streamKeyboardProtocolFlags)
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

    private func handleTerminalNotification(
        _ notification: TerminalNotificationRequest,
        marksUnread: Bool = true
    ) {
        guard !ProjectWindowRegistry.shared.isSessionVisible(self) else { return }
        guard !(kind == .agent && parentAgentID != nil) else { return }
        if marksUnread {
            lastNotification = notification
            hasUnreadNotification = true
        }
        TerminalNotificationCenter.shared.post(notification, for: self)
    }

    private func handleIncomingNotification(_ notification: TerminalNotificationRequest) {
        let isAgentCompletion = kind == .agent
            && Self.notificationBodyIndicatesCompletion(notification.body)
        if isAgentCompletion {
            // Completion status is an attention-episode signal, not a second
            // unread-dot source. Deliver the harness notification first and
            // remember that it owns this episode so the classifier can avoid a
            // duplicate fallback even though `hasUnreadNotification` stays false.
            hasHarnessNotificationForAttentionEpisode = true
        }
        handleTerminalNotification(notification, marksUnread: !isAgentCompletion)
        handleAgentNotification(notification)
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
        // Another machine's paths must never become input to local
        // filesystem/project APIs. A session on This Mac (a persistent tab,
        // or one attached to a local session) reports local directories.
        guard reportsLocalWorkingDirectory else { return }
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
        // A persistent tab's host may have shown this one already.
        let key = Self.notificationKey(title: title, body: body)
        guard noteSignalDelivery(key: key, fromHost: false, window: Self.notificationDeduplicationWindow) else { return }
        noteSurfaceSignalWhileFollowing(key: key)
        let notification = TerminalNotificationRequest(title: title, body: body, source: .osc777)
        handleIncomingNotification(notification)
        bumpRevision()
    }

    /// Ghostty rang the terminal bell (BEL).
    func ingestNativeBell() {
        guard noteSignalDelivery(key: "bell", fromHost: false, window: Self.bellDeduplicationWindow) else { return }
        noteSurfaceSignalWhileFollowing(key: "bell")
        bellHandler(self)
    }

    func ingestNativeChildExit(exitCode: Int32) {
        guard let launchID = activeLaunchID else { return }
        if isPersistentLocalSession {
            // The surface's process is the attach adapter, not the program.
            persistentAdapterDidExit(launchID: launchID)
            return
        }
        finishProcessExit(status: exitCode, launchID: launchID)
    }

    /// OSC 133 'D' (shell-integration command end) under native. A precise
    /// command-boundary signal for plain scripts/commands — far better than a
    /// quiet-period guess. (Agent TUIs run on the alternate screen and emit no
    /// per-command markers, so this fires only for primary-screen commands.)
    /// Polls libghostty for the PTY and resolves its stable session leader. This
    /// populates `process.pid` for process-ancestry routing without modifying the
    /// user's shell startup or coordinating through a temporary PID file.
    private func captureNativeShellIdentity() {
        let launchID = activeLaunchID
        func poll(_ attempt: Int) {
            guard activeLaunchID == launchID else { return } // session relaunched/exited
            if let pid = ghosttyBridgeStorage?.nativeSessionLeaderPID() {
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
        guard ghosttyBridgeStorage?.isNativePTYBacked == true else { return }
        lastNativeCommandFinishedAt = Date()
        lastNativeCommandExitCode = exitCode
        // Capture the command's final output and advance the counters so idle
        // detection converges on the real boundary, not a heuristic timeout.
        refreshNativeContentNow()
        bumpRevision()
    }

    // MARK: - Native-PTY content model (search / idle under EXEC)
    //
    // The data layer (getProcessOutput, search, agent activity, waitForProcessIdle)
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
        if let closedTabContentLines {
            return closedTabContentLines.count
        }
        if readsContentFromHost {
            // Read from the host by `refreshContentFromHostIfNeeded`.
            return nativeContentLines.count
        }
        guard ghosttyBridgeStorage?.isNativePTYBacked == true && !usesInjectedTestingContent else {
            return processor.lineCount
        }
        ensureNativeContentFresh()
        return nativeContentLines.count
    }

    private func contentSnapshot(range: Range<Int>) -> [String] {
        if let closedTabContentLines {
            return Array(closedTabContentLines[range.clamped(to: 0..<closedTabContentLines.count)])
        }
        if readsContentFromHost {
            return nativeContentSnapshot(range: range)
        }
        guard ghosttyBridgeStorage?.isNativePTYBacked == true && !usesInjectedTestingContent else {
            return processor.snapshot(range: range)
        }
        ensureNativeContentFresh()
        return nativeContentSnapshot(range: range)
    }

    /// The tab closes because its shell exited (`programExited`): what it
    /// shows now (its surface's text, or the host's screen as last read)
    /// stays its lines after its surface and session are gone.
    func keepContentAfterClosing() {
        guard closedTabContentLines == nil else { return }
        closedTabContentLines = contentSnapshot(range: 0..<contentLineCount())
    }

    private func nativeContentSnapshot(range: Range<Int>) -> [String] {
        guard !nativeContentLines.isEmpty else { return [] }
        let clamped = range.clamped(to: 0..<nativeContentLines.count)
        return Array(nativeContentLines[clamped])
    }

    /// Render-signal entry point: schedule a debounced content refresh so the
    /// output/idle counters advance even when nothing is actively reading.
    func noteNativeRenderRequest() {
        guard ghosttyBridgeStorage?.isNativePTYBacked == true, !usesInjectedTestingContent else { return }
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
            if self.readsContentFromHost {
                // Rendering needs the host's last lines no more often.
                let maximumAge = self.hostContentPollInterval
                Task { @MainActor [weak self] in
                    await self?.refreshContentFromHostIfNeeded(maximumAge: maximumAge, recentOnly: true)
                }
            } else {
                self.refreshNativeContentNow()
            }
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
        guard ghosttyBridgeStorage?.isNativePTYBacked == true, !usesInjectedTestingContent else { return false }
        // The surface does not show the program now; its text comes from
        // the host (`refreshContentFromHostIfNeeded`).
        guard !readsContentFromHost else { return false }
        // recordAgentActivitySignal below re-enters this function through
        // contentSnapshot → ensureNativeContentFresh. Without
        // this guard, a session whose screen changes faster than one scan pass
        // (any working agent repaints its spinner every second) recurses
        // unboundedly and livelocks the main thread.
        guard !isRefreshingNativeContent else { return false }
        isRefreshingNativeContent = true
        defer { isRefreshingNativeContent = false }
        guard let text = readNativeSurfaceText() else { return false }
        lastNativeContentReadAt = Date()
        return replaceNativeContent(with: text)
    }

    /// Takes `text` as the tab's lines; when it changed, advances the output
    /// and content counters and runs the agent activity hooks.
    @discardableResult
    private func replaceNativeContent(with text: String) -> Bool {
        var hasher = Hasher()
        hasher.combine(text)
        let hash = hasher.finalize()
        guard hash != nativeContentHash else { return false }
        nativeContentHash = hash
        nativeContentLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        lastOutputAt = Date()
        if case .launching = state { state = .live }
        outputVersion &+= 1
        clearCurrentAttentionScreenTag()
        lastContentChangeAt = Date()
        contentVersion &+= 1
        if kind == .agent {
            recordAgentActivitySignal()
            if agentActivityState == .working {
                scheduleAgentIdleRecheck()
            }
            scheduleAttentionObservation(event: .contentChanged)
        }
        bumpRevision()
        return true
    }

    // MARK: - Content read from the host (persistent tabs)
    //
    // A persistent tab's surface runs its attach adapter. Until that adapter
    // reports itself attached, while it reconnects (by itself, or relaunched
    // by the tab), and while it shows only a viewport of a session another
    // client made larger, the surface does not show the program's whole
    // screen (`adapterLiveStatus`). The data layer (MCP output, search, idle
    // waits, agent activity) then reads the host's screen into the same line
    // model: the whole history when a caller needs it, only the last lines
    // for loops that watch the screen.

    /// Whether the tab's lines come from its host now (see above).
    var readsContentFromHost: Bool {
        guard persistentHosting != nil, persistentSession != nil, !usesInjectedTestingContent else { return false }
        switch persistentPhase {
        case .reconnecting:
            return true
        case .attached:
            return !(adapterLiveStatus?.showsWholeScreen ?? false)
        case .creating, .idle:
            return false
        }
    }

    /// How old the host's screen may be for a loop that watches this tab's
    /// lines (idle waits, agent input readiness, render signals): reads are
    /// not made more often than this.
    var hostContentPollInterval: TimeInterval {
        persistentHosting?.configuration.hostScreenPollInterval ?? 1
    }

    /// Reads the program's screen from the host when the tab's lines come
    /// from there (`readsContentFromHost`) and the last read is older than
    /// `maximumAge` (default `hostScreenReuseInterval`). Waits for the answer
    /// at most `hostScreenWait`; a later answer still applies. MCP output,
    /// status, search and idle waits call this before they read the tab's
    /// lines.
    ///
    /// `recentOnly`: the caller looks at the last lines only (a loop that
    /// watches the screen for new output or agent activity): only the last
    /// `hostScreenRecentLines` are read, and the tab's lines may then hold
    /// just those (with their line numbers from the first of them) until a
    /// caller that needs the whole history reads again. Whether anything
    /// changed is decided on the last lines either way, so switching between
    /// the two reads alone never looks like new output.
    func refreshContentFromHostIfNeeded(maximumAge: TimeInterval? = nil, recentOnly: Bool = false) async {
        guard readsContentFromHost, let persistentHosting, let binding = persistentSession else { return }
        let configuration = persistentHosting.configuration
        let read: Task<Void, Never>
        if let hostContentRead, hostContentReadIsWhole || recentOnly {
            read = hostContentRead
        } else {
            // A read of the whole history is as recent as the last read
            // only while the lines still hold that history.
            let lastRead = recentOnly || hostContentHasHistory ? hostContentReadAt : nil
            if hostContentRead == nil, let lastRead,
               Date().timeIntervalSince(lastRead) < maximumAge ?? configuration.hostScreenReuseInterval {
                return
            }
            // Supersedes a read of the recent lines under way.
            hostContentReadGeneration &+= 1
            let generation = hostContentReadGeneration
            let maxLines = recentOnly ? max(1, configuration.hostScreenRecentLines) : nil
            read = Task { @MainActor [weak self] in
                let screen = try? await persistentHosting.screen(of: binding, maxLines: maxLines)
                guard let self, self.hostContentReadGeneration == generation else { return }
                self.hostContentRead = nil
                guard let screen, self.persistentSession == binding, self.readsContentFromHost else { return }
                self.applyHostContent(screen, recentLines: maxLines)
            }
            hostContentRead = read
            hostContentReadIsWhole = !recentOnly
        }
        await Self.wait(for: read, upTo: configuration.hostScreenWait)
    }

    /// Takes a screen read from the host as the tab's lines. `recentLines`:
    /// the read asked for only that many last lines (a host without the
    /// limit sends them all, as does one whose history is shorter).
    private func applyHostContent(_ screen: HostScreenText, recentLines: Int?) {
        hostContentReadAt = Date()
        if hostContentUsesAlternateScreen != screen.alternateScreen {
            hostContentUsesAlternateScreen = screen.alternateScreen
        }
        let lines = screen.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hasHistory = recentLines.map { lines.count < $0 } ?? true
        let tailKey = Self.hostContentChangeKey(
            lines, recentLines: persistentHosting?.configuration.hostScreenRecentLines ?? recentLines ?? lines.count
        )
        let changed = tailKey != hostContentTailKey
        hostContentTailKey = tailKey
        // A read of recent lines that shows nothing new keeps the history.
        guard changed || hasHistory else { return }
        hostContentHasHistory = hasHistory
        if changed {
            replaceNativeContent(with: screen.text)
        } else {
            // The same last lines, now with the history above them.
            nativeContentLines = lines
            var hasher = Hasher()
            hasher.combine(screen.text)
            nativeContentHash = hasher.finalize()
        }
    }

    /// What identifies the last lines of a screen read from the host,
    /// whether the read had the whole history or its last `recentLines`
    /// lines: the last half of those, from the last line with text. Half,
    /// so a host that counts a line more or less at either end gives the
    /// same key; still more than a screen holds, so any change on screen
    /// changes it.
    static func hostContentChangeKey(_ lines: [String], recentLines: Int) -> Int {
        var end = lines.count
        while end > 0, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            end -= 1
        }
        let count = max(1, recentLines / 2)
        var hasher = Hasher()
        for line in lines[max(0, end - count)..<end] {
            hasher.combine(line)
        }
        hasher.combine(end > 0)
        return hasher.finalize()
    }

    /// The host's screen is no longer this tab's: the next read takes the
    /// surface's (or the next session's) text.
    private func forgetHostContent() {
        // A read under way no longer applies.
        hostContentReadGeneration &+= 1
        hostContentRead?.cancel()
        hostContentRead = nil
        hostContentReadAt = nil
        hostContentUsesAlternateScreen = false
        hostContentHasHistory = false
        hostContentTailKey = nil
        lastNativeContentReadAt = nil
    }

    // MARK: - The program's screen before MCP types into it

    /// The last lines of what the program shows now, for a caller about to
    /// type into it (MCP input to an agent, which must never answer a
    /// permission prompt it cannot see): the surface's text while a surface
    /// shows the program, else its host's screen (`Screen`), read now. A
    /// surface that shows nothing yet (a restored tab whose adapter has not
    /// drawn the program) is not taken as the program's screen. Empty while
    /// a persistent tab's session is still being created (no program yet).
    /// Nil when the screen cannot be known: its host did not answer.
    func programScreenLinesForInput() async -> [String]? {
        let limit = AgentPermissionPrompt.tailLineLimit * 2
        if persistentHosting != nil, persistentPhase == .creating {
            return []
        }
        if readsContentFromHost {
            let started = Date()
            await refreshContentFromHostIfNeeded(maximumAge: 0, recentOnly: true)
            guard let readAt = hostContentReadAt, readAt >= started else { return nil }
            return Array(AgentPermissionPrompt.tail(of: nativeContentLines).suffix(limit))
        }
        if let read = hostScreenReaderWhileNoSurfaceShowsProgram() {
            return await Self.readHostScreenLines(read, limit: limit, timeout: hostScreenWaitForInput)
        }
        let count = contentLineCount()
        let lines = Array(AgentPermissionPrompt.tail(of: contentSnapshot(range: max(0, count - 600)..<count)).suffix(limit))
        if lines.isEmpty, let read = hostScreenReader() {
            // Nothing drawn yet: the host knows what the program shows.
            return await Self.readHostScreenLines(read, limit: limit, timeout: hostScreenWaitForInput)
        }
        return lines
    }

    /// The last lines the tab holds now, without reading the surface or the
    /// host again (for listings that look at many tabs).
    var cachedScreenTailLines: [String] {
        if readsContentFromHost || (ghosttyBridgeStorage?.isNativePTYBacked == true && !usesInjectedTestingContent) {
            return Array(AgentPermissionPrompt.tail(of: nativeContentLines))
        }
        let count = processor.lineCount
        return Array(AgentPermissionPrompt.tail(of: processor.snapshot(range: max(0, count - 200)..<count)))
    }

    private var hostScreenWaitForInput: Duration {
        persistentHosting?.configuration.hostScreenWait ?? .seconds(2)
    }

    /// Reads the program's screen from its host for a tab attached to a
    /// hosted session whose surface does not show the program now: its
    /// adapter waits for its turn (a restore), has not attached yet, or
    /// reconnects by itself. Nil when a surface shows it (or there is no
    /// host to ask).
    private func hostScreenReaderWhileNoSurfaceShowsProgram() -> (@MainActor () async throws -> HostScreenText)? {
        guard let hostedAttachment else { return nil }
        if hostedLaunchDeferred {
            guard let control = deferredHostControl else { return nil }
            return { [sessionID = hostedAttachment.sessionID, hostID = hostedAttachment.hostID] in
                try await control.screen(sessionID, scrollback: true, maxLines: 200, expectedHostID: hostID)
            }
        }
        guard isRunning, !(adapterLiveStatus?.showsWholeScreen ?? false) else { return nil }
        return hostScreenReader()
    }

    /// Reads the screen of the hosted session the tab shows from its host.
    private func hostScreenReader() -> (@MainActor () async throws -> HostScreenText)? {
        if let persistentHosting, let binding = persistentSession {
            return { try await persistentHosting.screen(of: binding, maxLines: 200) }
        }
        guard let hostedAttachment, let control = attachedHostControl else { return nil }
        return { [sessionID = hostedAttachment.sessionID, hostID = hostedAttachment.hostID] in
            try await control.screen(sessionID, scrollback: true, maxLines: 200, expectedHostID: hostID)
        }
    }

    private static func readHostScreenLines(
        _ read: @escaping @MainActor () async throws -> HostScreenText,
        limit: Int,
        timeout: Duration
    ) async -> [String]? {
        let result = HostScreenReadResult()
        let task = Task { @MainActor in
            result.screen = try? await read()
        }
        await wait(for: task, upTo: timeout)
        guard let screen = result.screen else { return nil }
        let lines = screen.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return Array(AgentPermissionPrompt.tail(of: lines).suffix(limit))
    }

    @MainActor
    private final class HostScreenReadResult {
        var screen: HostScreenText?
    }

    /// Waits for `task`, or until `timeout` passed, whichever comes first.
    private static func wait(for task: Task<Void, Never>, upTo timeout: Duration) async {
        let waiter = FirstResume()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter.continuation = continuation
            Task { @MainActor in
                await task.value
                waiter.resume()
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                waiter.resume()
            }
        }
    }

    @MainActor
    private final class FirstResume {
        var continuation: CheckedContinuation<Void, Never>?

        func resume() {
            continuation?.resume()
            continuation = nil
        }
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
            annotation: nil,
            scenarioID: scenarioID,
            checkpoint: checkpoint,
            harnessVersion: harnessVersion,
            runID: runID
        )
        attentionObservationRecorder.record(observation, synchronously: true)
        return (observation.id, attentionObservationRecorder.outputURL)
    }

    @discardableResult
    func captureAttentionCorrection(
        _ correction: TerminalAttentionCorrection
    ) throws -> (id: UUID, outputURL: URL) {
        guard let attentionObservationRecorder = (
            ensureAttentionObservationRecorder() ?? ensureAttentionCorrectionRecorder()
        ) else {
            throw TerminalAttentionRecordingError.disabled
        }

        let sourceEvent = latestAttentionObservationEvent
        let sourceObservation = makeAttentionObservation(
            event: sourceEvent,
            label: nil,
            annotation: nil,
            scenarioID: nil,
            checkpoint: nil,
            harnessVersion: nil,
            runID: nil
        )
        let sourcePrediction = kind == .agent
            ? TerminalAttentionClassifier.shared.predict(sourceObservation)
            : nil
        if let sourcePrediction {
            attentionClassifierPrediction = sourcePrediction
        }

        let observation = makeAttentionObservation(
            event: .labeledCheckpoint,
            label: correction.label,
            annotation: .init(
                schemaVersion: 1,
                provenance: "cherry_in_app_human_correction",
                confidence: 1,
                rationale: "human_corrected_action_label",
                reason: correction.reason
            ),
            scenarioID: "in-app-attention-correction",
            checkpoint: "human_corrected",
            harnessVersion: nil,
            runID: nil,
            correction: .init(
                sourceEvent: sourceEvent,
                modelID: sourcePrediction?.modelID,
                modelLabel: sourcePrediction?.label,
                attentionProbability: sourcePrediction?.attentionProbability,
                threshold: sourcePrediction?.threshold,
                supersedesObservationID: currentAttentionScreenTagObservationID
            )
        )
        attentionObservationRecorder.record(observation, synchronously: true)
        currentAttentionScreenTag = correction
        currentAttentionScreenTagObservationID = observation.id
        acknowledgeAttentionAlert()
        return (observation.id, attentionObservationRecorder.outputURL)
    }

    func acknowledgeAttentionAlert() {
        guard attentionAlertGeneration > acknowledgedAttentionAlertGeneration else { return }
        acknowledgedAttentionAlertGeneration = attentionAlertGeneration
        attentionNotificationGate.acknowledge()
        guard hasUnacknowledgedAttention else { return }
        hasUnacknowledgedAttention = false
        bumpRevision()
    }

    private func scheduleAttentionObservation(event: TerminalAttentionObservationEvent) {
        guard kind == .agent else { return }
        latestAttentionObservationEvent = event

        let isDebounced = event == .contentChanged || event == .inputChanged
        if !isDebounced {
            attentionObservationTask?.cancel()
            attentionObservationTask = nil
            recordAttentionObservation(event: event)
            return
        }

        guard attentionObservationTask == nil else { return }
        attentionObservationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.attentionObservationInterval * 1_000)))
            guard let self, !Task.isCancelled else { return }
            self.attentionObservationTask = nil
            self.recordAttentionObservation(event: event)
        }
    }

    private func recordAttentionObservation(event: TerminalAttentionObservationEvent) {
        let attentionObservationRecorder = ensureAttentionObservationRecorder()
        let observation = makeAttentionObservation(
            event: event,
            label: nil,
            annotation: nil,
            scenarioID: nil,
            checkpoint: nil,
            harnessVersion: nil,
            runID: nil
        )
        let prediction = TerminalAttentionClassifier.shared.predict(observation)
        // Published values change only when they differ: an observation
        // follows typing (debounced), and republishing an unchanged value
        // would re-render every view observing the tab.
        if attentionClassifierPrediction != prediction {
            attentionClassifierPrediction = prediction
        }
        if agentTurnState == .userInterrupted {
            // The user is already handling this turn. Preserve interruption and
            // follow-up screen observations for training without surfacing a
            // new alert until the user submits another turn.
            isAttentionEpisodeActive = prediction.needsAttention
            setHasUnacknowledgedAttention(false)
            attentionNotificationGate.acknowledge()
            attentionObservationRecorder?.record(observation)
            return
        }
        if prediction.needsAttention {
            // One continuous run of attention-needed predictions is one alert
            // episode. Acknowledging the visible result must cover later
            // debounced observations of that same completed screen.
            if !isAttentionEpisodeActive, event != .inputChanged {
                attentionAlertGeneration &+= 1
                isAttentionEpisodeActive = true
            }
            setHasUnacknowledgedAttention(
                isAttentionEpisodeActive
                    && attentionAlertGeneration > acknowledgedAttentionAlertGeneration
            )
        } else {
            // Preserve a consumed/completed episode through transient classifier
            // wobble. Native screen reflow can momentarily make an idle agent
            // look working without any new turn or agent output. The next active
            // turn will still clear the episode and allow its result to alert.
            if prediction.turnState != .completed {
                isAttentionEpisodeActive = false
            }
            setHasUnacknowledgedAttention(false)
        }
        updateAttentionNotification(for: prediction)
        attentionObservationRecorder?.record(observation)
    }

    private func setHasUnacknowledgedAttention(_ value: Bool) {
        guard hasUnacknowledgedAttention != value else { return }
        hasUnacknowledgedAttention = value
    }

    private func updateAttentionNotification(for prediction: TerminalAttentionPrediction) {
        guard attentionNotificationGate.shouldNotify(
            prediction: prediction,
            isTopLevelAgent: kind == .agent && parentAgentID == nil,
            hasUnreadNativeNotification:
                hasUnreadNotification || hasHarnessNotificationForAttentionEpisode,
            hasUnacknowledgedAttention: hasUnacknowledgedAttention
        ) else {
            return
        }

        attentionNotificationHandler(prediction, self)
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

    private func ensureAttentionCorrectionRecorder() -> TerminalAttentionObservationRecorder? {
        if attentionCorrectionRecorder == nil {
            attentionCorrectionRecorder = TerminalAttentionObservationRecorder(
                directoryURL: attentionCorrectionDirectoryProvider(),
                sessionID: id,
                harness: "\(agentName ?? kind.rawValue)-correction"
            )
        }
        return attentionCorrectionRecorder
    }

    private func makeAttentionObservation(
        event: TerminalAttentionObservationEvent,
        label: TerminalAttentionLabel?,
        annotation: TerminalAttentionObservation.AnnotationContext?,
        scenarioID: String?,
        checkpoint: String?,
        harnessVersion: String?,
        runID: String?,
        correction: TerminalAttentionObservation.CorrectionContext? = nil
    ) -> TerminalAttentionObservation {
        let now = Date()
        let lineCount = contentLineCount()
        let rowLimit = min(max(viewportSize.rows, 1), Self.attentionObservationMaximumRows)
        let columnLimit = min(max(viewportSize.columns, 1), Self.attentionObservationMaximumColumns)
        let gridStart = max(0, lineCount - rowLimit)
        let grid = contentSnapshot(range: gridStart..<lineCount).map { line in
            String(line.prefix(columnLimit))
        }
        // libghostty exposes terminal text but not per-cell styling. Preserve the
        // optional schema field without maintaining a second terminal parser.
        let styledGrid: [[TerminalAttentionObservation.TerminalContext.StyledRun]]? = nil
        let cursor = cursorState

        return TerminalAttentionObservation(
            schemaVersion: TerminalAttentionObservation.currentSchemaVersion,
            id: UUID(),
            recordedAt: now,
            event: event,
            label: label,
            annotation: annotation,
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
                styledGrid: styledGrid,
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
            interaction: .init(
                hasUnsubmittedInput: hasUnsubmittedHumanInput,
                millisecondsSinceLastKeystroke: Self.milliseconds(since: lastHumanKeystrokeAt, now: now),
                terminalFocused: ghosttyBridgeStorage?.isTerminalFocused ?? false
            ),
            turn: kind == .agent ? .init(state: agentTurnState) : nil,
            correction: correction,
            outputVersion: outputVersion,
            contentVersion: contentVersion
        )
    }

    private var attentionActivityEvidenceName: String {
        switch agentActivitySource {
        case .none: "none"
        case .outputActivity: "output_activity"
        case .inputSubmit: "input_submit"
        case .quietWindow: "quiet_window"
        case .promptMarker: "prompt_marker"
        case .workingMarker: "working_marker"
        case .titleSpinner: "title_spinner"
        case .notification: "notification"
        case .processExit: "process_exit"
        case .answerMenu: TerminalAttentionPrediction.answerMenuEvidence
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

    private func handleAgentNotification(
        _ notification: TerminalNotificationRequest
    ) {
        guard kind == .agent else { return }
        defer {
            scheduleAttentionObservation(event: .notification)
        }

        let body = notification.body
        if Self.notificationBodyIndicatesPermission(body) {
            setAgentActivityState(.permission, source: .notification)
            return
        }
        // A menu on screen still waits on the user's answer.
        if Self.notificationBodyIndicatesCompletion(body), !agentIsAtAnswerMenu {
            setAgentActivityState(.idle, source: .notification)
        }
    }

    private var agentStateHasDirectEvidence: Bool {
        switch agentActivitySource {
        case .promptMarker, .workingMarker, .titleSpinner, .notification, .processExit, .answerMenu:
            true
        case .none, .outputActivity, .inputSubmit, .quietWindow:
            false
        }
    }

    // Agents without a recognizable prompt/working UI (e.g. plain REPLs) only
    // ever produce weak evidence; idle waits fall back to quiet windows for them.
    var agentActivityEvidenceIsStrong: Bool {
        kind == .agent && agentStateHasDirectEvidence
    }

    @discardableResult
    private func recordAgentTitleActivity(_ title: String) -> Bool {
        guard kind == .agent else { return false }

        var didChange = applyAutomaticAgentTitle(from: title)

        let spinnerActive = Self.titleIndicatesAgentWorking(title)
        let spinnerCleared = titleIndicatesAgentWorking && !spinnerActive
        titleIndicatesAgentWorking = spinnerActive

        if spinnerActive {
            lastTitleSpinnerAt = Date()
            lastStrongWorkingEvidenceAt = Date()
            scheduleAgentIdleRecheck()
            if noteAgentTitleForResumedWork(title, isSpinner: true) {
                return startSelfResumedAgentTurn(source: .titleSpinner) || didChange
            }
            return markAgentWorking(source: .titleSpinner) || didChange
        }
        _ = noteAgentTitleForResumedWork(title, isSpinner: false)
        if spinnerCleared || agentUsesTitleActivitySignals {
            didChange = recordAgentActivitySignal() || didChange
        }
        return didChange
    }

    private func applyAutomaticAgentTitle(from terminalTitle: String) -> Bool {
        let brand = AgentToolBrand.detect(
            name: agentName ?? systemTitle,
            commandLine: subtitle
        )
        let projectPaths: [String?] = [projectRoot, workingDirectory]
        let projectNames = Set<String>(projectPaths.compactMap { path -> String? in
            guard let path else { return nil }
            let name = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        })
        guard let nextTitle = AgentTerminalTitleParser.taskTitle(
            from: terminalTitle,
            brand: brand,
            projectNames: projectNames,
            agentName: agentName
        ) else {
            return false
        }

        var didChange = false
        if automaticTitle != nextTitle {
            automaticTitle = nextTitle
            didChange = true
        }
        if titleSource != .explicit,
           title != nextTitle || titleSource != .automatic {
            title = nextTitle
            titleSource = .automatic
            didChange = true
            scheduleHostSessionNameSync()
        }
        return didChange
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

        var didChange = false
        switch applyAgentAnswerMenu() {
        case .showing(let changed):
            return changed
        case .left(let changed):
            didChange = changed
        case .none:
            break
        }

        let markerLines = renderedOutputAgentMarkerLines()
        let workingLineIndices = AgentScreenActivity.workingLineIndices(markerLines, agent: screenAgentKey)
        if noteAgentScreenForResumedWork(markerLines, workingLineIndices: workingLineIndices) {
            return startSelfResumedAgentTurn(source: .workingMarker) || didChange
        }
        if !workingLineIndices.isEmpty {
            return markAgentWorking(source: .workingMarker) || didChange
        }
        if titleSpinnerEvidenceIsActive {
            return markAgentWorking(source: .titleSpinner) || didChange
        }
        if renderedOutputShowsAgentInputPrompt() {
            return requestAgentIdleFromRenderedOutput() || didChange
        }
        // Full-screen TUIs repaint the composer after every keystroke. If a new
        // harness version changes its prompt glyph or layout, that repaint must
        // not look like agent output while Cherry knows the user still has an
        // unsubmitted draft. Explicit working markers and title spinners above
        // continue to win, and submitting the draft clears this flag before
        // marking the agent working.
        if hasUnsubmittedHumanInput {
            cancelAgentIdleConfirmation()
            return setAgentActivityState(.idle, source: .promptMarker) || didChange
        }
        guard !agentStateResistsOutputActivity else { return didChange }
        return setAgentActivityState(.working, source: .outputActivity) || didChange
    }

    private enum AgentAnswerMenuEffect {
        /// A menu shows: the state says so, and nothing else applies.
        case showing(changed: Bool)
        /// The menu the state followed is gone: the turn goes on.
        case left(changed: Bool)
        /// No menu, and the state did not follow one.
        case none
    }

    /// Whether the state follows a permission or question menu on screen.
    private var agentIsAtAnswerMenu: Bool {
        agentActivitySource == .answerMenu && agentActivityState.awaitsUserAnswer
    }

    /// A permission or question menu at the bottom of the screen
    /// (`AgentScreenActivity.answerMenu`, MCP's recognizers) makes the
    /// agent wait on the user's answer: `.permission` or `.needsInput`, an
    /// attention alert like a permission prompt. Its state follows the
    /// menu: when the menu goes (answered, or withdrawn), the turn it
    /// paused goes on and the agent is working again until its screen says
    /// otherwise. A startup dialog before this tab's first turn (folder
    /// trust, resume picker) is not one: the agent has no turn to pause.
    /// A permission prompt the agent notified is left to the notification.
    private func applyAgentAnswerMenu() -> AgentAnswerMenuEffect {
        guard agentActivityState != .error else { return .none }
        let menu = renderedOutputAgentAnswerMenu()
        if let menu, agentTurnState != .notStarted || !startedCurrentProgram {
            if agentActivityState == .permission, agentActivitySource == .notification {
                return .showing(changed: false)
            }
            cancelAgentIdleConfirmation()
            // An agent this tab follows rather than started (restored or
            // adopted) asking a question is in a turn submitted before
            // the tab followed it.
            if agentTurnState == .notStarted {
                agentTurnState = .active
            }
            let state: AgentActivityState = menu == .permission ? .permission : .needsInput
            return .showing(changed: setAgentActivityState(state, source: .answerMenu))
        }
        guard agentIsAtAnswerMenu else { return .none }
        // The answer resumes the turn: like fresh working evidence, a
        // composer drawn before the agent's next working frame is
        // confirmed before it counts as the turn's end.
        lastStrongWorkingEvidenceAt = Date()
        let changed = setAgentActivityState(.working, source: .inputSubmit)
        scheduleAgentIdleRecheck()
        return .left(changed: changed)
    }

    private func renderedOutputAgentAnswerMenu() -> AgentScreenActivity.AnswerMenu? {
        let lineCount = effectiveAgentContentLineCount()
        guard lineCount > 0 else { return nil }
        let start = max(0, lineCount - Self.agentInputMarkerTailLineLimit)
        return AgentScreenActivity.answerMenu(in: contentSnapshot(range: start..<lineCount))
    }

    private var agentStateResistsOutputActivity: Bool {
        if agentActivityState == .permission || agentActivityState == .needsInput || agentActivityState == .error {
            return true
        }
        switch agentActivitySource {
        case .promptMarker, .notification, .processExit, .answerMenu:
            return true
        case .none, .outputActivity, .inputSubmit, .workingMarker, .titleSpinner, .quietWindow:
            return false
        }
    }

    @discardableResult
    private func markAgentWorking(source: AgentActivitySource) -> Bool {
        guard agentActivitySource != .processExit else { return false }
        guard !agentActivityState.awaitsUserAnswer, agentActivityState != .error else { return false }
        cancelAgentIdleConfirmation()
        if source == .workingMarker || source == .titleSpinner {
            lastStrongWorkingEvidenceAt = Date()
            // An agent this tab follows rather than started (restored or
            // adopted) that shows it is at work is in a turn submitted
            // before the tab followed it: its end is a finished turn, which
            // notifies like one this tab saw submitted.
            if agentTurnState == .notStarted, !startedCurrentProgram {
                agentTurnState = .active
            }
        }
        return setAgentActivityState(.working, source: source)
    }

    // MARK: Turns the agent resumes by itself

    /// The agent's turn ended (or, interrupted by the user, it settled at
    /// its composer), and it neither waits on an answer nor failed or
    /// exited: work it shows from here on is its own new turn, once
    /// `AgentResumedWorkDetector` tells it from a stale frame.
    private var agentMayResumeWorkByItself: Bool {
        guard resumedWorkDetector.isArmed,
              agentTurnState == .completed || agentTurnState == .userInterrupted
        else { return false }
        return agentActivitySource != .processExit
            && !agentActivityState.awaitsUserAnswer
            && agentActivityState != .error
    }

    private var resumedWorkLayout: AgentResumedWorkDetector.Layout {
        .init(columns: viewportSize.columns, rows: viewportSize.rows, fromHost: readsContentFromHost)
    }

    /// The turn ended: what the screen shows now is its past.
    private func armResumedWorkDetector() {
        resumedWorkDetector.arm(screenLines: lastReadAgentScreenTail(), layout: resumedWorkLayout)
    }

    /// Whether `screen` (the marker tail), whose lines at
    /// `workingLineIndices` show live work, shows the agent back at work by
    /// itself.
    private func noteAgentScreenForResumedWork(_ screen: [String], workingLineIndices: [Int]) -> Bool {
        guard agentMayResumeWorkByItself else { return false }
        return resumedWorkDetector.noteScreen(
            screen,
            workingLineIndices: workingLineIndices,
            layout: resumedWorkLayout,
            lastInputAt: lastAgentInputAt,
            now: Date()
        )
    }

    /// Whether the title, now `title`, shows the agent back at work by
    /// itself.
    private func noteAgentTitleForResumedWork(_ title: String, isSpinner: Bool) -> Bool {
        guard agentMayResumeWorkByItself else { return false }
        return resumedWorkDetector.noteTitle(title, isSpinner: isSpinner, now: Date())
    }

    /// The agent went back to work by itself after its turn ended (a
    /// background agent's or task's result, a scheduled wake-up, a hook):
    /// a new turn, as if one was submitted. The sidebar shows it working,
    /// MCP counts it (`agent_turn`, `agent_turn_state` active, a monitor's
    /// `done` when it ends), and its end is a new attention episode that
    /// can alert once. Nothing was submitted, so `lastAgentSubmitAt` and
    /// the turn-start rule of MCP waits keep to submitted turns.
    @discardableResult
    private func startSelfResumedAgentTurn(source: AgentActivitySource) -> Bool {
        resumedWorkDetector.disarm()
        agentSelfResumedTurnCount &+= 1
        agentTurnState = .active
        // A harness notification of the turn that ended owned that turn's
        // episode, not this one's.
        hasHarnessNotificationForAttentionEpisode = false
        if activityDebugEnabled {
            SessionLog.debug("[activity] turn resumed by the agent itself source=\(source)")
        }
        if !markAgentWorking(source: source) {
            // Its first frames already made it working: the observation
            // that ends the finished turn's episode is due now.
            scheduleAttentionObservation(event: .activityStateChanged)
        }
        scheduleAgentIdleRecheck()
        bumpRevision()
        return true
    }

    @discardableResult
    private func requestAgentIdleFromRenderedOutput() -> Bool {
        guard agentActivitySource != .processExit else { return false }
        guard !agentActivityState.awaitsUserAnswer, agentActivityState != .error else { return false }

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
        guard !agentActivityState.awaitsUserAnswer, agentActivityState != .error else { return }
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
            SessionLog.debug("[activity] recheck state=\(agentActivityState) source=\(agentActivitySource) marker=\(renderedOutputShowsAgentWorkingMarker()) spinner=\(titleSpinnerEvidenceIsActive) prompt=\(renderedOutputShowsAgentInputPrompt())")
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
            let normalizedAgentName = screenAgentKey
            let scanStart = max(0, lineCount - Self.agentInputMarkerTailLineLimit)
            let scanLines = contentSnapshot(range: scanStart..<lineCount)
            let promptLines = agentPromptWindowLines(
                scanStart: scanStart,
                scanLines: scanLines,
                applyInputFloor: false
            )
            let promptVisible = promptLines.contains { line in
                AgentScreenActivity.isInputPromptLine(line, agent: normalizedAgentName)
            } || AgentScreenActivity.showsInputMarker(scanLines, agent: normalizedAgentName)
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

    /// The harness key the screen rules (`AgentScreenActivity`) use.
    private var screenAgentKey: String {
        AgentScreenActivity.agentKey(name: agentName ?? title, commandLine: subtitle)
    }

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

    /// The screen tail the working and input markers are read from: the
    /// last `agentInputMarkerTailLineLimit` lines up to the last one with
    /// text.
    private func renderedOutputAgentMarkerLines() -> [String] {
        let lineCount = effectiveAgentContentLineCount()
        guard lineCount > 0 else { return [] }
        let markerStart = max(0, lineCount - Self.agentInputMarkerTailLineLimit)
        return contentSnapshot(range: markerStart..<lineCount)
    }

    private func renderedOutputShowsAgentWorkingMarker() -> Bool {
        AgentScreenActivity.showsWorkingMarker(renderedOutputAgentMarkerLines(), agent: screenAgentKey)
    }

    private static let agentResumedWorkBaselineLineLimit = 200

    /// The tab's last lines with text as it last read them, without reading
    /// its screen again: a state change can take them (a refresh from there
    /// would re-enter the activity hooks).
    private func lastReadAgentScreenTail() -> [String] {
        let lines: [String]
        if let closedTabContentLines {
            lines = closedTabContentLines
        } else if readsContentFromHost
                    || (ghosttyBridgeStorage?.isNativePTYBacked == true && !usesInjectedTestingContent) {
            lines = nativeContentLines
        } else {
            let count = processor.lineCount
            lines = processor.snapshot(range: max(0, count - Self.agentTrailingBlankScanLimit)..<count)
        }
        var end = lines.count
        while end > 0, lines[end - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            end -= 1
        }
        return Array(lines[max(0, end - Self.agentResumedWorkBaselineLineLimit)..<end])
    }

    private func renderedOutputShowsAgentInputPrompt() -> Bool {
        let lineCount = effectiveAgentContentLineCount()
        guard lineCount > 0 else { return false }

        let normalizedAgentName = screenAgentKey
        let markerStart = max(0, lineCount - Self.agentInputMarkerTailLineLimit)
        let markerLines = contentSnapshot(range: markerStart..<lineCount)
        if AgentScreenActivity.showsWorkingMarker(markerLines, agent: normalizedAgentName) {
            return false
        }

        let promptLines = agentPromptWindowLines(
            scanStart: markerStart,
            scanLines: markerLines,
            applyInputFloor: true
        )
        if promptLines.contains(where: { line in
            AgentScreenActivity.isInputPromptLine(line, agent: normalizedAgentName)
        }) {
            return true
        }

        return AgentScreenActivity.showsInputMarker(markerLines, agent: normalizedAgentName)
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

    private static let agentInputPromptTailLineLimit = AgentScreenActivity.promptTailLineLimit
    private static let agentInputMarkerTailLineLimit = AgentScreenActivity.markerTailLineLimit

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

    private static let enhancedShiftEnterBytes = Data("\u{1B}[13;2u".utf8)

    private static func agentDraftInputEffect(_ data: Data) -> AgentDraftInputEffect {
        guard !data.isEmpty else { return .none }
        if agentInputSubmitsTurn(data) {
            return .submitted
        }

        let bytes = Array(data)
        if bytes.contains(0x03) || bytes.contains(0x15) {
            return .cleared
        }
        if data == enhancedShiftEnterBytes {
            return .inserted
        }
        if bytes.starts(with: bracketedPasteStartBytes),
           bytes.count > bracketedPasteStartBytes.count + bracketedPasteEndBytes.count,
           bytes.suffix(bracketedPasteEndBytes.count).elementsEqual(bracketedPasteEndBytes) {
            return .inserted
        }
        if bytes.first == 0x1B {
            if bytes == [0x1B, 0x7F] || bytes == Array("\u{1B}[3~".utf8) {
                return .edited
            }
            return .none
        }
        if bytes.contains(where: { (0x20...0x7E).contains($0) || $0 >= 0x80 }) {
            return .inserted
        }
        if bytes.contains(where: { $0 == 0x08 || $0 == 0x17 || $0 == 0x7F }) {
            return .edited
        }
        return .none
    }

    static func appKitKeyEventSubmitsAgentTurn(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        guard event.keyCode == 36 || event.keyCode == 76 else { return false }

        let heldModifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        return heldModifiers.isEmpty
    }

    private static func appKitDraftInputEffect(_ event: NSEvent) -> AgentDraftInputEffect {
        guard event.type == .keyDown else { return .none }
        if appKitKeyEventSubmitsAgentTurn(event) {
            return .submitted
        }

        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if modifiers.contains(.command) {
            return event.charactersIgnoringModifiers?.lowercased() == "v" ? .inserted : .none
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            return .edited
        }
        if modifiers.contains(.shift), (event.keyCode == 36 || event.keyCode == 76) {
            return .inserted
        }
        if modifiers.contains(.control),
           let scalar = event.characters?.unicodeScalars.first {
            switch scalar.value {
            case 0x03, 0x15:
                return .cleared
            case 0x17:
                return .edited
            default:
                return .none
            }
        }
        guard let characters = event.characters, !characters.isEmpty else { return .none }
        return characters.unicodeScalars.contains(where: { !CharacterSet.controlCharacters.contains($0) })
            ? .inserted
            : .none
    }

    private static func appKitKeyEventInterruptsAgentTurn(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if event.keyCode == 53, modifiers.isEmpty {
            return true
        }
        return modifiers == [.control]
            && event.characters?.unicodeScalars.first?.value == 0x03
    }

    private func applyAgentDraftInputEffect(_ effect: AgentDraftInputEffect) {
        guard kind == .agent, effect != .none else { return }
        lastHumanKeystrokeAt = Date()

        if agentIsAtAnswerMenu {
            // Keys typed into a permission or question menu answer it
            // (digits, arrows, Enter): no draft and no new turn. The state
            // follows the screen: another question of the same menu keeps
            // it, the menu's end resumes the paused turn
            // (`applyAgentAnswerMenu`).
            if effect == .submitted {
                hasUnsubmittedHumanInput = false
                noteHumanInputIfNeeded()
            }
            return
        }

        switch effect {
        case .none:
            return
        case .inserted:
            hasUnsubmittedHumanInput = true
            scheduleAttentionObservation(event: .inputChanged)
        case .edited:
            scheduleAttentionObservation(event: .inputChanged)
        case .cleared:
            hasUnsubmittedHumanInput = false
            scheduleAttentionObservation(event: .inputChanged)
        case .submitted:
            hasUnsubmittedHumanInput = false
            hasHarnessNotificationForAttentionEpisode = false
            noteHumanInputIfNeeded()
            agentWasWorkingAtLastSubmit = agentActivityState == .working && agentStateHasDirectEvidence
            agentWasReadableAtLastSubmit = agentStateHasDirectEvidence
            agentSubmittedTurnCount &+= 1
            lastAgentSubmitAt = Date()
            agentTurnState = .active
            resumedWorkDetector.disarm()
            setAgentActivityState(.working, source: .inputSubmit)
            scheduleAgentIdleRecheck()
            scheduleAttentionObservation(event: .inputSubmitted)
        }
    }

    private func noteAgentDraftCleared() {
        guard kind == .agent else { return }
        applyAgentDraftInputEffect(.cleared)
    }

    private func noteAgentTurnInterrupted() {
        guard kind == .agent, agentTurnState == .active else { return }
        agentTurnState = .userInterrupted
        scheduleAttentionObservation(event: .turnInterrupted)
    }

    /// Every keystroke clears it: publishes only when there was one.
    private func clearCurrentAttentionScreenTag() {
        if currentAttentionScreenTag != nil {
            currentAttentionScreenTag = nil
        }
        currentAttentionScreenTagObservationID = nil
    }

    @discardableResult
    private func setAgentActivityState(_ nextState: AgentActivityState, source: AgentActivitySource) -> Bool {
        guard kind == .agent else { return false }
        if nextState == .idle || nextState == .error {
            switch agentTurnState {
            case .active:
                agentTurnState = .completed
                armResumedWorkDetector()
            case .userInterrupted where nextState == .idle && !resumedWorkDetector.isArmed:
                // The interrupted turn settled at the composer: work the
                // agent shows from here on is its own.
                armResumedWorkDetector()
            case .userInterrupted, .completed, .notStarted:
                break
            }
        }
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
        streamKeyboardProtocolFlags = flags
        hostInputWriter.setKeyboardProtocolFlags(flags)
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

    private func noteHumanInputIfNeeded() {
        guard kind == .agent else { return }
        lastHumanInputLine = effectiveAgentContentLineCount()
        lastHumanInputAt = Date()
        humanInputGeneration &+= 1
    }

    private func keyboardProtocolFlagsByApplying(flags: Int, mode: Int) -> Int {
        switch mode {
        case 2:
            streamKeyboardProtocolFlags | flags
        case 3:
            streamKeyboardProtocolFlags & ~flags
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
        guard isBuildingBridgeForView else {
            revision &+= 1
            return
        }
        guard !isRevisionBumpScheduled else { return }
        isRevisionBumpScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isRevisionBumpScheduled = false
                self.revision &+= 1
            }
        }
    }
}
