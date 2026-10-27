import CherryControl
import Foundation

// MARK: - The `cherry` agent commands
//
// `cherry ls`, `cherry send ID <<'EOF'`, `cherry task report` …: the agent
// commands of `cherry` (docs/specs/agent-cli.md). The Rust `cherry` keeps
// the session host's commands (`cherry host …`) and sends every other one
// to the app as a `runCommand` request, which the app parses here and runs
// as its caller (`CherryControlServer.handleCommand`). Each command is one
// catalog tool, called as a `callTool` is (interface "cli"), so the
// caller's identity, scoping and errors are the tools'.
//
// A command's words and positional arguments are in `CherryCLI.commands`;
// every other `--flag` is the tool's own parameter in kebab case
// (`--line-limit 50` is `line_limit`), typed by the tool's schema. Long
// text (a brief, a message, a report, a schema) also comes on standard
// input: `-`, or nothing with standard input a pipe or a file.

/// What one `cherry` invocation does.
public enum CherryCLIAction: Equatable, Sendable {
    /// Call `tool` with `arguments`; when the app answers
    /// `not_agent_process`, call `fallback` instead (`cherry send` to a
    /// terminal or command).
    case call(tool: String, arguments: [String: JSONValue], fallback: CherryCLIFallback? = nil)
    /// Print `text` and exit 0 (help, the guide).
    case print(String)
    /// Print `message` and a usage line on standard error, exit 2.
    case usage(String)
    /// `cherry skill setup|status|remove`: the skill's files on this Mac.
    case skill(CherrySkillRequest)
}

/// `cherry skill setup|status|remove [--agent A]… [--dry-run] [--project]
/// [--force]`.
public struct CherrySkillRequest: Equatable, Sendable {
    public enum Operation: String, Sendable {
        case setup
        case status
        case remove
    }

    public var operation: Operation
    /// nil: every agent (setup: those found).
    public var agents: [CherrySkillAgent]?
    public var dryRun = false
    public var project = false
    public var force = false
}

public struct CherryCLIFallback: Equatable, Sendable {
    public let tool: String
    public let arguments: [String: JSONValue]
}

/// One parsed invocation: what it does, and whether its output is JSON.
public struct CherryCLIInvocation: Equatable, Sendable {
    public var action: CherryCLIAction
    /// `--json`: the tool's JSON even on a terminal.
    public var json: Bool
    /// The command's words (`["task", "report"]`), for the human output.
    public var command: [String]
}

/// Standard input as the parser sees it, injected by tests.
public struct CherryCLIInput: Sendable {
    /// Standard input is a pipe or a file, which a missing text argument
    /// reads (never a terminal, nor `/dev/null`, which is a device).
    public var hasPipedInput: Bool
    /// Reads all of standard input once.
    public var read: @Sendable () -> String?
    /// Reads a file argument (`--schema schema.json`).
    public var readFile: @Sendable (String) -> String?

    public init(
        hasPipedInput: Bool,
        read: @escaping @Sendable () -> String?,
        readFile: @escaping @Sendable (String) -> String? = { _ in nil }
    ) {
        self.hasPipedInput = hasPipedInput
        self.read = read
        self.readFile = readFile
    }

    /// No standard input (tests).
    public static let none = CherryCLIInput(hasPipedInput: false, read: { nil })
}

public enum CherryCLI {
    // MARK: Commands

    /// A positional argument of a command.
    enum Positional: Equatable {
        /// A process ID or name (`process_id` for a UUID, else
        /// `process_name`); optional ones default to the caller's tab.
        case process(optional: Bool)
        /// One string parameter.
        case value(String, optional: Bool = false)
        /// A string parameter that may come on standard input instead.
        case text(String, optional: Bool = false)
        /// The rest of the words, as an array parameter.
        case rest(String)
        /// Key names typed as raw bytes (`cherry keys`).
        case keys
        /// The report's value (and its status and summary), JSON.
        case report
        /// A JSON object of the tool's arguments (`cherry tool NAME`).
        case toolArguments
    }

