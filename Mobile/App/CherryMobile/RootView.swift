import CherryMobileKit
import SwiftUI

enum Route: Hashable {
    case session(SessionKey)
    case terminal(SessionKey, fitsPhone: Bool)
    case macs
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            InboxView(path: $path)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .session(let key):
                        SessionView(key: key, path: $path)
                    case .terminal(let key, let fitsPhone):
                        TerminalScreen(key: key, fitsPhone: fitsPhone)
                    case .macs:
                        MacsView()
                    }
                }
        }
        .alert(
            "Trust \(macAwaitingTrust?.endpoint.name ?? "this Mac")?",
            isPresented: Binding(
                get: { macAwaitingTrust != nil },
                set: { _ in }
            ),
            presenting: macAwaitingTrust
        ) { mac in
            Button("Trust") { Task { await model.trustHostKey(of: mac.id) } }
            Button("Cancel", role: .cancel) { Task { await model.rejectHostKey(of: mac.id) } }
        } message: { mac in
            if case .awaitingTrust(let fingerprint) = mac.status {
                Text("First connection to \(mac.endpoint.host). Its host key is \(fingerprint). Check it matches the Mac's (ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub) before you trust it.")
            }
        }
        .task { await openLaunchScreen() }
    }

    private var macAwaitingTrust: AppModel.Mac? {
        model.macs.first {
            if case .awaitingTrust = $0.status { return true }
            return false
        }
    }

    /// Opens the screen `-screen` asks for, once the Demo Mac listed.
    private func openLaunchScreen() async {
        guard let screen = model.launch.screen else { return }
        let mac = DemoMac.endpoint.id
        await model.waitUntilListed(mac)
        switch screen {
        case .inbox:
            path = []
        case .macs:
            path = [.macs]
        case .session(let id):
            path = [.session(SessionKey(macID: mac, sessionID: id))]
        case .terminal(let id, let fitsPhone):
            let key = SessionKey(macID: mac, sessionID: id)
            path = [.session(key), .terminal(key, fitsPhone: fitsPhone)]
        }
    }
}
