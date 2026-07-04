import AppKit
import SwiftUI

struct SettingsSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search settings", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .settingsSearchFieldSurface()
    }
}

struct SettingsIconBadge: View {
    let systemImage: String
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
                }

            Image(systemName: systemImage)
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
    }
}

private struct SettingsGroupedSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.32), lineWidth: 0.6)
            }
    }
}

private struct SettingsGlassButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(.glass)
            .buttonBorderShape(.roundedRectangle)
            .controlSize(.small)
    }
}

private struct SettingsProminentGlassButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.roundedRectangle)
            .controlSize(.small)
    }
}

private struct SettingsSearchFieldSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .glassEffect(.regular.interactive(), in: Capsule())
    }
}

extension View {
    func settingsGroupedSurface() -> some View {
        modifier(SettingsGroupedSurfaceModifier())
    }

    func settingsGlassButtonStyle() -> some View {
        modifier(SettingsGlassButtonModifier())
    }

    func settingsProminentGlassButtonStyle() -> some View {
        modifier(SettingsProminentGlassButtonModifier())
    }

    func settingsSearchFieldSurface() -> some View {
        modifier(SettingsSearchFieldSurfaceModifier())
    }

    func settingsRowPadding() -> some View {
        padding(.horizontal, 18).padding(.vertical, 13)
    }
}

struct SettingsPaneScroll<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let content: Content

    init(page: SettingsPage, @ViewBuilder content: () -> Content) {
        title = page.title
        subtitle = page.subtitle
        systemImage = page.systemImage
        self.content = content()
    }

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: 660, alignment: .topLeading)
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SettingsCard<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 16)
                    .padding(.top, 13)
                    .padding(.bottom, 7)
            }

            content
        }
        .settingsGroupedSurface()
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    let subtitle: String?
    let control: Control

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)

                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control
                .frame(minWidth: 150, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 18)
    }
}

struct SettingsEmptyState: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            Text(title)
                .font(.system(size: 15, weight: .semibold))

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }
}

struct SettingsSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String
    var displayScale = 1.0

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 140, alignment: .leading)

            Slider(value: $value, in: range, step: step)

            Text(formattedValue)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
    }

    private var formattedValue: String {
        let displayValue = value * displayScale

        if step * displayScale >= 1 {
            return "\(Int(displayValue.rounded()))\(formattedSuffix)"
        } else {
            return "\(displayValue.formatted(.number.precision(.fractionLength(2))))\(formattedSuffix)"
        }
    }

    private var formattedSuffix: String {
        guard !suffix.isEmpty else { return "" }
        return suffix == "pt" ? " \(suffix)" : suffix
    }
}

@MainActor
final class OptionKeyObserver: ObservableObject {
    @Published private(set) var isOptionDown: Bool

    private nonisolated(unsafe) var flagsMonitor: Any?
    private nonisolated(unsafe) var resignObserver: NSObjectProtocol?

    init() {
        isOptionDown = NSEvent.modifierFlags.contains(.option)

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                self?.isOptionDown = event.modifierFlags.contains(.option)
            }
            return event
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isOptionDown = false
            }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            if let flagsMonitor {
                NSEvent.removeMonitor(flagsMonitor)
            }
            if let resignObserver {
                NotificationCenter.default.removeObserver(resignObserver)
            }
        }
    }
}