    /// A flag of a command that is not its tool's parameter by name.
    struct Alias: Equatable {
        let flag: String
        let parameter: String
        /// `--no-wait` sets `wait_for_idle` false.
        var inverted = false
    }

    struct Command {
        let words: [String]
        let tool: String
        var positionals: [Positional] = []
        var fixed: [String: JSONValue] = [:]
        var aliases: [Alias] = []
        /// For `cherry send`: the call made when the process is not an agent.
        var fallbackTool: String? = nil
        let usage: String
        let summary: String
    }

    static let timeout = Alias(flag: "timeout", parameter: "timeout_ms")

    static let commands: [Command] = [
        Command(words: ["ls"], tool: "list_processes", usage: "cherry ls [--kind agent|terminal|command]",
                summary: "List the project's tabs: terminals, agents and commands."),
        Command(words: ["show"], tool: "get_process_status", positionals: [.process(optional: true)],
                usage: "cherry show [ID]", summary: "A tab's status (your own without ID)."),
        Command(words: ["read"], tool: "get_process_output", positionals: [.process(optional: true)],
                aliases: [Alias(flag: "lines", parameter: "line_limit"), Alias(flag: "from", parameter: "start_line")],
                usage: "cherry read [ID] [--lines N] [--from LINE]", summary: "A tab's output, the last lines by default."),
        Command(words: ["search"], tool: "search_process_output", positionals: [.process(optional: false), .value("query")],
                usage: "cherry search ID PATTERN", summary: "Search a tab's output."),
        Command(words: ["wait"], tool: "wait_for_process_idle", positionals: [.process(optional: true)],
                aliases: [timeout, Alias(flag: "quiet", parameter: "quiet_ms")],
                usage: "cherry wait [ID] [--timeout MS]", summary: "Wait until a tab printed output and went quiet (an agent: idle)."),
        Command(words: ["send"], tool: "send_agent_message", positionals: [.process(optional: false), .text("message")],
                aliases: [timeout, Alias(flag: "quiet", parameter: "quiet_ms"), Alias(flag: "wait", parameter: "wait_for_idle")],
                fallbackTool: "send_process_input",
                usage: "cherry send ID [TEXT | -] [--no-wait]",
                summary: "Message an agent (or type a line into a terminal); several lines arrive as one message."),
        Command(words: ["keys"], tool: "send_process_input", positionals: [.process(optional: false), .keys],
                fixed: ["submit": .bool(false)],
                usage: "cherry keys ID KEY…", summary: "Press keys: up down left right enter esc tab space backspace ctrl-c, a character…"),
        Command(words: ["answer"], tool: "answer_prompt", positionals: [.process(optional: false), .value("choice")],
                usage: "cherry answer ID CHOICE", summary: "Pick an option of an agent's permission or question menu (number or label)."),
        Command(words: ["spawn", "agent"], tool: "spawn_agent", positionals: [.value("name")],
                aliases: [Alias(flag: "schema", parameter: "result_schema"), Alias(flag: "run", parameter: "run_id")],
                usage: "cherry spawn agent NAME [--task - | --message -] [--label L] [--phase P] [--schema FILE|-] [--run RUN] [--allow-subagents] [--project-root DIR]",
                summary: "Start a configured agent; with --task it is a worker of yours."),
        Command(words: ["spawn", "terminal"], tool: "spawn_process", positionals: [.text("text", optional: true)],
                fixed: ["kind": .string("terminal")],
                usage: "cherry spawn terminal [TEXT] [--title T] [--working-directory DIR]", summary: "Open a terminal tab, typing TEXT into it."),
        Command(words: ["spawn", "command"], tool: "spawn_process", positionals: [.value("name")],
                fixed: ["kind": .string("command")],
                usage: "cherry spawn command NAME", summary: "Start one of the project's commands."),
        Command(words: ["start"], tool: "start_process", positionals: [.process(optional: true)],
                usage: "cherry start [ID]", summary: "Start a stopped tab."),
        Command(words: ["stop"], tool: "stop_process", positionals: [.process(optional: true)],
                usage: "cherry stop [ID]", summary: "Stop a tab's program."),
        Command(words: ["restart"], tool: "restart_process", positionals: [.process(optional: true)],
                usage: "cherry restart [ID]", summary: "Restart a tab's program."),
        Command(words: ["close"], tool: "close_process", positionals: [.process(optional: true)],
                aliases: [Alias(flag: "policy", parameter: "agent_close_policy")],
                usage: "cherry close [ID] [--policy close_sub_agents|promote_sub_agents]", summary: "Close a tab without asking."),
        Command(words: ["rename"], tool: "rename_process", positionals: [.process(optional: false), .value("title")],
                usage: "cherry rename ID TITLE", summary: "Rename a tab."),
        Command(words: ["select"], tool: "select_process", positionals: [.process(optional: false)],
                usage: "cherry select ID", summary: "Show a tab in Cherry's window (only when the user asks)."),
        Command(words: ["task", "mine"], tool: "get_my_task",
                usage: "cherry task mine", summary: "Your task's brief, if your tab is a worker."),
        Command(words: ["task", "report"], tool: "report_result", positionals: [.report],
                usage: "cherry task report [JSON | -] [--status ok|failed] [--summary TEXT]",
                summary: "Finish your task: {\"value\":…,\"status\":…,\"summary\":…}, or the value with --status/--summary."),
        Command(words: ["task", "progress"], tool: "report_progress", positionals: [.text("message")],
                usage: "cherry task progress MESSAGE [--awaiting-approval]",
                summary: "Tell your orchestrator how it goes; --awaiting-approval asks it and waits."),
        Command(words: ["task", "get"], tool: "get_task", positionals: [.value("task_id")],
                usage: "cherry task get TASK", summary: "A task's state and result."),
        Command(words: ["task", "list"], tool: "list_tasks",
                aliases: [Alias(flag: "run", parameter: "run_id")],
                usage: "cherry task list [--run RUN] [--state STATE]", summary: "Your runs' tasks."),
        Command(words: ["task", "wait"], tool: "wait_for_tasks", positionals: [.value("run_id", optional: true)],
                aliases: [timeout],
                usage: "cherry task wait [RUN] [--cursor N] [--until any|all] [--timeout MS]",
                summary: "Wait for your workers' events; call again with the cursor on timed_out."),
        Command(words: ["task", "cancel"], tool: "cancel_tasks", positionals: [.rest("task_ids")],
                aliases: [Alias(flag: "run", parameter: "run_id")],
                usage: "cherry task cancel [TASK…] [--run RUN] [--close]",
                summary: "Cancel open tasks; --close also closes their workers' tabs."),
        Command(words: ["subscribe"], tool: "subscribe", positionals: [.rest("process_ids")],
                aliases: [Alias(flag: "pattern", parameter: "output_pattern")],
                usage: "cherry subscribe [ID…] [--sub-agents] [--events done,needs_input,…] [--wake]",
                summary: "Watch tabs for events; with --wake Cherry types a line into your tab when you are idle."),
        Command(words: ["events"], tool: "wait_for_events", positionals: [.value("subscription_id")],
                aliases: [timeout],
                usage: "cherry events SUBSCRIPTION [--cursor N] [--timeout MS]", summary: "Read a subscription's events."),
        Command(words: ["unsubscribe"], tool: "unsubscribe", positionals: [.value("subscription_id")],
                usage: "cherry unsubscribe SUBSCRIPTION", summary: "End a subscription."),
        Command(words: ["subscriptions"], tool: "list_subscriptions",
                usage: "cherry subscriptions", summary: "Your subscriptions."),
        Command(words: ["ports"], tool: "get_process_ports", positionals: [.process(optional: true)],
                usage: "cherry ports [ID]", summary: "A tab's localhost TCP services."),
        Command(words: ["services"], tool: "services_list",
                usage: "cherry services [--kind KIND]", summary: "The project's localhost TCP services."),
        Command(words: ["wait-port"], tool: "wait_for_bound_port", positionals: [.process(optional: true)],
                aliases: [timeout],
                usage: "cherry wait-port [ID] [--port N] [--probe-http] [--timeout MS]", summary: "Wait for a tab's service to listen."),
        Command(words: ["todo", "ls"], tool: "list_todos",
                usage: "cherry todo ls", summary: "The project's todos."),
        Command(words: ["todo", "show"], tool: "get_todo", positionals: [.value("todo_id")],
                usage: "cherry todo show TODO", summary: "One todo."),
        Command(words: ["todo", "add"], tool: "create_todo", positionals: [.value("title"), .text("markdown", optional: true)],
                usage: "cherry todo add TITLE [MARKDOWN | -] [--status S] [--tags a,b]", summary: "Add a todo."),
        Command(words: ["todo", "edit"], tool: "update_todo", positionals: [.value("todo_id")],
                usage: "cherry todo edit TODO [--title T] [--markdown -] [--status S] [--tags a,b]", summary: "Change a todo."),
        Command(words: ["todo", "move"], tool: "move_todo", positionals: [.value("todo_id"), .value("status")],
                aliases: [Alias(flag: "after", parameter: "after_todo_id")],
                usage: "cherry todo move TODO STATUS [--after TODO]", summary: "Move a todo."),
        Command(words: ["todo", "rm"], tool: "delete_todo", positionals: [.value("todo_id")],
                usage: "cherry todo rm TODO", summary: "Delete a todo."),
        Command(words: ["todo", "select"], tool: "select_todo", positionals: [.value("todo_id")],
                usage: "cherry todo select TODO", summary: "Show a todo in Cherry (only when the user asks)."),
        Command(words: ["todo", "comment"], tool: "add_todo_comment", positionals: [.value("todo_id"), .text("markdown")],
                usage: "cherry todo comment TODO [MARKDOWN | -]", summary: "Comment on a todo."),
        Command(words: ["todo", "comments"], tool: "list_todo_comments", positionals: [.value("todo_id")],
                usage: "cherry todo comments TODO", summary: "A todo's comments."),
        Command(words: ["project", "ls"], tool: "list_projects",
                usage: "cherry project ls", summary: "Cherry's projects."),
        Command(words: ["project", "open"], tool: "open_project", positionals: [.value("project_root")],
                usage: "cherry project open ROOT [--device D]", summary: "Open a project's window (ROOT a path on device D)."),
        Command(words: ["project", "add"], tool: "add_project", positionals: [.value("path")],
                usage: "cherry project add PATH [--device D] [--create] [--open false]",
                summary: "Add a folder of a device (default: yours) as a project and open it; --create makes the folder."),
        Command(words: ["devices"], tool: "list_devices",
                usage: "cherry devices", summary: "This Mac and your other machines: names, connected, projects and their keys."),
        Command(words: ["project", "show"], tool: "get_project_status",
                usage: "cherry project show", summary: "The project's status."),
        Command(words: ["commands", "start"], tool: "start_all_commands",
                usage: "cherry commands start", summary: "Start the project's commands."),
        Command(words: ["commands", "stop"], tool: "stop_all_commands",
                usage: "cherry commands stop", summary: "Stop the project's commands."),
        Command(words: ["commands", "restart"], tool: "restart_all_commands",
                usage: "cherry commands restart", summary: "Restart the project's commands."),
        Command(words: ["agents"], tool: "list_agents",
                usage: "cherry agents", summary: "The configured agents spawn agent takes."),
        Command(words: ["link"], tool: "resolve_link", positionals: [.value("link")],
                usage: "cherry link LINK", summary: "Resolve a Cherry link to a todo or a tab."),
        Command(words: ["whoami"], tool: "whoami",
                usage: "cherry whoami", summary: "Which tab and project Cherry sees you as."),
        Command(words: ["tool"], tool: "", positionals: [.value("name"), .toolArguments],
                usage: "cherry tool NAME [JSON | -]", summary: "Call any Cherry tool with its MCP arguments."),
    ]

