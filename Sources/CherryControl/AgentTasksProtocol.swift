import Foundation

// MARK: - Tasks and results
//
// An orchestrating agent hands work to worker agents as tasks: MCP
// `spawn_agent` with `task` starts a visible agent tab nested under it and
// records the task; Cherry types a one-line kickoff into the worker, which
// reads its brief with `get_my_task` and answers with `report_result`,
// checked against the task's `result_schema`. The orchestrator waits with
// `wait_for_tasks` (or ends its turn: Cherry types one line into its tab
// once the run settled) and reads results with `get_task`. Task records
// live in the app's memory (docs/mcp.md, Tasks and results).

extension CherryControl {
    /// The longest `wait_for_tasks` call, as `wait_for_events`.
    public static let maximumTaskWaitMilliseconds = 50_000
    /// A result's `summary`, in characters; a longer one is cut.
    public static let maximumTaskSummaryCharacters = 400
    /// A `report_progress` message, in characters; a longer one is cut.
    public static let maximumTaskProgressCharacters = 200
}

/// Any JSON value: a task's result and its schema.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        // A dictionary's keys are never converted by a key strategy (MCP
        // output is snake_case): a result's own keys stay as written.
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Parses JSON text (any value, not only an object).
    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// The value as compact JSON text (sorted keys).
    public var compactJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Its size as compact JSON, in bytes.
    public var encodedByteCount: Int { compactJSON.utf8.count }

    /// Its JSON Schema type name: `integer` for a whole number.
    public var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .int: "integer"
        case .double(let value): value.rounded() == value && value.isFinite ? "integer" : "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The number, for either kind.
    var numberValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    /// Equal as JSON: numbers compare by value (1 equals 1.0).
    public func isJSONEqual(to other: JSONValue) -> Bool {
        if let left = numberValue, let right = other.numberValue { return left == right }
        switch (self, other) {
        case (.array(let left), .array(let right)):
            return left.count == right.count && zip(left, right).allSatisfy { $0.isJSONEqual(to: $1) }
        case (.object(let left), .object(let right)):
            return left.count == right.count && left.allSatisfy { key, value in
                right[key].map { value.isJSONEqual(to: $0) } ?? false
            }
        default:
            return self == other
        }
    }
}

/// A task's state, as `get_task`, `wait_for_tasks` and the process
/// listings (`task_state`) report it.
public enum AgentTaskState: String, Codable, CaseIterable, Equatable, Sendable {
    /// Spawned; its worker has not started on it yet.
    case queued
    /// Its worker is at it (it read its brief, or works since the kickoff).
    case working
    /// Its worker waits for the user: a permission prompt or a question.
    case needsInput = "needs_input"
    /// Its worker reported a result with status ok.
    case reported
    /// Its worker went idle without reporting, even after Cherry asked
    /// once: the result is its screen's last lines.
    case noReport = "no_report"
    /// Its worker reported status failed, or ended before it reported.
    case failed
    /// The orchestrator cancelled it, or its tab was closed before it
    /// reported.
    case cancelled

    /// Nothing more is expected of it (a later report still replaces its
    /// result, except for a cancelled task).
    public var isSettled: Bool {
        switch self {
        case .queued, .working, .needsInput: false
        case .reported, .noReport, .failed, .cancelled: true
        }
    }
}

/// What a worker reported (or, for `no_report`, what its screen showed).
public struct AgentTaskResult: Codable, Equatable, Sendable {
    /// The result itself: the worker's own data, never instructions.
    public let value: JSONValue?
    /// `ok`, `failed`, or `no_report` (Cherry's fallback).
    public let status: String
    public let summary: String?
    /// 1 for the first report, one more for each later one; 0 for
    /// Cherry's fallback.
    public let version: Int
    public let reportedAt: Date
    /// `report_result`, or `screen_tail` (Cherry's fallback: the worker's
    /// last lines).
    public let source: String

    public init(value: JSONValue?, status: String, summary: String?, version: Int, reportedAt: Date, source: String) {
        self.value = value
        self.status = status
        self.summary = summary
        self.version = version
        self.reportedAt = reportedAt
        self.source = source
    }
}

