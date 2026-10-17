import Foundation
import JavaScriptCore
import Testing
@testable import Cherry

// Cherry's Pi extension (`Resources/cherry-pi-mcp.ts`, `PiMCPExtension`),
// which the Pi agents Cherry starts get with `-e`: the bundle's own copy,
// run in JavaScriptCore against a stand-in for Pi's extension API (never a
// real Pi). It is plain JavaScript, so it runs once its `export` is gone.

/// The bundle's copy, as Pi loads it: through `CherryResources.bundle`,
/// which also checks that SwiftPM copied it flat into the bundle.
private func piExtensionSource() throws -> String {
    let url = try #require(PiMCPExtension.bundledURL)
    return try String(contentsOf: url, encoding: .utf8)
}

/// What one load of the extension did: the servers it registered (each as
/// `JSON.stringify([name, config])`) and the exception it threw, if any.
private struct PiExtensionRun {
    var registrations: [String]
    var exception: String?

    /// The one registration's name and config, decoded.
    func registration() throws -> (name: String, config: [String: Any]) {
        let json = try #require(registrations.first)
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any])
        let name = try #require(decoded.first as? String)
        let config = try #require(decoded.last as? [String: Any])
        return (name, config)
    }
}

/// Evaluates the extension (its `export default function` made a plain
/// `function`) in a fresh context whose `process.env` is `environment`
/// (nil: no `process` global at all), then calls `cherryMCP` with `pi`, a
/// script expression for Pi's API (`fakePi` records each
/// `registerMcpServer`).
private func runPiExtension(environment: [String: String]?, pi: String = "fakePi") throws -> PiExtensionRun {
    let source = try piExtensionSource()
    let script = source.replacingOccurrences(of: "export default function", with: "function")
    #expect(script != source)
    // JavaScriptCore keeps an uncaught exception in `context.exception`.
    let context = try #require(JSContext())
    context.evaluateScript("var registrations = []; var fakePi = { registerMcpServer: function (name, config) { registrations.push(JSON.stringify([name, config])); } };")
    if let environment {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: environment), as: UTF8.self)
        context.evaluateScript("var process = { env: \(json) };")
    }
    #expect(context.exception == nil)
    context.evaluateScript(script)
    #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
    #expect(context.objectForKeyedSubscript("cherryMCP")?.isObject == true)
    context.evaluateScript("cherryMCP(\(pi));")
    let registrations = context.objectForKeyedSubscript("registrations")?.toArray()?.compactMap { $0 as? String } ?? []
    return PiExtensionRun(registrations: registrations, exception: context.exception?.toString())
}

private let piExtensionHelper = "/Applications/Cherry.app/Contents/MacOS/CherryMCP"

@Test func controlToolPiExtensionIsTheBundlesPlainJavaScript() throws {
    let url = try #require(PiMCPExtension.bundledURL)
    #expect(url.lastPathComponent == PiMCPExtension.fileName)
    #expect(url.path.hasSuffix("Cherry_Cherry.bundle/cherry-pi-mcp.ts"))
    #expect(PiMCPExtension.bundledPath == url.path)
    let source = try piExtensionSource()
    // Nothing for jiti to resolve, and no TypeScript syntax: the parse in
    // JavaScriptCore below shows the rest.
    for word in ["import ", "require(", "ExtensionAPI", "interface "] {
        #expect(!source.contains(word), "\(word)")
    }
    #expect(source.range(of: #":\s*(string|number|boolean|any|unknown|void|object)\b"#, options: .regularExpression) == nil)
    #expect(source.hasPrefix("// Cherry MCP for a Pi agent that Cherry starts"))
    #expect(source.contains("export default function cherryMCP(pi) {"))
    // The description is the one Settings registers, and fits Pi's prompt.
    #expect(source.contains("\"\(PiMCPRegistration.serverDescription)\""))
    #expect(PiMCPRegistration.serverDescription.count <= 250)
}

@Test func controlToolPiExtensionRegistersTheTabsHelperForTheSession() throws {
    // (a) The helper and name the tab sets: one server, deferred, with
    // CherryMCP told Pi's 300 s timeout.
    let run = try runPiExtension(environment: [
        "CHERRY_MCP_HELPER": piExtensionHelper, "CHERRY_MCP_SERVER_NAME": "cherry", "CHERRY_PROCESS_ID": UUID().uuidString,
    ])
    #expect(run.exception == nil)
    #expect(run.registrations.count == 1)
    let (name, config) = try run.registration()
    #expect(name == "cherry")
    #expect(Set(config.keys) == ["command", "args", "exposure", "timeout", "description"])
    #expect(config["command"] as? String == piExtensionHelper)
    #expect(config["args"] as? [String] == ["--client-tool-timeout", "300"])
    #expect(config["exposure"] as? String == "deferred")
    #expect(config["timeout"] as? Int == 300)
    #expect(config["description"] as? String == PiMCPRegistration.serverDescription)
    #expect(run.registrations.first == #"["cherry",{"command":"\#(piExtensionHelper)","args":["--client-tool-timeout","300"],"exposure":"deferred","timeout":300,"description":"\#(PiMCPRegistration.serverDescription)"}]"#)

    // (b) Another identity's name; none set is `cherry`.
    let dev = try runPiExtension(environment: ["CHERRY_MCP_HELPER": piExtensionHelper, "CHERRY_MCP_SERVER_NAME": "cherrydev"])
    #expect(try dev.registration().name == "cherrydev")
    let unnamed = try runPiExtension(environment: ["CHERRY_MCP_HELPER": piExtensionHelper])
    #expect(try unnamed.registration().name == "cherry")
    #expect(dev.exception == nil && unnamed.exception == nil)
}

@Test func controlToolPiExtensionDoesNothingWhereItCannot() throws {
    let environment = ["CHERRY_MCP_HELPER": piExtensionHelper, "CHERRY_MCP_SERVER_NAME": "cherry"]
    // (c) A Pi without MCP (before 0.99) has no registerMcpServer.
    for pi in ["{}", "{ registerMcpServer: 1 }", "undefined", "null"] {
        let run = try runPiExtension(environment: environment, pi: pi)
        #expect(run.registrations.isEmpty, "\(pi)")
        #expect(run.exception == nil, "\(pi): \(run.exception ?? "")")
    }
    // (d) No helper, or not an absolute path.
    for helper in [nil, "", "CherryMCP", "./CherryMCP", "~/CherryMCP"] as [String?] {
        var tab = environment
        tab["CHERRY_MCP_HELPER"] = helper
        let run = try runPiExtension(environment: tab)
        #expect(run.registrations.isEmpty, "\(helper ?? "none")")
        #expect(run.exception == nil, "\(helper ?? "none")")
    }
    // (e) A name Pi would refuse.
    for name in ["bad name", "cherry.dev", "cherry'", "a/b"] {
        var tab = environment
        tab["CHERRY_MCP_SERVER_NAME"] = name
        let run = try runPiExtension(environment: tab)
        #expect(run.registrations.isEmpty, "\(name)")
        #expect(run.exception == nil, "\(name)")
    }
    // (f) No `process` global, or one without an environment.
    let bare = try runPiExtension(environment: nil)
    #expect(bare.registrations.isEmpty)
    #expect(bare.exception == nil, "\(bare.exception ?? "")")
}