    /// The words that start a command, in the order help lists them.
    static var commandWords: [String] {
        var seen = Set<String>()
        return (commands.map { $0.words[0] } + ["skill", "help"]).filter { seen.insert($0).inserted }
    }

    // MARK: Parsing

    /// Parses `cherry`'s words (the program name left out) into what to do.
    public static func parse(_ arguments: [String], input: CherryCLIInput = .none) -> CherryCLIInvocation {
        var words = arguments
        var json = false
        if let index = words.firstIndex(of: "--json") {
            json = true
            words.remove(at: index)
        }
        func invocation(_ action: CherryCLIAction, _ command: [String] = []) -> CherryCLIInvocation {
            CherryCLIInvocation(action: action, json: json, command: command)
        }
        guard let first = words.first, first != "help", first != "--help", first != "-h" else {
            let topic = words.dropFirst().filter { !$0.hasPrefix("-") }
            return invocation(.print(help(for: Array(topic))))
        }
        if first == "skill" {
            return invocation(skillAction(Array(words.dropFirst())), ["skill"])
        }
        guard let command = command(for: words) else {
            if commands.contains(where: { $0.words[0] == first }) {
                let options = commands.filter { $0.words[0] == first }.map { $0.words[1] }
                return invocation(.usage("cherry \(first) needs one of: \(options.joined(separator: ", ")).\n"
                    + commands.filter { $0.words[0] == first }.map(\.usage).joined(separator: "\n")))
            }
            return invocation(.usage("cherry: unknown command \(first.debugDescription). Commands: \(commandWords.joined(separator: ", ")).\nRun cherry help, or cherry skill show for the guide."))
        }
        let rest = Array(words.dropFirst(command.words.count))
        if rest.contains("--help") || rest.contains("-h") {
            return invocation(.print(help(for: command.words)), command.words)
        }
        do {
            return invocation(try action(for: command, rest, input: input), command.words)
        } catch let error as UsageError {
            return invocation(.usage("\(error.message)\nusage: \(command.usage)"), command.words)
        } catch {
            return invocation(.usage("usage: \(command.usage)"), command.words)
        }
    }