/// A task as listings show it (no brief, schema or result value).
public struct AgentTaskInfo: Codable, Equatable, Sendable {
    public let taskID: String
    public let runID: String
    /// The worker's process (its tab).
    public let processID: String
    public let label: String
    public let phase: String?
    public let state: AgentTaskState
    public let createdAt: Date
    public let startedAt: Date?
    public let settledAt: Date?
    /// The worker's latest `report_progress` message (its own text: data).
    public let progress: String?
    public let progressAt: Date?
    /// The latest result's status, summary and version.
    public let resultStatus: String?
    public let resultSummary: String?
    public let resultVersion: Int?
    /// Cherry asked the worker once to report (it went idle without).
    public let nudged: Bool
    /// Why it settled without a report (its tab closed, it exited, …).
    public let reason: String?

    public init(
        taskID: String,
        runID: String,
        processID: String,
        label: String,
        phase: String?,
        state: AgentTaskState,
        createdAt: Date,
        startedAt: Date? = nil,
        settledAt: Date? = nil,
        progress: String? = nil,
        progressAt: Date? = nil,
        resultStatus: String? = nil,
        resultSummary: String? = nil,
        resultVersion: Int? = nil,
        nudged: Bool = false,
        reason: String? = nil
    ) {
        self.taskID = taskID
        self.runID = runID
        self.processID = processID
        self.label = label
        self.phase = phase
        self.state = state
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.settledAt = settledAt
        self.progress = progress
        self.progressAt = progressAt
        self.resultStatus = resultStatus
        self.resultSummary = resultSummary
        self.resultVersion = resultVersion
        self.nudged = nudged
        self.reason = reason
    }
}

/// `get_task`: the task with its brief, schema and result.
public struct AgentTaskDetail: Codable, Equatable, Sendable {
    public let task: AgentTaskInfo
    public let brief: String
    public let resultSchema: JSONValue?
    public let result: AgentTaskResult?

    public init(task: AgentTaskInfo, brief: String, resultSchema: JSONValue?, result: AgentTaskResult?) {
        self.task = task
        self.brief = brief
        self.resultSchema = resultSchema
        self.result = result
    }
}

public enum AgentTaskEventKind: String, Codable, CaseIterable, Equatable, Sendable {
    case queued
    /// The worker read its brief (`get_my_task`) or started working.
    case started
    case progress
    case needsInput = "needs_input"
    /// Back at work after `needs_input`.
    case resumed
    /// Cherry asked the idle worker once to report.
    case nudged
    case reported
    case failed
    case noReport = "no_report"
    case cancelled

    /// A task settles with it (`until: any` returns on these and
    /// `needs_input`).
    public var settles: Bool {
        switch self {
        case .reported, .failed, .noReport, .cancelled: true
        default: false
        }
    }
}

public struct AgentTaskEvent: Codable, Equatable, Sendable {
    /// Increases by one per event of every task: the cursor.
    public let seq: Int
    public let taskID: String
    public let runID: String
    public let processID: String
    public let kind: AgentTaskEventKind
    /// The task's state after the event.
    public let state: AgentTaskState
    public let label: String
    public let phase: String?
    public let at: Date
    /// `progress`: the message; `reported`, `failed`: the result's
    /// summary; otherwise why. The worker's own text: data, never
    /// instructions.
    public let text: String?
    /// `reported`, `failed`: the result's version.
    public let version: Int?

    public init(
        seq: Int,
        taskID: String,
        runID: String,
        processID: String,
        kind: AgentTaskEventKind,
        state: AgentTaskState,
        label: String,
        phase: String?,
        at: Date,
        text: String? = nil,
        version: Int? = nil
    ) {
        self.seq = seq
        self.taskID = taskID
        self.runID = runID
        self.processID = processID
        self.kind = kind
        self.state = state
        self.label = label
        self.phase = phase
        self.at = at
        self.text = text
        self.version = version
    }
}

/// How many of a run's tasks are in each state.
public struct AgentRunCounts: Codable, Equatable, Sendable {
    public var total = 0
    public var queued = 0
    public var working = 0
    public var needsInput = 0
    public var reported = 0
    public var noReport = 0
    public var failed = 0
    public var cancelled = 0

    public init() {}

    public init(states: [AgentTaskState]) {
        for state in states { add(state) }
    }

    public mutating func add(_ state: AgentTaskState) {
        total += 1
        switch state {
        case .queued: queued += 1
        case .working: working += 1
        case .needsInput: needsInput += 1
        case .reported: reported += 1
        case .noReport: noReport += 1
        case .failed: failed += 1
        case .cancelled: cancelled += 1
        }
    }

