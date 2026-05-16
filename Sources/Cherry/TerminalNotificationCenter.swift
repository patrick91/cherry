import Foundation
import UserNotifications

@MainActor
final class TerminalNotificationCenter {
    static let shared = TerminalNotificationCenter()

    var isDeliveryEnabled = true
    private var didRequestAuthorization = false
    private var didReportUnavailableDelivery = false

    private init() {}

    func configure(delegate: UNUserNotificationCenterDelegate) {
        guard canUseNativeNotifications else {
            reportUnavailableDeliveryIfNeeded()
            return
        }

        UNUserNotificationCenter.current().delegate = delegate
    }

    func requestAuthorizationIfNeeded() {
        guard canUseNativeNotifications else {
            reportUnavailableDeliveryIfNeeded()
            return
        }

        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                fputs("[notification authorization] \(error.localizedDescription)\n", stderr)
            }
        }
    }

    func post(_ notification: TerminalNotificationRequest, for session: TerminalSession) {
        guard isDeliveryEnabled else { return }
        guard !ProjectWindowRegistry.shared.isSessionVisible(session) else { return }
        guard canUseNativeNotifications else {
            reportUnavailableDeliveryIfNeeded()
            return
        }

        requestAuthorizationIfNeeded()

        let projectRoot = ProjectWindowRegistry.shared.projectRoot(containing: session.id)
        let content = UNMutableNotificationContent()
        content.title = notification.title?.nilIfEmpty ?? session.title
        content.body = notification.body.nilIfEmpty ?? "Terminal bell"
        content.sound = .default
        content.userInfo = [
            "sessionID": session.id.uuidString,
            "projectRoot": projectRoot ?? ""
        ]

        let request = UNNotificationRequest(
            identifier: "cherry-terminal-\(session.id.uuidString)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                fputs("[notification post] \(error.localizedDescription)\n", stderr)
            }
        }
    }

    func handleResponse(userInfo: [AnyHashable: Any]) {
        guard let sessionIDString = userInfo["sessionID"] as? String,
              let sessionID = UUID(uuidString: sessionIDString)
        else {
            return
        }

        let projectRoot = (userInfo["projectRoot"] as? String)?.nilIfEmpty
        focusSession(sessionID: sessionID, projectRoot: projectRoot)
    }

    func handleResponse(sessionIDString: String?, projectRoot: String?) {
        guard let sessionIDString,
              let sessionID = UUID(uuidString: sessionIDString)
        else {
            return
        }

        focusSession(sessionID: sessionID, projectRoot: projectRoot?.nilIfEmpty)
    }

    private func focusSession(sessionID: UUID, projectRoot: String?) {
        ProjectWindowRegistry.shared.focusSession(sessionID: sessionID, projectRoot: projectRoot)
    }

    private var canUseNativeNotifications: Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        guard let bundleIdentifier = Bundle.main.bundleIdentifier?.nilIfEmpty else { return false }
        return bundleIdentifier.contains(".")
    }

    private func reportUnavailableDeliveryIfNeeded() {
        guard !didReportUnavailableDelivery else { return }
        didReportUnavailableDelivery = true
        fputs("[notification delivery] skipped because the app has no notification-capable bundle identifier\n", stderr)
    }
}
