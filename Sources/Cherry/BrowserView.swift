import AppKit
import SwiftUI
import WebKit

struct BrowserPaneView: View {
    @ObservedObject var workspace: BrowserWorkspace
    let isActivePane: Bool
    let onActivate: () -> Void
    let onCloseBrowser: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            BrowserTabStrip(
                workspace: workspace,
                onCloseLastTab: onCloseBrowser
            )

            Divider()

            if let tab = workspace.selectedTab {
                BrowserNavigationBar(workspace: workspace, tab: tab)

                Divider()

                ZStack(alignment: .top) {
                    BrowserWebViewHost(webView: tab.webView, onActivate: onActivate)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if tab.isLoading {
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(
                                    width: geometry.size.width * max(0.04, tab.estimatedProgress),
                                    height: 2
                                )
                                .animation(.easeOut(duration: 0.15), value: tab.estimatedProgress)
                        }
                        .frame(height: 2)
                    }

                    if let error = tab.errorMessage, !error.isEmpty {
                        BrowserErrorBanner(message: error) {
                            tab.setError(nil)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("No Browser Tabs", systemImage: "globe")
                } description: {
                    Text("Open a tab to start browsing.")
                } actions: {
                    Button("New Tab") {
                        _ = workspace.addTab()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isActivePane ? Color.accentColor.opacity(0.42) : Color.clear,
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded(onActivate))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project browser")
    }
}

private struct BrowserTabStrip: View {
    @ObservedObject var workspace: BrowserWorkspace
    let onCloseLastTab: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(workspace.tabs) { tab in
                        BrowserTabButton(
                            tab: tab,
                            isSelected: workspace.selectedTabID == tab.id,
                            select: { workspace.selectTab(tab.id) },
                            close: { close(tab) }
                        )
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
            }
            .scrollIndicators(.hidden)

            Divider()
                .frame(height: 20)

            Button {
                _ = workspace.addTab()
                workspace.requestAddressFocus()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 27, height: 27)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("New Browser Tab (⌘T)")
            .padding(.horizontal, 6)
        }
        .frame(height: 38)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.78))
    }

    private func close(_ tab: BrowserTab) {
        if workspace.tabs.count <= 1 {
            onCloseLastTab()
        } else {
            _ = workspace.closeTab(tab.id)
        }
    }
}

private struct BrowserTabButton: View {
    @ObservedObject var tab: BrowserTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 7) {
            Button(action: select) {
                HStack(spacing: 7) {
                    Group {
                        if tab.isLoading {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "globe")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 14, height: 14)

                    Text(tab.title)
                        .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: 150, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHovered || isSelected {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 17, height: 17)
                        .background {
                            Circle().fill(Color.primary.opacity(isHovered ? 0.09 : 0))
                        }
                }
                .buttonStyle(.plain)
                .help("Close Browser Tab")
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .frame(height: 28)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(backgroundColor)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(isSelected ? 0.10 : 0), lineWidth: 0.5)
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Close Tab", action: close)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tab.title)
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color(nsColor: .windowBackgroundColor)
        }
        if isHovered {
            return Color.primary.opacity(0.055)
        }
        return .clear
    }
}

private struct BrowserNavigationBar: View {
    @ObservedObject var workspace: BrowserWorkspace
    @ObservedObject var tab: BrowserTab

    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            BrowserToolbarButton(
                symbol: "chevron.left",
                help: "Back",
                enabled: tab.canGoBack
            ) {
                _ = try? workspace.goBack(tabID: tab.id)
            }

            BrowserToolbarButton(
                symbol: "chevron.right",
                help: "Forward",
                enabled: tab.canGoForward
            ) {
                _ = try? workspace.goForward(tabID: tab.id)
            }

            BrowserToolbarButton(
                symbol: tab.isLoading ? "xmark" : "arrow.clockwise",
                help: tab.isLoading ? "Stop" : "Reload"
            ) {
                if tab.isLoading {
                    _ = try? workspace.stopLoading(tabID: tab.id)
                } else {
                    _ = try? workspace.reload(tabID: tab.id)
                }
            }

            HStack(spacing: 7) {
                Image(systemName: securitySymbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField("Search or enter address", text: $address)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($addressFocused)
                    .onSubmit(navigate)

                if addressFocused, !address.isEmpty {
                    Button {
                        address = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.065))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        addressFocused ? Color.accentColor.opacity(0.52) : Color.primary.opacity(0.08),
                        lineWidth: addressFocused ? 1 : 0.5
                    )
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            address = tab.displayAddress
            if address.isEmpty {
                DispatchQueue.main.async {
                    addressFocused = true
                }
            }
        }
        .onChange(of: tab.id) { _, _ in
            address = tab.displayAddress
            addressFocused = address.isEmpty
        }
        .onChange(of: tab.url) { _, _ in
            guard !addressFocused else { return }
            address = tab.displayAddress
        }
        .onChange(of: workspace.addressFocusRequest) { _, _ in
            address = tab.displayAddress
            addressFocused = true
        }
    }

    private var securitySymbol: String {
        switch tab.url?.scheme?.lowercased() {
        case "https": "lock.fill"
        case "http": "exclamationmark.triangle.fill"
        default: "magnifyingglass"
        }
    }

    private func navigate() {
        do {
            try workspace.navigate(address, tabID: tab.id)
            addressFocused = false
        } catch {
            tab.setError(error.localizedDescription)
        }
    }
}

private struct BrowserToolbarButton: View {
    let symbol: String
    let help: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 27, height: 27)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.34)
        .help(help)
    }
}

private struct BrowserErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(message)
                .font(.system(size: 12))
                .lineLimit(2)

            Spacer(minLength: 8)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

private struct BrowserWebViewHost: NSViewRepresentable {
    let webView: WKWebView
    let onActivate: () -> Void

    func makeNSView(context: Context) -> BrowserWebViewContainer {
        let container = BrowserWebViewContainer()
        container.onActivate = onActivate
        container.setWebView(webView)
        return container
    }

    func updateNSView(_ nsView: BrowserWebViewContainer, context: Context) {
        nsView.onActivate = onActivate
        nsView.setWebView(webView)
    }
}

private final class BrowserWebViewContainer: NSView {
    var onActivate: (() -> Void)?
    private weak var installedWebView: WKWebView?
    private nonisolated(unsafe) var mouseMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        guard window != nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            _ = MainActor.assumeIsolated {
                guard let self,
                      event.window === self.window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                else {
                    return false
                }
                self.onActivate?()
                return true
            }
            return event
        }
    }

    func setWebView(_ webView: WKWebView) {
        guard installedWebView !== webView else { return }
        installedWebView?.removeFromSuperview()
        installedWebView = webView
        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }
}