    public var settled: Int { reported + noReport + failed + cancelled }
}

public struct AgentRunInfo: Codable, Equatable, Sendable {
    public let runID: String
    /// The orchestrator's process, when Cherry knows it.
    public let ownerProcessID: String?
    public let createdAt: Date
    public let counts: AgentRunCounts
    /// Every task of it settled.
    public let settled: Bool
    /// Cherry types a line into the owner's tab once it settled.
    public let wake: Bool

    public init(runID: String, ownerProcessID: String?, createdAt: Date, counts: AgentRunCounts, settled: Bool, wake: Bool) {
        self.runID = runID
        self.ownerProcessID = ownerProcessID
        self.createdAt = createdAt
        self.counts = counts
        self.settled = settled
        self.wake = wake
    }
}

// MARK: Worker side

/// `get_my_task`: the caller's own tab's task.
public struct GetMyTaskResult: Codable, Equatable, Sendable {
    public let taskID: String
    public let runID: String
    public let label: String
    public let phase: String?
    public let brief: String
    public let resultSchema: JSONValue?
    public let rules: [String]
    public let state: AgentTaskState
    /// The latest result's version, 0 before the first report.
    public let resultVersion: Int

    public init(
        taskID: String,
        runID: String,
        label: String,
        phase: String?,
        brief: String,
        resultSchema: JSONValue?,
        rules: [String],
        state: AgentTaskState,
        resultVersion: Int
    ) {
        self.taskID = taskID
        self.runID = runID
        self.label = label
        self.phase = phase
        self.brief = brief
        self.resultSchema = resultSchema
        self.rules = rules
        self.state = state
        self.resultVersion = resultVersion
    }
}

public struct ReportResultRequest: Codable, Equatable, Sendable {
    public let value: JSONValue?
    /// `ok` (the default) or `failed`.
    public let status: String?
    public let summary: String?

    public init(value: JSONValue? = nil, status: String? = nil, summary: String? = nil) {
        self.value = value
        self.status = status
        self.summary = summary
    }
}

public struct ReportResultResult: Codable, Equatable, Sendable {
    public let taskID: String
    public let runID: String
    public let version: Int
    public let state: AgentTaskState
    /// The summary was longer than `maximumTaskSummaryCharacters` and cut.
    public let summaryTruncated: Bool

    public init(taskID: String, runID: String, version: Int, state: AgentTaskState, summaryTruncated: Bool) {
        self.taskID = taskID
        self.runID = runID
        self.version = version
        self.state = state
        self.summaryTruncated = summaryTruncated
    }
}

public struct ReportProgressRequest: Codable, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public struct ReportProgressResult: Codable, Equatable, Sendable {
    public let taskID: String
    /// False when the last message was recorded too recently.
    public let recorded: Bool
    /// When not recorded: how long until the next one is.
    public let retryAfterMilliseconds: Int?

    public init(taskID: String, recorded: Bool, retryAfterMilliseconds: Int? = nil) {
        self.taskID = taskID
        self.recorded = recorded
        self.retryAfterMilliseconds = retryAfterMilliseconds
    }
}

// MARK: Orchestrator side

public struct WaitForTasksRequest: Codable, Equatable, Sendable {
    public let runID: String?
    public let taskIDs: [String]?
    /// `any` (the default: a task settled or needs input) or `all`.
    public let until: String?
    /// Events after this seq are returned. Nil: from the first.
    public let cursor: Int?
    /// At most `CherryControl.maximumTaskWaitMilliseconds`; 0 returns at once.
    public let timeoutMilliseconds: Int?
    public let maxEvents: Int?

    public init(
        runID: String? = nil,
        taskIDs: [String]? = nil,
        until: String? = nil,
        cursor: Int? = nil,
        timeoutMilliseconds: Int? = nil,
        maxEvents: Int? = nil
    ) {
        self.runID = runID
        self.taskIDs = taskIDs
        self.until = until
        self.cursor = cursor
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maxEvents = maxEvents
    }
}

public struct WaitForTasksResult: Codable, Equatable, Sendable {
    public let events: [AgentTaskEvent]
    /// The selected tasks that settled.
    public let completed: [AgentTaskInfo]
    /// The selected tasks still open.
    public let pending: [AgentTaskInfo]
    /// Pass it as `cursor` next time.
    public let cursor: Int
    public let timedOut: Bool
    /// Events after these (more than `max_events`).
    public let moreEvents: Int
    /// Some events after `cursor` were no longer kept.
    public let eventsDropped: Bool
    public let runs: [AgentRunInfo]

