import CherryControl
import Foundation

/// Runs a parsed `cherry` invocation and says what it prints.
public enum CherryCLIRunner {
    public struct Outcome: Equatable, Sendable {
        public var standardOutput: String
        public var standardError: String
        public var exitCode: Int32
    }

    /// `invocation` through `call` (a `callTool` with interface "cli");
    /// `isTerminal` says whether standard output is a terminal, which gets
    /// the human form unless `--json`. `skillInstaller` places the skill's
    /// files on the caller's Mac; none (or none for a request) refuses
    /// `cherry skill setup|status|remove`. It runs on
    /// its caller's actor (the app's main actor), as `call` does.
    public static func run(
        _ invocation: CherryCLIInvocation,
        isTerminal: Bool,
        skillInstaller: ((CherrySkillRequest) -> CherrySkillInstaller?)? = nil,
        isolation: isolated (any Actor)? = #isolation,
        call: (String, [String: JSONValue]) async -> CallToolResult
    ) async -> Outcome {
        switch invocation.action {
        case .skill(let request):
            guard let installer = skillInstaller?(request) else {
                return Outcome(standardOutput: "", standardError: skillUnavailable(request) + "\n", exitCode: 1)
            }
            return runSkill(request, installer: installer, json: invocation.json || !isTerminal)
        case .print(let text):
            return Outcome(standardOutput: text.hasSuffix("\n") ? text : text + "\n", standardError: "", exitCode: 0)
        case .usage(let message):
            return Outcome(standardOutput: "", standardError: message + "\n", exitCode: 2)
        case .call(let tool, let arguments, let fallback):
            var result = await call(tool, arguments)
            if let fallback, result.isError, errorCode(of: result) == "not_agent_process" {
                result = await call(fallback.tool, fallback.arguments)
            }
            if result.isError {
                return Outcome(standardOutput: "", standardError: errorLine(of: result) + "\n", exitCode: 1)
            }
            let human = isTerminal && !invocation.json
            let text = human ? render(result.text, command: invocation.command) : result.text
            return Outcome(standardOutput: text.hasSuffix("\n") ? text : text + "\n", standardError: "", exitCode: 0)
        }
    }

    static func payload(_ text: String) -> JSONValue? {
        try? JSONValue.parse(Data(text.utf8))
    }

    static func errorCode(of result: CallToolResult) -> String? {
        payload(result.text)?.objectValue?["error"]?.objectValue?["code"]?.stringValue
    }

    /// `code: message`, then the error's details (a menu's options, a
    /// schema's problems) as JSON on the next line.
    static func errorLine(of result: CallToolResult) -> String {
        guard let error = payload(result.text)?.objectValue?["error"]?.objectValue else { return result.text }
        var line = "\(error["code"]?.stringValue ?? "error"): \(error["message"]?.stringValue ?? "")"
        let rest = error.filter { $0.key != "code" && $0.key != "message" }
        if !rest.isEmpty {
            line += "\n" + JSONValue.object(rest).compactJSON
        }
        return line
    }

    // MARK: Human output

    /// A short form of a result for a person at a terminal, else the JSON
    /// indented.
    static func render(_ text: String, command: [String]) -> String {
        guard let value = payload(text) else { return text }
        switch command {
        case ["ls"]:
            if let rows = firstArray(in: value) { return table(rows) }
        case ["read"]:
            if let lines = lines(in: value) { return lines.joined(separator: "\n") }
        case ["show"]:
            if let process = value.objectValue?["process"]?.objectValue ?? value.objectValue {
                return fields(process, keys: ["name", "id", "kind", "state", "agent_activity_state", "task_id", "task_state", "label", "result_summary"])
            }
        case ["task", "mine"]:
            if let task = value.objectValue?["task"]?.objectValue, let brief = task["brief"]?.stringValue {
                return "Task \(task["id"]?.stringValue ?? task["task_id"]?.stringValue ?? "")\n\n\(brief)"
            }
        case ["task", "list"]:
            if let rows = firstArray(in: value) { return table(rows) }
        case ["devices"]:
            if let devices = value.objectValue?["devices"]?.arrayValue?.compactMap(\.objectValue) {
                return devices.map { device in
                    let you = device["caller"] == .bool(true) ? ", you are here" : ""
                    let header = "\(string(device["name"])) (\(string(device["id"]))): \(string(device["os"]))\(you)"
                    let projects = (device["projects"]?.arrayValue ?? []).compactMap(\.objectValue).map { project in
                        "  \(string(project["path"]))" + (project["open"] == .bool(true) ? "  (open)" : "")
                    }
                    return ([header] + projects).joined(separator: "\n")
                }.joined(separator: "\n")
            }
        case ["project", "add"]:
            if let object = value.objectValue {
                return fields(object, keys: ["project_root", "device", "path", "created", "already_added", "opened"])
            }
        default:
            break
        }
        return pretty(value)
    }

    static func pretty(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return value.compactJSON }
        return String(decoding: data, as: UTF8.self)
    }

    static func firstArray(in value: JSONValue) -> [[String: JSONValue]]? {
        if let array = value.arrayValue { return array.compactMap(\.objectValue) }
        guard let object = value.objectValue else { return nil }
        for key in object.keys.sorted() {
            if let array = object[key]?.arrayValue, array.allSatisfy({ $0.objectValue != nil }) {
                return array.compactMap(\.objectValue)
            }
        }
        return nil
    }

    static func lines(in value: JSONValue) -> [String]? {
        guard let object = value.objectValue else { return nil }
        if let lines = object["lines"]?.arrayValue { return lines.compactMap(\.stringValue) }
        if let output = object["output"] { return self.lines(in: output) }
        return nil
    }

    static func string(_ value: JSONValue?) -> String {
        switch value {
        case .string(let text)?: text
        case .int(let number)?: String(number)
        case .double(let number)?: String(number)
        case .bool(let flag)?: flag ? "yes" : "no"
        default: ""
        }
    }

    static func fields(_ object: [String: JSONValue], keys: [String]) -> String {
        keys.compactMap { key in
            let text = string(object[key])
            return text.isEmpty ? nil : "\(key): \(text)"
        }.joined(separator: "\n")
    }

    static func table(_ rows: [[String: JSONValue]]) -> String {
        guard !rows.isEmpty else { return "(none)" }
        let preferred = ["id", "task_id", "name", "label", "kind", "state", "agent_activity_state", "task_state", "selected"]
        let columns = preferred.filter { key in rows.contains { !string($0[key]).isEmpty } }
        let cells = rows.map { row in columns.map { string(row[$0]) } }
        let widths = columns.indices.map { index in
            max(columns[index].count, cells.map { $0[index].count }.max() ?? 0)
        }
        func line(_ values: [String]) -> String {
            zip(values, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }
                .joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }
        return ([line(columns.map { $0.uppercased() })] + cells.map(line)).joined(separator: "\n")
    }
}