    static func command(for words: [String]) -> Command? {
        commands
            .filter { $0.words.count <= words.count && Array(words.prefix($0.words.count)) == $0.words }
            .max { $0.words.count < $1.words.count }
    }

    struct UsageError: Error {
        let message: String
    }

    static func action(for command: Command, _ words: [String], input: CherryCLIInput) throws -> CherryCLIAction {
        var positional: [String] = []
        var flags: [(name: String, value: String?)] = []
        var index = 0
        var onlyPositional = false
        while index < words.count {
            let word = words[index]
            index += 1
            if onlyPositional || !word.hasPrefix("--") || word == "-" {
                positional.append(word)
                continue
            }
            if word == "--" {
                onlyPositional = true
                continue
            }
            let body = String(word.dropFirst(2))
            if let equals = body.firstIndex(of: "=") {
                flags.append((String(body[..<equals]), String(body[body.index(after: equals)...])))
            } else if index < words.count, !words[index].hasPrefix("--") || words[index] == "-" {
                flags.append((body, words[index]))
                index += 1
            } else {
                flags.append((body, nil))
            }
        }

        let tool = command.tool
        var arguments = command.fixed
        var toolName = tool
        var schema = parameterTypes(of: tool)
        var stdinUsed = false
        func readStandardInput() throws -> String {
            guard !stdinUsed else { throw UsageError(message: "Standard input can be read only once.") }
            stdinUsed = true
            guard let text = input.read() else { throw UsageError(message: "Could not read standard input.") }
            return text
        }

        var queue = positional[...]
        for slot in command.positionals {
            switch slot {
            case .process(let optional):
                guard let word = queue.popFirst() else {
                    if optional { continue }
                    throw UsageError(message: "Which tab? Give its ID or name.")
                }
                arguments.merge(processSelector(word)) { _, new in new }
            case .value(let name, let optional):
                guard let word = queue.popFirst() else {
                    if optional { continue }
                    throw UsageError(message: "Missing \(name.uppercased()).")
                }
                arguments[name] = .string(word)
            case .text(let name, let optional):
                if let word = queue.popFirst() {
                    arguments[name] = .string(word == "-" ? try readStandardInput() : word)
                } else if input.hasPipedInput, !flags.contains(where: { $0.name == name || $0.value == "-" }) {
                    arguments[name] = .string(try readStandardInput())
                } else if !optional, !flags.contains(where: { parameterName($0.name, command: command) == name }) {
                    throw UsageError(message: "Missing \(name.uppercased()): give it as an argument, or - to read standard input.")
                }
            case .rest(let name):
                let values = Array(queue)
                queue.removeAll()
                if !values.isEmpty { arguments[name] = .array(values.map(JSONValue.string)) }
            case .keys:
                let names = Array(queue)
                queue.removeAll()
                guard !names.isEmpty else { throw UsageError(message: "Which keys? For example: cherry keys ID down enter") }
                var bytes = Data()
                for name in names {
                    guard let key = keyBytes(name) else {
                        throw UsageError(message: "Unknown key \(name.debugDescription). Keys: \(keyNames.joined(separator: ", ")), ctrl-<letter>, or one character. To type text, use cherry send.")
                    }
                    bytes.append(key)
                }
                arguments["raw_base64"] = .string(bytes.base64EncodedString())
            case .report:
                let text: String? = if let word = queue.popFirst() {
                    word == "-" ? try readStandardInput() : word
                } else if input.hasPipedInput {
                    try readStandardInput()
                } else {
                    nil
                }
                let hasFlags = flags.contains { $0.name == "status" || $0.name == "summary" }
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard let value = try? JSONValue.parse(Data(text.utf8)) else {
                        throw UsageError(message: "The report is not JSON. Give {\"value\":…,\"status\":\"ok\",\"summary\":\"…\"}, or the value with --status and --summary.")
                    }
                    if !hasFlags, let object = value.objectValue, object["value"] != nil,
                       Set(object.keys).isSubset(of: ["value", "status", "summary"]) {
                        arguments.merge(object) { _, new in new }
                    } else {
                        arguments["value"] = value
                    }
                } else if !hasFlags {
                    throw UsageError(message: "Missing the report: JSON as an argument or on standard input.")
                }
            case .toolArguments:
                guard let name = arguments.removeValue(forKey: "name")?.stringValue else {
                    throw UsageError(message: "Which tool?")
                }
                toolName = name
                schema = parameterTypes(of: name)
                guard let word = queue.popFirst() ?? (input.hasPipedInput ? "-" : nil) else { continue }
                let text = word == "-" ? try readStandardInput() : word
                guard let object = (try? JSONValue.parse(Data(text.utf8)))?.objectValue else {
                    throw UsageError(message: "The arguments are not a JSON object; pass one in single quotes, for example: cherry tool \(name) '{\"kind\":\"agent\"}'")
                }
                arguments.merge(object) { _, new in new }
            }
        }
        if let extra = queue.first {
            throw UsageError(message: "Unexpected argument \(extra.debugDescription).")
        }

