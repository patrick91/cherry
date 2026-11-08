import ChatLayout
import CherryMobileKit
import SwiftUI
import UIKit

/// A row of an agent's conversation.
enum ConversationItem: Equatable {
    /// Older entries were left out.
    case earlier
    case message(TranscriptEntry)
    /// A run of tool calls between messages, named by its first.
    case tools(id: String, [TranscriptEntry])
    /// The menu the agent's screen asks with.
    case question(ScreenMenu)
    /// What the agent says it is working on.
    case working(String)

    /// Unique among a conversation's rows. A new question is another row,
    /// so it starts unanswered.
    var id: String {
        switch self {
        case .earlier: "earlier"
        case .message(let entry): "entry:" + entry.id
        case .tools(let id, _): "tools:" + id
        case .question(let menu): "question:" + ([menu.question ?? ""] + menu.options.map(\.label)).joined(separator: "\u{1F}")
        case .working: "working"
        }
    }

    /// The rows for `conversation`, then a question or a working row. A row
    /// whose id an earlier one has is left out (a list can't show both).
    static func items(of conversation: Conversation, question: ScreenMenu?, working: String?) -> [ConversationItem] {
        var items: [ConversationItem] = conversation.moreBefore ? [.earlier] : []
        for row in ConversationRow.rows(of: conversation.entries) {
            switch row {
            case .entry(let entry): items.append(.message(entry))
            case .tools(let tools): items.append(.tools(id: tools.first?.id ?? "", tools))
            }
        }
        if let question {
            items.append(.question(question))
        } else if let working {
            items.append(.working(working))
        }
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}

/// An agent's conversation, oldest first, in a `UICollectionView` laid out
/// by ChatLayout, each row SwiftUI. UIKit, because SwiftUI's scroll views
/// can't keep their place while rows change or scroll exactly to a row they
/// haven't laid out (patrick91/duck's chat found the same). The composer
/// under it stays SwiftUI.
struct ConversationList: UIViewControllerRepresentable {
    let items: [ConversationItem]
    /// The session's folder, which tool calls' paths are shown relative to.
    let project: String?
    /// Goes up each time the list should scroll to its end: when sending.
    let endRequests: Int
    let answer: @MainActor ([MobileKey]) async -> Void

    func makeUIViewController(context: Context) -> ConversationListController {
        ConversationListController(project: project, answer: answer)
    }

    func updateUIViewController(_ controller: ConversationListController, context: Context) {
        controller.project = project
        controller.answer = answer
        controller.show(items)
        controller.scrollToEnd(onRequest: endRequests)
    }
}

/// The collection view behind `ConversationList`. It opens at the end,
/// follows the end as rows come and change or the keyboard opens while the
/// end is on screen, and leaves the person alone while they read further
/// up: ChatLayout keeps the rows on screen still through updates.
final class ConversationListController: UIViewController {
    var project: String?
    var answer: @MainActor ([MobileKey]) async -> Void

    private let layout = CollectionViewChatLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private lazy var dataSource = ChatLayoutDiffableDataSource<Int, String>(collectionView: collectionView) { [unowned self] collectionView, indexPath, id in
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: Self.cellIdentifier, for: indexPath)
        if let item = self.itemsByID[id] {
            self.configure(cell, with: item)
        }
        return cell
    }

    private var items: [ConversationItem] = []
    private var itemsByID: [String: ConversationItem] = [:]
    private var endRequestsSeen = 0

    /// Tool groups showing every call, by row id, and tool calls showing
    /// their result, by entry id. Kept here, not in the rows, so a reused
    /// cell doesn't take another row's.
    private var openGroups: Set<String> = []
    private var expandedTools: Set<String> = []

    /// Whether to keep the end on screen as rows come or the keyboard opens:
    /// yes while the end is on screen, or a scroll to it was asked for,
    /// until the person drags.
    private var followsEnd = true