    public init(
        events: [AgentTaskEvent],
        completed: [AgentTaskInfo],
        pending: [AgentTaskInfo],
        cursor: Int,
        timedOut: Bool,
        moreEvents: Int,
        eventsDropped: Bool,
        runs: [AgentRunInfo]
    ) {
        self.events = events
        self.completed = completed
        self.pending = pending
        self.cursor = cursor
        self.timedOut = timedOut
        self.moreEvents = moreEvents
        self.eventsDropped = eventsDropped
        self.runs = runs
    }
}

public struct GetTaskRequest: Codable, Equatable, Sendable {
    public let taskID: String

    public init(taskID: String) {
        self.taskID = taskID
    }
}

public struct ListTasksRequest: Codable, Equatable, Sendable {
    public let runID: String?
    /// An `AgentTaskState` raw value.
    public let state: String?

    public init(runID: String? = nil, state: String? = nil) {
        self.runID = runID
        self.state = state
    }
}

public struct ListTasksResult: Codable, Equatable, Sendable {
    public let runs: [AgentRunInfo]
    public let tasks: [AgentTaskInfo]

    public init(runs: [AgentRunInfo], tasks: [AgentTaskInfo]) {
        self.runs = runs
        self.tasks = tasks
    }
}

public struct CancelTasksRequest: Codable, Equatable, Sendable {
    public let runID: String?
    public let taskIDs: [String]?
    /// Also close the workers' tabs (settled tasks' too).
    public let close: Bool?

    public init(runID: String? = nil, taskIDs: [String]? = nil, close: Bool? = nil) {
        self.runID = runID
        self.taskIDs = taskIDs
        self.close = close
    }
}

public struct CancelTasksResult: Codable, Equatable, Sendable {
    public let cancelled: [String]
    /// Tasks whose worker's tab was closed.
    public let closed: [String]
    /// Tasks that had settled already (their result stays).
    public let alreadySettled: [String]

    public init(cancelled: [String], closed: [String], alreadySettled: [String]) {
        self.cancelled = cancelled
        self.closed = closed
        self.alreadySettled = alreadySettled
    }
}

// MARK: - Result schemas

/// The JSON Schema subset Cherry checks a task's result against:
/// `type` (a name or a list of them: object, array, string, number,
/// integer, boolean, null), `properties`, `required`, `items` (one schema
/// for every element), `enum`, and `additionalProperties` (true, false or
/// a schema). `description`, `title`, `$schema`, `default` and `examples`
/// are allowed and ignored; any other keyword is refused when the task is
/// made (`lint`), so nothing the worker must meet goes unchecked; so is an
/// `enum` of more than `maximumEnumValues` values.
public enum TaskResultSchema {
    public static let checkedKeywords: Set<String> = ["type", "properties", "required", "items", "enum", "additionalProperties"]
    public static let ignoredKeywords: Set<String> = ["description", "title", "$schema", "default", "examples"]
    public static let typeNames: Set<String> = ["object", "array", "string", "number", "integer", "boolean", "null"]
    /// The largest schema, as compact JSON.
    public static let maximumEncodedBytes = 64 * 1024
    public static let maximumDepth = 32
    /// At most this many problems are listed.
    public static let maximumErrors = 20
    /// The longest `enum` list.
    public static let maximumEnumValues = 256

    /// What is wrong with `schema` itself; empty when Cherry can check
    /// values against it.
    public static func lint(_ schema: JSONValue) -> [String] {
        var errors: [String] = []
        if schema.encodedByteCount > maximumEncodedBytes {
            return ["$: the schema is larger than \(maximumEncodedBytes) bytes"]
        }
        lint(schema, path: "$", depth: 0, errors: &errors)
        return Array(errors.prefix(maximumErrors))
    }

