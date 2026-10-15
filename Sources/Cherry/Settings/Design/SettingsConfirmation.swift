import SwiftUI

/// A question Settings asks before it does something (every destructive
/// action and every page reset asks first, in an alert that names what is
/// lost). Each page builds it with a pure function, which
/// its tests compare (`==` looks at the texts and roles, not the actions),
/// and shows it with `.settingsConfirmation(_:)`.
struct SettingsConfirmation: Equatable {
    /// One of the alert's buttons.
    struct Choice: Equatable {
        var title: String
        var role: ButtonRole?
        /// Return presses it.
        var isDefault: Bool
        var perform: @MainActor () -> Void

        init(_ title: String, role: ButtonRole? = nil, isDefault: Bool = false, perform: @escaping @MainActor () -> Void = {}) {
            self.title = title
            self.role = role
            self.isDefault = isDefault
            self.perform = perform
        }

        /// Cancel: does nothing.
        static func cancel(_ title: String = "Cancel") -> Choice {
            Choice(title, role: .cancel)
        }

        static func == (lhs: Choice, rhs: Choice) -> Bool {
            lhs.title == rhs.title && lhs.role == rhs.role && lhs.isDefault == rhs.isDefault
        }
    }

    var title: String
    var message: String?
    var choices: [Choice]

    init(title: String, message: String? = nil, choices: [Choice]) {
        self.title = title
        self.message = message
        self.choices = choices
    }

    /// A page's Reset…: "Reset 3 settings?", the changes, and
    /// Reset (the default) and Cancel.
    static func pageReset(
        changes: [SettingsChange],
        mentionsGhosttyConfig: Bool,
        reset: @escaping @MainActor () -> Void
    ) -> SettingsConfirmation {
        let texts = SettingsPageReset.confirmation(for: changes, mentionsGhosttyConfig: mentionsGhosttyConfig)
        return SettingsConfirmation(
            title: texts.title,
            message: texts.message,
            choices: [Choice("Reset", isDefault: true, perform: reset), .cancel()]
        )
    }
}

extension View {
    /// Shows `confirmation` as an alert while it is set, and clears it when
    /// the alert closes.
    func settingsConfirmation(_ confirmation: Binding<SettingsConfirmation?>) -> some View {
        alert(
            confirmation.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { confirmation.wrappedValue != nil },
                set: { if !$0 { confirmation.wrappedValue = nil } }
            ),
            presenting: confirmation.wrappedValue
        ) { shown in
            ForEach(Array(shown.choices.enumerated()), id: \.offset) { _, choice in
                Button(choice.title, role: choice.role) {
                    choice.perform()
                }
                .keyboardShortcut(choice.isDefault ? .defaultAction : nil)
            }
        } message: { shown in
            if let message = shown.message {
                Text(message)
            }
        }
    }
}
