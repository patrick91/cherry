import SwiftUI

struct TopChromeShieldMetrics: Equatable {
    let coverHeight: CGFloat
    let fadeHeight: CGFloat
    let contentTopInset: CGFloat

    var totalHeight: CGFloat {
        coverHeight + fadeHeight
    }

    static let settingsNativePane = TopChromeShieldMetrics(
        coverHeight: 110,
        fadeHeight: 30,
        contentTopInset: 140
    )

    static let projectSidebar = TopChromeShieldMetrics(
        coverHeight: 52,
        fadeHeight: 24,
        contentTopInset: 76
    )
}

struct MaterialTopChromeShield: View {
    let metrics: TopChromeShieldMetrics
    let material: Material

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(material)
                .frame(height: metrics.coverHeight)

            Rectangle()
                .fill(material)
                .mask {
                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .frame(height: metrics.fadeHeight)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ReservesSettingsNavigationTitleChromeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var reservesSettingsNavigationTitleChrome: Bool {
        get { self[ReservesSettingsNavigationTitleChromeKey.self] }
        set { self[ReservesSettingsNavigationTitleChromeKey.self] = newValue }
    }
}