    private static func lint(_ schema: JSONValue, path: String, depth: Int, errors: inout [String]) {
        guard errors.count < maximumErrors else { return }
        guard depth <= maximumDepth else {
            errors.append("\(path): nested more than \(maximumDepth) levels")
            return
        }
        // `true` takes anything, `false` nothing.
        if case .bool = schema { return }
        guard case .object(let object) = schema else {
            errors.append("\(path): a schema is an object (or true or false), not \(schema.typeName)")
            return
        }
        for key in object.keys.sorted() where !checkedKeywords.contains(key) && !ignoredKeywords.contains(key) {
            errors.append("\(path): \(key) is not supported (Cherry checks type, properties, required, items, enum and additionalProperties)")
        }
        if let type = object["type"] {
            switch type {
            case .string(let name):
                if !typeNames.contains(name) { errors.append("\(path).type: unknown type \(name)") }
            case .array(let names) where !names.isEmpty:
                for name in names {
                    guard let name = name.stringValue, typeNames.contains(name) else {
                        errors.append("\(path).type: unknown type \(name.compactJSON)")
                        continue
                    }
                }
            default:
                errors.append("\(path).type: a type name or a non-empty list of them")
            }
        }
        if let properties = object["properties"] {
            if case .object(let map) = properties {
                for key in map.keys.sorted() {
                    lint(map[key] ?? .null, path: path + ".properties" + member(key), depth: depth + 1, errors: &errors)
                }
            } else {
                errors.append("\(path).properties: an object of schemas")
            }
        }
        if let required = object["required"] {
            if !(required.arrayValue?.allSatisfy { $0.stringValue != nil } ?? false) {
                errors.append("\(path).required: a list of property names")
            }
        }
        if let items = object["items"] {
            if case .array = items {
                errors.append("\(path).items: one schema for every element (a list of schemas is not supported)")
            } else {
                lint(items, path: path + ".items", depth: depth + 1, errors: &errors)
            }
        }
        if let values = object["enum"] {
            let count = values.arrayValue?.count ?? 0
            if count == 0 {
                errors.append("\(path).enum: a non-empty list of values")
            } else if count > maximumEnumValues {
                errors.append("\(path).enum: at most \(maximumEnumValues) values (it has \(count))")
            }
        }
        if let additional = object["additionalProperties"] {
            switch additional {
            case .bool: break
            case .object: lint(additional, path: path + ".additionalProperties", depth: depth + 1, errors: &errors)
            default: errors.append("\(path).additionalProperties: true, false or a schema")
            }
        }
    }

    /// The most work `validate` does (about one step per value and schema
    /// node it looks at): a value too large to check within it fails.
    public static let defaultValidationBudget = 2_000_000

    /// Where `value` does not match `schema` (a schema `lint` accepts):
    /// empty when it matches; at most `maximumErrors` problems, each with
    /// its path (`$.findings[2].severity`). Linear in the value's size
    /// (`enum` values are looked up, not compared one by one), and it stops
    /// after `budget` steps. Pure: callers run it off the main thread.
    public static func validate(_ value: JSONValue, against schema: JSONValue, budget: Int = defaultValidationBudget) -> [String] {
        var validator = Validator(budget: budget)
        validator.validate(value, CompiledSchema(schema), path: "$")
        if validator.exhausted {
            validator.errors = Array(validator.errors.prefix(maximumErrors - 1))
            validator.errors.append("$: the value is too large to check against the schema; report a smaller one (put details in a file)")
        }
        return Array(validator.errors.prefix(maximumErrors))
    }

    /// A schema made ready to check against: its type names, its `enum`
    /// as a set of canonical keys, its properties and items compiled.
    private final class CompiledSchema {
        enum Kind {
            case any
            case none
            case object
        }

        let kind: Kind
        var types: [String] = []
        var enumKeys: Set<String>?
        var enumListing = ""
        var required: [String] = []
        var properties: [String: CompiledSchema] = [:]
        var items: CompiledSchema?
        /// nil: any extra property; `.none` kind: none allowed.
        var additional: CompiledSchema?

        init(_ schema: JSONValue) {
            switch schema {
            case .bool(true): kind = .any
            case .bool(false): kind = .none
            case .object(let object):
                kind = .object
                if let type = object["type"] {
                    types = type.stringValue.map { [$0] } ?? (type.arrayValue ?? []).compactMap(\.stringValue)
                }
                if let options = object["enum"]?.arrayValue {
                    var keys = Set<String>()
                    var steps = 0
                    for option in options { keys.insert(TaskResultSchema.canonicalKey(option, steps: &steps)) }
                    enumKeys = keys
                    let listed = options.prefix(20).map(\.compactJSON).joined(separator: ", ")
                    enumListing = listed.count > 200 || options.count > 20 ? String(listed.prefix(200)) + "…" : listed
                }
                required = (object["required"]?.arrayValue ?? []).compactMap(\.stringValue)
                for (key, property) in object["properties"]?.objectValue ?? [:] {
                    properties[key] = CompiledSchema(property)
                }
                items = object["items"].map(CompiledSchema.init)
                additional = object["additionalProperties"].map(CompiledSchema.init)
            default: kind = .any
            }
        }
    }

