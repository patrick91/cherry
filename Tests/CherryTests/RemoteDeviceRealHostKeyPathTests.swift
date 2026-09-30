import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import Cherry

// Keys typed into a tab of another Mac, down the real key path (see
// PersistentLocalRealHostKeyPathTests): tmux's prefix, then `d`, detaches it,
// whether the tab's attach adapter types the keys (over the fake Mac's ssh
// shim) or, while it is away, the device's host does over the live control
// connection. Against a fake remote Mac (Scripts/fake-remote-mac), gated like
// the other real-host suites. tmux runs on a private socket with a
// configuration file of the test's own.

private let deviceKeyPathEnabled = ProcessInfo.processInfo.environment["CHERRY_TEST_HOST_INTEGRATION"] == "1"

@Test(.enabled(if: deviceKeyPathEnabled))
@MainActor func RemoteDeviceRealHostTmuxPrefixThenDDetachesIt() async throws {
    let mac = try FakeRemoteMac()
    let control = mac.makeControl()
    var configuration = FakeRemoteMac.fastConfiguration
    // Once lost, an adapter stays lost for the test.
    configuration.reconnectDelay = (120, 120)
    let hosting = mac.makeHosting(control: control, configuration: configuration)
    let workspace = TerminalWorkspace(
        projectRoot: mac.projectKey, createInitialSession: false,
        backendPolicy: .remote(hosting, settings: { .defaults }, hostReconnects: nil)
    )
    let stage = KeyPathStage()
    var servers: [PrivateTmux] = []
    func cleanUp() async {
        for server in servers { server.killServer() }
        stage.cleanUp()
        workspace.closeAllSessions(intent: .windowClosedEndingSessions)
        await mac.tearDown()
    }
    do {
        guard let defaults = try PrivateTmux(in: mac.root, name: "b"),
              let spacePrefix = try PrivateTmux(in: mac.root, name: "s", configuration: [
                  "unbind C-b", "set -g prefix C-Space", "bind C-Space send-prefix",
              ])
        else {
            print("No tmux on this Mac: nothing to detach")
            await cleanUp()
            return
        }
        servers = [defaults, spacePrefix]

        func detach(_ tmux: PrivateTmux, prefix: TypedKey, throughHost: Bool) async throws {
            let tab = workspace.addSession(title: "tmux")
            stage.show(tab)
            try await mac.waitFor("the tab's adapter to attach", timeout: 30) {
                tab.persistentSession != nil && tab.state == .live && tab.usesNativePTYBackend && !tab.readsContentFromHost
            }
            #expect(stage.focus(tab))
            let binding = try #require(tab.persistentSession)
            try await tab.sendControlInput(Data(("TERM=xterm-256color " + tmux.newSessionCommand + "\n").utf8), raw: false)
            try await mac.waitFor("tmux's status line") { (tab.ghosttyBridge.readNativeScreenText() ?? "").contains("[t] 0:") }
            try await mac.waitFor("tmux's client") { tmux.sessions() == ["t:1"] }
            if throughHost {
                let adapter = try #require(tab.ghosttyBridge.nativeSessionLeaderPID(), "the adapter's tty session")
                ShellProcessController.terminateNativeShellSession(anchorPID: adapter)
                try await mac.waitFor("the tab to lose its adapter") { tab.readsContentFromHost && tab.keyboardInputGoesThroughHost }
                #expect(stage.focus(tab))
            }
            try stage.type(prefix)
            try stage.type(.d)
            try await mac.waitFor("tmux to detach (\(prefix), through the host: \(throughHost))") {
                tmux.sessions() == ["t:0"]
            }
            try await mac.waitFor("tmux's detach message") {
                (try? await hosting.screen(of: binding).text.contains("[detached (from session t)]")) == true
            }
            #expect(tab.offlineInputRejectedAt == nil)
            tmux.killServer()
        }

        try await detach(defaults, prefix: .controlB, throughHost: false)
        try await detach(spacePrefix, prefix: .controlSpace, throughHost: false)
        try await detach(defaults, prefix: .controlB, throughHost: true)
        try await detach(spacePrefix, prefix: .controlSpace, throughHost: true)
    } catch {
        await cleanUp()
        throw error
    }
    await cleanUp()
}
