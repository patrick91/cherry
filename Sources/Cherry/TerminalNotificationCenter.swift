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
        deliver(
            title: notification.title?.nilIfEmpty ?? session.title,
            body: notification.body.nilIfEmpty ?? "Terminal bell",
            identifierPrefix: "cherry-terminal",
            for: session
        )
    }

    /// What a program status notification says: the program's own line
    /// when it gave one (`message`, untrusted text, shown as plain text),
    /// else what its state means.
    static func programStatusBody(for status: ProgramStatus) -> String {
        if !status.message.isEmpty {
            return String(status.message.prefix(256))
        }
        switch status.state {
        case .blocked:
            switch status.kind {
            case .permission?: return "Waiting for your permission."
            case .question?: return "Asking you a question."
            case .auth?: return "Waiting for you to sign in."
            case .unknown?, nil: return "Waiting for you."
            }
        case .done: return "Finished."
        case .error: return "Failed."
        case .idle, .working, .unknown: return "Needs your attention."
        }
    }

    /// A tab's program blocked on the user, finished or failed (OSC 7501)
    /// while the tab is not on screen.
    func postProgramStatus(_ status: ProgramStatus, for session: TerminalSession) {
        deliver(
            title: session.title,
            body: Self.programStatusBody(for: status),
            identifierPrefix: "cherry-program-status",
            for: session
        )
    }

    /// A bell or notification from a session of this app that no open tab
    /// shows (Background Sessions): posted naming the session and its
    /// project. Clicking it opens the session as Background Sessions → Open
    /// does (`handleResponse`).
    func postBackgroundSession(_ content: BackgroundSessionNotificationContent) {
        guard isDeliveryEnabled else { return }
        guard canUseNativeNotifications else {
            reportUnavailableDeliveryIfNeeded()
            return
        }
        requestAuthorizationIfNeeded()
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.subtitle = content.subtitle
        notification.body = content.body
        notification.sound = .default
        notification.userInfo = content.userInfo
        let request = UNNotificationRequest(
            identifier: "cherry-background-\(content.sessionID)-\(UUID().uuidString)",
            content: notification,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                fputs("[notification post] \(error.localizedDescription)\n", stderr)
            }
        }
    }

    private func deliver(
        title: String,
        body: String,
        identifierPrefix: String,
        for session: TerminalSession
    ) {
        guard isDeliveryEnabled else { return }
        guard !ProjectWindowRegistry.shared.isSessionVisible(session) else { return }
        guard canUseNativeNotifications else {
            reportUnavailableDeliveryIfNeeded()
            return
        }

        requestAuthorizationIfNeeded()

        let projectRoot = ProjectWindowRegistry.shared.projectRoot(containing: session.id)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [
            "sessionID": session.id.uuidString,
            "projectRoot": projectRoot ?? ""
        ]

        let request = UNNotificationRequest(
            identifier: "\(identifierPrefix)-\(session.id.uuidString)-\(UUID().uuidString)",
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

    /// A click on a notification: a background session's opens it
    /// (`BackgroundSessionsModel.open(sessionID:)`), a tab's focuses the tab.
    func handleResponse(userInfo: [AnyHashable: Any], backgroundSessions: BackgroundSessionsModel) {
        if let sessionID = (userInfo[BackgroundSessionNotificationContent.sessionIDKey] as? String)?.nilIfEmpty {
            // This Mac's or a device's (its host identity says which).
            backgroundSessions.open(
                sessionID: sessionID,
                hostID: (userInfo[BackgroundSessionNotificationContent.hostIDKey] as? String)?.nilIfEmpty
            )
            return
        }
        handleResponse(userInfo: userInfo)
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

/// What the notification for a background session's bell or notification
/// says (`TerminalNotificationCenter.postBackgroundSession`); pure, for tests.
struct BackgroundSessionNotificationContent: Equatable {
    /// The host session id, in `userInfo` under `sessionIDKey`.
    static let sessionIDKey = "backgroundSessionID"
    /// Its host's identity (This Mac's or a device's), under `hostIDKey`.
    static let hostIDKey = "backgroundSessionHostID"

    let sessionID: String
    let hostID: String
    /// The session, as Background Sessions names it.
    let title: String
    /// Its project, and that it runs in the background.
    let subtitle: String
    let body: String

    /// `machine`: the device the session is on, nil for This Mac.
    init(session: BackgroundSession, signal: PersistentHostSignal, machine: String? = nil) {
        sessionID = session.id
        hostID = session.hostID
        title = session.title
        subtitle = machine.map { "\(session.projectName) on \($0) · in the background" }
            ?? "\(session.projectName) · in the background"
        switch signal {
        case .notification(let title, let body):
            let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty {
                self.body = title.isEmpty ? "Notification" : title
            } else {
                self.body = title.isEmpty ? body : "\(title): \(body)"
            }
        case .bell, .progress:
            body = session.kind == .agent ? "This agent may need your attention." : "Terminal bell"
        }
    }

    var userInfo: [String: String] {
        [Self.sessionIDKey: sessionID, Self.hostIDKey: hostID]
    }
}
