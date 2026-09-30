import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import Cherry

// Copying in a tab of another Mac lands on this Mac's clipboard: the tab's
// environment says it is remote, as over ssh (`RemoteLaunchSpec.
// sshEnvironment`, and the holder's SSH_TTY), so programs copy with OSC 52,
// and the write reaches the tab's surface through the device's host and the
// attach adapter. Against a fake remote Mac (Scripts/fake-remote-mac), gated
// like the other real-host suites. The surfaces' clipboard is a private
// pasteboard: no test here touches the general one.

private let clipboardRealHostEnabled = ProcessInfo.processInfo.environment["CHERRY_TEST_HOST_INTEGRATION"] == "1"

@Test(.enabled(if: clipboardRealHostEnabled))
@MainActor func RemoteDeviceRealHostOSC52CopyReachesThisMacsClipboard() async throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("CherryTests.RemoteOSC52.\(UUID().uuidString)"))
    let savedPasteboard = TerminalClipboard.pasteboard
    TerminalClipboard.pasteboard = { pasteboard }
    pasteboard.clearContents()
    let mac = try FakeRemoteMac()
    let control = mac.makeControl()
    let hosting = mac.makeHosting(control: control)
    let workspace = TerminalWorkspace(
        projectRoot: mac.projectKey, createInitialSession: false,
        backendPolicy: .remote(hosting, settings: { .defaults }, hostReconnects: nil)
    )
    let container = GhosttyTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    func cleanUp() async {
        container.detachActiveSession()
        window.close()
        workspace.closeAllSessions(intent: .windowClosed)
        await mac.tearDown()
        TerminalClipboard.pasteboard = savedPasteboard
        pasteboard.releaseGlobally()
    }
    do {
        let tab = workspace.addSession(title: "Remote")
        container.configure(with: tab, colorScheme: .dark, allowsAutoFocus: false)
        window.orderFrontRegardless()
        try await mac.waitFor("the tab's adapter to attach", timeout: 30) {
            tab.persistentSession != nil && tab.state == .live && tab.usesNativePTYBackend && !tab.readsContentFromHost
        }
        let binding = try #require(tab.persistentSession)

        // The program runs there as over ssh: SSH_CONNECTION from the
        // launch spec, SSH_TTY its own terminal, from the holder.
        try await tab.sendControlInput(Data(
            "echo \"SSH:$SSH_CONNECTION:$([ \"$SSH_TTY\" = \"$(tty)\" ] && echo own-tty)\"\n".utf8
        ), raw: false)
        try await mac.waitFor("the environment there") {
            (try? await hosting.screen(of: binding).text.contains("SSH:127.0.0.1 0 127.0.0.1 22:own-tty")) == true
        }

        // What a program there copies with OSC 52 lands here.
        try await tab.sendControlInput(Data(
            "printf '\\033]52;c;%s\\a' \"$(printf hello | base64)\"\n".utf8
        ), raw: false)
        try await mac.waitFor("the copy to reach this Mac's pasteboard") {
            pasteboard.string(forType: .string) == "hello"
        }
    } catch {
        await cleanUp()
        throw error
    }
    await cleanUp()
}
