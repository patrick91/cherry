import CoreGraphics

struct TopChromeShieldMetrics: Equatable {
    let coverHeight: CGFloat
    let fadeHeight: CGFloat
    let contentTopInset: CGFloat

    var totalHeight: CGFloat {
        coverHeight + fadeHeight
    }

    static let projectSidebar = TopChromeShieldMetrics(
        coverHeight: 32,
        fadeHeight: 16,
        contentTopInset: 48
    )
}