        for flag in flags {
            var name = flag.name
            var inverted = false
            if name.hasPrefix("no-") {
                name.removeFirst(3)
                inverted = true
            }
            if let alias = command.aliases.first(where: { $0.flag == name }) {
                name = alias.parameter
                inverted = inverted != alias.inverted
            } else {
                name = name.replacingOccurrences(of: "-", with: "_")
            }
            guard let type = schema[name] else {
                let known = schema.keys.sorted().map { "--" + $0.replacingOccurrences(of: "_", with: "-") }
                throw UsageError(message: "Unknown option --\(flag.name). Options: \((command.aliases.map { "--" + $0.flag } + known).joined(separator: " ")).")
            }
            arguments[name] = try value(of: flag.value, type: type, inverted: inverted, flag: flag.name, input: input, readStandardInput: readStandardInput)
        }

        if command.words == ["send"], arguments["message"] == nil {
            throw UsageError(message: "Missing the message: give it as an argument, or - to read standard input.")
        }
        let fallback: CherryCLIFallback? = command.fallbackTool.map { fallbackTool in
            var input = arguments.filter { ["process_id", "process_name", "line_limit"].contains($0.key) }
            input["text"] = arguments["message"]
            input["submit"] = .bool(true)
            return CherryCLIFallback(tool: fallbackTool, arguments: input)
        }
        return .call(tool: toolName, arguments: arguments, fallback: fallback)
    }

    /// A tab named on the command line: its ID, or its name.
    static func processSelector(_ word: String) -> [String: JSONValue] {
        UUID(uuidString: word) != nil ? ["process_id": .string(word.uppercased())] : ["process_name": .string(word)]
    }

    static func parameterName(_ flag: String, command: Command) -> String {
        command.aliases.first { $0.flag == flag }?.parameter ?? flag.replacingOccurrences(of: "-", with: "_")
    }

    /// Each parameter of `tool` and its schema type (`any` for an untyped
    /// one, such as report_result's value).
    static func parameterTypes(of tool: String) -> [String: String] {
        guard let definition = CherryToolCatalog.tools(for: .unknown).first(where: { $0.name == tool }),
              let properties = definition.inputSchema.objectValue?["properties"]?.objectValue
        else { return [:] }
        return properties.mapValues { $0.objectValue?["type"]?.stringValue ?? "any" }
    }

    static func value(
        of text: String?,
        type: String,
        inverted: Bool,
        flag: String,
        input: CherryCLIInput,
        readStandardInput: () throws -> String
    ) throws -> JSONValue {
        switch type {
        case "boolean":
            guard let text else { return .bool(!inverted) }
            switch text.lowercased() {
            case "true", "yes", "1": return .bool(!inverted)
            case "false", "no", "0": return .bool(inverted)
            default: throw UsageError(message: "--\(flag) is true or false, not \(text.debugDescription).")
            }
        case "integer":
            guard let text, let number = Int(text) else {
                throw UsageError(message: "--\(flag) takes a whole number.")
            }
            return .int(number)
        case "array":
            guard let text else { throw UsageError(message: "--\(flag) takes a list: a,b,c.") }
            return .array(text.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) })
        case "object", "any":
            guard let text else { throw UsageError(message: "--\(flag) takes JSON, a file, or - for standard input.") }
            let source: String
            if text == "-" {
                source = try readStandardInput()
            } else if (try? JSONValue.parse(Data(text.utf8))) != nil {
                source = text
            } else if let file = input.readFile(text) {
                source = file
            } else {
                throw UsageError(message: "--\(flag): \(text.debugDescription) is neither JSON nor a readable file.")
            }
            guard let value = try? JSONValue.parse(Data(source.utf8)) else {
                throw UsageError(message: "--\(flag) is not valid JSON.")
            }
            if type == "object", value.objectValue == nil {
                throw UsageError(message: "--\(flag) must be a JSON object.")
            }
            return value
        default:
            guard let text else { throw UsageError(message: "--\(flag) needs a value.") }
            return .string(text == "-" ? try readStandardInput() : text)
        }
    }

    // MARK: Keys

    static let namedKeys: [(String, String)] = [
        ("up", "\u{1B}[A"), ("down", "\u{1B}[B"), ("right", "\u{1B}[C"), ("left", "\u{1B}[D"),
        ("enter", "\r"), ("return", "\r"), ("tab", "\t"), ("shift-tab", "\u{1B}[Z"), ("esc", "\u{1B}"), ("escape", "\u{1B}"),
        ("space", " "), ("backspace", "\u{7F}"), ("delete", "\u{1B}[3~"), ("home", "\u{1B}[H"), ("end", "\u{1B}[F"),
        ("pageup", "\u{1B}[5~"), ("pagedown", "\u{1B}[6~"),
        ("f1", "\u{1B}OP"), ("f2", "\u{1B}OQ"), ("f3", "\u{1B}OR"), ("f4", "\u{1B}OS"),
    ]

    static var keyNames: [String] { namedKeys.map(\.0) }

    /// The bytes of one key name: a named key, `ctrl-<letter>`, or one
    /// character as itself.
    static func keyBytes(_ name: String) -> Data? {
        let lowered = name.lowercased()
        if let key = namedKeys.first(where: { $0.0 == lowered }) {
            return Data(key.1.utf8)
        }
        if lowered.hasPrefix("ctrl-") || lowered.hasPrefix("c-") {
            let letter = lowered.drop { $0 != "-" }.dropFirst()
            // Control and a letter, or one of @ [ \ ] ^ _: the character's
            // low five bits (ctrl-c is 0x03).
            guard letter.count == 1, let scalar = letter.unicodeScalars.first, scalar.isASCII else { return nil }
            let byte = UInt8(scalar.value)
            let upper = (0x61...0x7A).contains(byte) ? byte - 0x20 : byte
            guard (0x40...0x5F).contains(upper) else { return nil }
            return Data([upper & 0x1F])
        }
        guard name.count == 1 else { return nil }
        return Data(name.utf8)
    }

    // MARK: Skill and help

    static let skillUsage = """
    usage: cherry skill show [--skill-md]
           cherry skill setup|status|remove [--agent claude|codex|pi|opencode|amp]… [--dry-run] [--project] [--force] [--json]
    """

    static func skillAction(_ words: [String]) -> CherryCLIAction {
        switch words.first {
        case "show", nil:
            return .print(words.contains("--skill-md") ? CherryCLIGuide.skillMarkdown : CherryCLIGuide.guide)
        case "setup", "status", "remove":
            let operation = CherrySkillRequest.Operation(rawValue: words[0])!
            var request = CherrySkillRequest(operation: operation)
            var rest = Array(words.dropFirst())
            while !rest.isEmpty {
                let word = rest.removeFirst()
                switch word {
                case "--dry-run": request.dryRun = true
                case "--project": request.project = true
                case "--force": request.force = true
                case "--help", "-h": return .print(skillUsage)
                case "--agent":
                    guard let name = rest.first else { return .usage("--agent needs a name.\n" + skillUsage) }
                    rest.removeFirst()
                    guard let agent = CherrySkillAgent(rawValue: name) else {
                        return .usage("cherry: unknown agent \(name.debugDescription): "
                            + CherrySkillAgent.allCases.map(\.rawValue).joined(separator: ", ") + ".\n" + skillUsage)
                    }
                    request.agents = (request.agents ?? []) + [agent]
                default:
                    return .usage("cherry: unknown option \(word.debugDescription).\n" + skillUsage)
                }
            }
            if request.force, operation != .setup {
                return .usage("--force is for cherry skill setup.\n" + skillUsage)
            }
            return .skill(request)
        default:
            return .usage(skillUsage)
        }
    }

    /// Help: every command, or one group's.
    static func help(for topic: [String]) -> String {
        let matching = topic.isEmpty ? commands : commands.filter { Array($0.words.prefix(topic.count)) == Array(topic.prefix($0.words.count)) }
        let list = matching.isEmpty ? commands : matching
        var lines = ["Cherry's commands for agents (cherry host … has the session host's).", ""]
        for command in list {
            lines.append("  \(command.usage)")
            lines.append("      \(command.summary)")
        }
        lines.append("")
        lines.append("ID is a tab's ID or name; without one, a command acts on your own tab.")
        lines.append("Other --options are the tool's own parameters (cherry tool NAME takes its JSON).")
        lines.append("Output is JSON unless standard output is a terminal (--json forces it).")
        lines.append("cherry skill show prints the guide.")
        return lines.joined(separator: "\n") + "\n"
    }
}