    /// Whether to move to the end at the next layout, once the view is in a
    /// window: when the rows arrive or start over.
    private var needsEnd = false

    /// The height at the last layout. SwiftUI makes room for the keyboard
    /// by resizing the list.
    private var lastHeight: CGFloat = 0

    private static let cellIdentifier = "row"

    init(project: String?, answer: @escaping @MainActor ([MobileKey]) async -> Void) {
        self.project = project
        self.answer = answer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ConversationListController isn't made from a storyboard")
    }

    override func loadView() {
        layout.settings.interItemSpacing = 14
        layout.settings.additionalInsets = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        layout.keepContentOffsetAtBottomOnBatchUpdates = true
        layout.keepContentAtBottomOfVisibleArea = true
        layout.processOnlyVisibleItemsOnAnimatedBatchUpdates = false

        collectionView.register(ConversationCell.self, forCellWithReuseIdentifier: Self.cellIdentifier)
        collectionView.delegate = self
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.accessibilityIdentifier = "conversation"
        // ChatLayout's example turns prefetching off: https://openradar.appspot.com/40926834
        collectionView.isPrefetchingEnabled = false
        _ = dataSource

        // A tap on the conversation puts the keyboard away; the rows' own
        // buttons still get it.
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTap))
        tap.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(tap)

        view = collectionView
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let height = collectionView.bounds.height
        let heightChanged = height != lastHeight
        lastHeight = height
        if needsEnd, view.window != nil {
            needsEnd = false
            UIView.performWithoutAnimation { moveToEnd(animated: false) }
        } else if heightChanged, followsEnd, !items.isEmpty {
            // The keyboard opening or closing, or the composer growing: the
            // end moves with it when it's on screen; history stays put.
            moveToEnd(animated: false)
        }
    }

    // MARK: Rows

    /// Shows `newItems`: rows added, removed or changed in place are
    /// animated, and the end followed when it's on screen. The first rows
    /// open at the end.
    func show(_ newItems: [ConversationItem]) {
        guard newItems != items else { return }
        let old = itemsByID
        var snapshot = Self.snapshot(of: newItems)
        let changed = newItems.filter { item in old[item.id].map { $0 != item } ?? false }
        snapshot.reconfigureItems(changed.map(\.id))
        let commit = { [unowned self] in
            self.items = newItems
            self.itemsByID = Dictionary(uniqueKeysWithValues: newItems.map { ($0.id, $0) })
        }
        guard isViewLoaded, view.window != nil, !items.isEmpty, !newItems.isEmpty else {
            dataSource.applySnapshotUsingReloadData(snapshot, commitAlongsideUpdates: commit)
            followsEnd = true
            needsEnd = true
            if isViewLoaded { view.setNeedsLayout() }
            return
        }
        dataSource.apply(snapshot, animatingDifferences: true, commitAlongsideUpdates: commit) { [weak self] in
            guard let self, followsEnd else { return }
            moveToEnd(animated: false)
        }
    }

    private static func snapshot(of items: [ConversationItem]) -> NSDiffableDataSourceSnapshot<Int, String> {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(items.map(\.id))
        return snapshot
    }

    private func configure(_ cell: UICollectionViewCell, with item: ConversationItem) {
        let row = ConversationRowView(
            item: item,
            project: project,
            openGroups: openGroups,
            expandedTools: expandedTools,
            showAll: { [weak self] id in self?.showAllTools(inRow: id) },
            toggle: { [weak self] tool, row in self?.toggleTool(tool, inRow: row) },
            answer: answer
        )
        cell.contentConfiguration = UIHostingConfiguration {
            // A reused cell starts the row's SwiftUI state over.
            row.id(item.id)
        }
        .margins(.horizontal, 14)
        .margins(.vertical, 0)
    }

    // MARK: Opening rows

    private func showAllTools(inRow id: String) {
        openGroups.insert(id)
        reconfigureKeepingTop(of: id)
    }

    private func toggleTool(_ toolID: String, inRow id: String) {
        expandedTools.formSymmetricDifference([toolID])
        reconfigureKeepingTop(of: id)
    }

    /// Redraws a row the person opened or closed, keeping its top where it
    /// was so the rows under it move: ChatLayout would keep the bottom.
    private func reconfigureKeepingTop(of id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let indexPath = IndexPath(item: index, section: 0)
        var snapshot = Self.snapshot(of: items)
        snapshot.reconfigureItems([id])
        guard let attributes = layout.layoutAttributesForItem(at: indexPath) else {
            dataSource.apply(snapshot, animatingDifferences: false, commitAlongsideUpdates: {})
            return
        }
        let offset = attributes.frame.minY - layout.visibleBounds.minY - layout.settings.additionalInsets.top
        dataSource.apply(snapshot, animatingDifferences: false, commitAlongsideUpdates: {}) { [weak self] in
            guard let self else { return }
            layout.restoreContentOffset(with: ChatLayoutPositionSnapshot(indexPath: indexPath, edge: .top, offset: offset))
            followsEnd = isAtEnd
        }
    }

    // MARK: The end

    /// Scrolls to the end when `requests` went up: when sending.
    func scrollToEnd(onRequest requests: Int) {
        guard requests != endRequestsSeen else { return }
        endRequestsSeen = requests
        followsEnd = true
        moveToEnd(animated: true)
    }

    /// Puts the last row at the bottom: animated when it's near, in one step
    /// from further away, which lands exactly.
    private func moveToEnd(animated: Bool) {
        guard let last = items.indices.last else { return }
        let distance = maxContentOffsetY - collectionView.contentOffset.y
        if animated, distance > 0, distance <= collectionView.bounds.height {
            collectionView.setContentOffset(CGPoint(x: 0, y: maxContentOffsetY), animated: true)
            return
        }
        layout.restoreContentOffset(with: ChatLayoutPositionSnapshot(indexPath: IndexPath(item: last, section: 0), edge: .bottom))
    }

    private var maxContentOffsetY: CGFloat {
        let insets = collectionView.adjustedContentInset
        let end = layout.collectionViewContentSize.height - collectionView.bounds.height + insets.bottom
        return max(-insets.top, end)
    }

    private var isAtEnd: Bool {
        collectionView.contentOffset.y >= maxContentOffsetY - 1
    }

    @objc
    private func didTap() {
        view.window?.endEditing(true)
    }
}