    private struct Validator {
        let budget: Int
        var steps = 0
        var errors: [String] = []
        var exhausted: Bool { steps > budget }

        init(budget: Int) {
            self.budget = budget
        }

        mutating func validate(_ value: JSONValue, _ schema: CompiledSchema, path: @autoclosure () -> String) {
            steps += 1
            guard errors.count < TaskResultSchema.maximumErrors, !exhausted else { return }
            switch schema.kind {
            case .any: return
            case .none:
                errors.append("\(path()): no value is allowed here")
                return
            case .object: break
            }
            if !schema.types.isEmpty, !schema.types.contains(where: { TaskResultSchema.matches(value, type: $0) }) {
                errors.append("\(path()): expected \(schema.types.joined(separator: " or ")), got \(value.typeName)")
                return
            }
            if let keys = schema.enumKeys {
                let key = TaskResultSchema.canonicalKey(value, steps: &steps)
                if !keys.contains(key) {
                    errors.append("\(path()): expected one of [\(schema.enumListing)], got \(TaskResultSchema.clipped(value))")
                }
            }
            if case .object(let fields) = value {
                for key in schema.required where fields[key] == nil {
                    errors.append("\(path()): missing required property \(key)")
                }
                let base = path()
                for key in fields.keys.sorted() {
                    guard let field = fields[key], !exhausted else { continue }
                    if let property = schema.properties[key] {
                        validate(field, property, path: base + TaskResultSchema.member(key))
                    } else if let additional = schema.additional {
                        if additional.kind == .none {
                            errors.append("\(base): property \(key) is not allowed")
                        } else {
                            validate(field, additional, path: base + TaskResultSchema.member(key))
                        }
                    }
                }
            }
            if case .array(let elements) = value, let items = schema.items {
                let base = path()
                for (index, element) in elements.enumerated() where !exhausted && errors.count < TaskResultSchema.maximumErrors {
                    validate(element, items, path: "\(base)[\(index)]")
                }
            }
        }
    }

    /// A key equal for values `isJSONEqual` takes as equal (numbers by
    /// value, object keys in any order), counting one step per node.
    static func canonicalKey(_ value: JSONValue, steps: inout Int) -> String {
        steps += 1
        switch value {
        case .null: return "n;"
        case .bool(let flag): return flag ? "t;" : "f;"
        case .int(let number): return "i\(number);"
        case .double(let number):
            if number.isFinite, number.rounded() == number, abs(number) < 9.0e15 { return "i\(Int(number));" }
            return "d\(number);"
        case .string(let text): return "s\(text.utf8.count):\(text)"
        case .array(let elements):
            var key = "["
            for element in elements { key += canonicalKey(element, steps: &steps) }
            return key + "]"
        case .object(let fields):
            var key = "{"
            for name in fields.keys.sorted() {
                key += "k\(name.utf8.count):\(name)" + canonicalKey(fields[name] ?? .null, steps: &steps)
            }
            return key + "}"
        }
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch type {
        case "null": value == .null
        case "boolean": if case .bool = value { true } else { false }
        case "string": value.stringValue != nil
        case "array": value.arrayValue != nil
        case "object": value.objectValue != nil
        case "number": value.numberValue != nil
        case "integer": value.typeName == "integer"
        default: false
        }
    }

    /// `.key`, or `["key"]` for a key that is not a plain name.
    private static func member(_ key: String) -> String {
        let plain = !key.isEmpty && key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
            && !(key.unicodeScalars.first.map { CharacterSet.decimalDigits.contains($0) } ?? true)
        return plain ? ".\(key)" : "[\(JSONValue.string(key).compactJSON)]"
    }

    private static func clipped(_ value: JSONValue) -> String {
        let text = value.compactJSON
        return text.count > 80 ? String(text.prefix(80)) + "…" : text
    }
}