extension ConversationListController: UICollectionViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        followsEnd = false
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            followsEnd = isAtEnd
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        followsEnd = isAtEnd
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        followsEnd = false
    }
}

/// A cell whose height fits its row at the list's width. The default cell
/// measures the hosted view free of width, so a paragraph comes out one
/// line long and gets cut.
private final class ConversationCell: UICollectionViewCell {
    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let width = layoutAttributes.size.width
        let size = contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        layoutAttributes.size = CGSize(width: width, height: size.height)
        return layoutAttributes
    }
}

/// One row of the conversation in SwiftUI.
private struct ConversationRowView: View {
    let item: ConversationItem
    let project: String?
    let openGroups: Set<String>
    let expandedTools: Set<String>
    let showAll: (String) -> Void
    let toggle: (_ tool: String, _ row: String) -> Void
    let answer: @MainActor ([MobileKey]) async -> Void

    var body: some View {
        switch item {
        case .earlier:
            Text("Earlier messages aren't shown.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        case .message(let entry):
            MessageView(entry: entry)
        case .tools(_, let tools):
            ToolGroupView(
                tools: tools,
                project: project,
                showsAll: openGroups.contains(item.id),
                expanded: expandedTools,
                showAll: { showAll(item.id) },
                toggle: { toggle($0, item.id) }
            )
        case .question(let menu):
            QuestionCard(menu: menu, answer: answer)
        case .working(let detail):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(detail.isEmpty ? "Working…" : "Working · \(detail)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("working-row")
        }
    }
}
