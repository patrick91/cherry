import AppKit
import CherryControl
import CoreFoundation
import CryptoKit
import Foundation
import WebKit

enum BrowserWorkspaceError: LocalizedError {
    case invalidAddress(String)
    case unsupportedScheme(String)
    case tabNotFound
    case staleElementReference
    case elementNotFound(String)
    case actionFailed(String)
    case loadTimedOut
    case unsupportedJavaScriptResult

    var errorDescription: String? {
        switch self {
        case .invalidAddress(let address):
            "Invalid browser address: \(address)"
        case .unsupportedScheme(let scheme):
            "The browser does not allow the \(scheme) URL scheme."
        case .tabNotFound:
            "The requested browser tab does not exist."
        case .staleElementReference:
            "The browser element reference belongs to an older document. Take a new snapshot and retry."
        case .elementNotFound(let reference):
            "No browser element exists for reference \(reference). Take a new snapshot and retry."
        case .actionFailed(let message):
            message
        case .loadTimedOut:
            "The browser did not finish loading before the timeout."
        case .unsupportedJavaScriptResult:
            "The browser JavaScript result is not JSON-compatible."
        }
    }
}

struct BrowserPageElement: Equatable, Sendable {
    let ref: String
    let role: String
    let name: String
    let value: String?
    let disabled: Bool?
    let selected: Bool?
}

struct BrowserPageSnapshot: Equatable, Sendable {
    let tabID: UUID
    let url: String?
    let title: String
    let documentGeneration: Int
    let elements: [BrowserPageElement]
    let text: String
}

struct BrowserPageScreenshot: Sendable {
    let tabID: UUID
    let url: String?
    let title: String
    let pngData: Data
}

@MainActor
final class BrowserWorkspace: ObservableObject, Identifiable {
    let id = UUID()
    let projectRoot: String?

    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var selectedTabID: UUID?
    @Published private(set) var addressFocusRequest = 0

    private let websiteDataStore: WKWebsiteDataStore

    init(projectRoot: String?) {
        self.projectRoot = projectRoot
        if let projectRoot {
            websiteDataStore = WKWebsiteDataStore(
                forIdentifier: Self.websiteDataStoreIdentifier(projectRoot: projectRoot)
            )
        } else {
            websiteDataStore = .nonPersistent()
        }

        _ = addTab(select: true)
    }

    var selectedTab: BrowserTab? {
        guard let selectedTabID else { return tabs.first }
        return tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    @discardableResult
    func addTab(url: String? = nil, select: Bool = true) -> BrowserTab {
        let tab = BrowserTab(dataStore: websiteDataStore)
        tab.openNewTab = { [weak self] url in
            guard let self else { return }
            _ = self.addTab(url: url.absoluteString, select: true)
        }
        tabs.append(tab)
        if select || selectedTabID == nil {
            selectedTabID = tab.id
        }

        if let url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                try navigate(url, tabID: tab.id)
            } catch {
                tab.setError(error.localizedDescription)
            }
        } else {
            tab.loadBlankPage()
        }
        return tab
    }

    @discardableResult
    func closeTab(_ tabID: UUID? = nil) -> BrowserTab? {
        guard let tab = tab(for: tabID),
              let index = tabs.firstIndex(where: { $0.id == tab.id })
        else {
            return nil
        }

        let wasSelected = selectedTabID == tab.id
        tabs.remove(at: index)
        tab.prepareForClose()

        if tabs.isEmpty {
            selectedTabID = nil
        } else if wasSelected {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
        return tab
    }

    func selectTab(_ tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        selectedTabID = tabID
    }

    func requestAddressFocus() {
        addressFocusRequest &+= 1
    }

    func tab(for requestedID: UUID? = nil) -> BrowserTab? {
        if let requestedID {
            return tabs.first { $0.id == requestedID }
        }
        return selectedTab
    }

    func requireTab(_ requestedID: UUID? = nil) throws -> BrowserTab {
        guard let tab = tab(for: requestedID) else {
            throw BrowserWorkspaceError.tabNotFound
        }
        return tab
    }

    @discardableResult
    func navigate(_ address: String, tabID: UUID? = nil) throws -> BrowserTab {
        let tab = try requireTab(tabID)
        let url = try Self.url(for: address)
        tab.setError(nil)
        if url.absoluteString == "about:blank" {
            tab.loadBlankPage()
        } else {
            tab.load(URLRequest(url: url))
        }
        return tab
    }

    @discardableResult
    func goBack(tabID: UUID? = nil) throws -> BrowserTab {
        let tab = try requireTab(tabID)
        if tab.webView.canGoBack {
            let version = tab.beginNavigationRequest()
            tab.record(tab.webView.goBack(), forNavigationVersion: version)
        }
        return tab
    }

    @discardableResult
    func goForward(tabID: UUID? = nil) throws -> BrowserTab {
        let tab = try requireTab(tabID)
        if tab.webView.canGoForward {
            let version = tab.beginNavigationRequest()
            tab.record(tab.webView.goForward(), forNavigationVersion: version)
        }
        return tab
    }

    @discardableResult
    func reload(tabID: UUID? = nil) throws -> BrowserTab {
        let tab = try requireTab(tabID)
        tab.setError(nil)
        if tab.webView.url == nil {
            tab.loadBlankPage()
        } else {
            let version = tab.beginNavigationRequest()
            tab.record(tab.webView.reload(), forNavigationVersion: version)
        }
        return tab
    }

    @discardableResult
    func stopLoading(tabID: UUID? = nil) throws -> BrowserTab {
        let tab = try requireTab(tabID)
        tab.webView.stopLoading()
        tab.finishNavigationRequest()
        return tab
    }

    func waitForLoad(
        tabID: UUID? = nil,
        timeoutMilliseconds: Int = 30_000
    ) async throws -> BrowserTab {
        let tab = try requireTab(tabID)
        let timeout = min(max(timeoutMilliseconds, 100), 120_000)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(timeout))
        let graceDeadline = clock.now.advanced(by: .milliseconds(150))
        var targetNavigationVersion = tab.navigationRequestVersion
        var observedNavigation = tab.isLoading
            || tab.completedNavigationRequestVersion < targetNavigationVersion

        while clock.now < deadline {
            if tab.navigationRequestVersion > targetNavigationVersion {
                targetNavigationVersion = tab.navigationRequestVersion
                observedNavigation = true
            }
            if tab.isLoading {
                observedNavigation = true
            }
            if !tab.isLoading,
               tab.errorMessage != nil,
               (observedNavigation || clock.now >= graceDeadline) {
                return tab
            }
            if !tab.isLoading,
               tab.completedNavigationRequestVersion >= targetNavigationVersion,
               (observedNavigation || clock.now >= graceDeadline) {
                let readyState: String?
                do {
                    readyState = try await tab.webView.evaluateJavaScript("document.readyState") as? String
                } catch {
                    readyState = nil
                }
                if readyState == "complete"
                    || readyState == "interactive"
                    || tab.webView.url?.scheme == "about"
                    || tab.errorMessage != nil {
                    return tab
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw BrowserWorkspaceError.loadTimedOut
    }

    func snapshot(tabID: UUID? = nil) async throws -> BrowserPageSnapshot {
        let tab = try requireTab(tabID)
        let generation = tab.documentGeneration
        let result = try await tab.webView.evaluateJavaScript(Self.snapshotScript)
        guard let payload = result as? [String: Any],
              let rawElements = payload["elements"] as? [[String: Any]]
        else {
            throw BrowserWorkspaceError.actionFailed("Cherry could not read the browser page snapshot.")
        }

        let elements = rawElements.compactMap { raw -> BrowserPageElement? in
            guard let localReference = raw["ref"] as? String,
                  let role = raw["role"] as? String,
                  let name = raw["name"] as? String
            else {
                return nil
            }
            return BrowserPageElement(
                ref: "\(generation):\(localReference)",
                role: role,
                name: name,
                value: raw["value"] as? String,
                disabled: raw["disabled"] as? Bool,
                selected: raw["selected"] as? Bool
            )
        }

        let bodyText = (payload["bodyText"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let elementLines = elements.map { element in
            var details = "\(element.role) \"\(element.name)\" [ref=\(element.ref)]"
            if let value = element.value, !value.isEmpty {
                details += " value=\"\(value)\""
            }
            if element.disabled == true { details += " disabled" }
            if element.selected == true { details += " selected" }
            return details
        }
        let compactText = ([bodyText] + elementLines)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return BrowserPageSnapshot(
            tabID: tab.id,
            url: tab.url?.absoluteString,
            title: tab.title,
            documentGeneration: generation,
            elements: elements,
            text: String(compactText.prefix(24_000))
        )
    }

    func screenshot(tabID: UUID? = nil) async throws -> BrowserPageScreenshot {
        let tab = try requireTab(tabID)
        let configuration = WKSnapshotConfiguration()
        if !tab.webView.bounds.isEmpty {
            configuration.rect = tab.webView.bounds
        }
        let image = try await tab.webView.takeSnapshot(configuration: configuration)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            throw BrowserWorkspaceError.actionFailed("Cherry could not encode the browser screenshot.")
        }
        return BrowserPageScreenshot(
            tabID: tab.id,
            url: tab.url?.absoluteString,
            title: tab.title,
            pngData: pngData
        )
    }

    func click(elementRef: String, tabID: UUID? = nil) async throws -> BrowserTab {
        let tab = try requireTab(tabID)
        let localReference = try localElementReference(elementRef, for: tab)
        let result = try await tab.webView.callAsyncJavaScript(
            Self.clickScript,
            arguments: ["reference": localReference],
            contentWorld: .page
        )
        try validateActionResult(result, elementRef: elementRef)
        return tab
    }

    func type(
        text: String,
        elementRef: String,
        clear: Bool = true,
        tabID: UUID? = nil
    ) async throws -> BrowserTab {
        let tab = try requireTab(tabID)
        let localReference = try localElementReference(elementRef, for: tab)
        let result = try await tab.webView.callAsyncJavaScript(
            Self.typeScript,
            arguments: [
                "reference": localReference,
                "text": text,
                "clear": clear,
            ],
            contentWorld: .page
        )
        try validateActionResult(result, elementRef: elementRef)
        return tab
    }

    func press(
        key: String,
        modifiers: [String] = [],
        tabID: UUID? = nil
    ) async throws -> BrowserTab {
        let tab = try requireTab(tabID)
        let normalizedModifiers = Set(modifiers.map { $0.lowercased() })
        let supportedModifiers: Set<String> = ["shift", "control", "option", "alt", "command", "meta"]
        guard normalizedModifiers.isSubset(of: supportedModifiers) else {
            throw BrowserWorkspaceError.actionFailed("browser_press received an unsupported modifier.")
        }
        let result = try await tab.webView.callAsyncJavaScript(
            Self.pressScript,
            arguments: [
                "key": key,
                "shift": normalizedModifiers.contains("shift"),
                "control": normalizedModifiers.contains("control"),
                "alt": normalizedModifiers.contains("option") || normalizedModifiers.contains("alt"),
                "meta": normalizedModifiers.contains("command") || normalizedModifiers.contains("meta"),
            ],
            contentWorld: .page
        )
        guard (result as? Bool) == true else {
            throw BrowserWorkspaceError.actionFailed("Cherry could not send the browser key press.")
        }
        return tab
    }

    func scroll(
        deltaX: Int = 0,
        deltaY: Int = 0,
        tabID: UUID? = nil
    ) async throws -> BrowserTab {
        let tab = try requireTab(tabID)
        _ = try await tab.webView.callAsyncJavaScript(
            "window.scrollBy({ left: deltaX, top: deltaY, behavior: 'instant' }); return true;",
            arguments: ["deltaX": deltaX, "deltaY": deltaY],
            contentWorld: .page
        )
        return tab
    }

    func evaluate(
        script: String,
        arguments: [String: BrowserJSONValue] = [:],
        tabID: UUID? = nil
    ) async throws -> BrowserJSONValue {
        let tab = try requireTab(tabID)
        let foundationArguments = arguments.mapValues(Self.foundationValue)
        let result = try await tab.webView.callAsyncJavaScript(
            script,
            arguments: foundationArguments,
            contentWorld: .page
        )
        return try Self.jsonValue(result)
    }

    private func localElementReference(_ reference: String, for tab: BrowserTab) throws -> String {
        let parts = reference.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let generation = Int(parts[0]) else {
            throw BrowserWorkspaceError.staleElementReference
        }
        guard generation == tab.documentGeneration else {
            throw BrowserWorkspaceError.staleElementReference
        }
        return parts[1]
    }

    private func validateActionResult(_ result: Any?, elementRef: String) throws {
        guard let payload = result as? [String: Any] else {
            throw BrowserWorkspaceError.actionFailed("Cherry could not complete the browser action.")
        }
        if payload["ok"] as? Bool == true { return }
        if payload["reason"] as? String == "not_found" {
            throw BrowserWorkspaceError.elementNotFound(elementRef)
        }
        throw BrowserWorkspaceError.actionFailed(
            payload["message"] as? String ?? "Cherry could not complete the browser action."
        )
    }

    private static func url(for rawAddress: String) throws -> URL {
        let address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            throw BrowserWorkspaceError.invalidAddress(rawAddress)
        }

        let lowercased = address.lowercased()
        let local = lowercased == "localhost"
            || lowercased.hasPrefix("localhost:")
            || lowercased.hasPrefix("127.")
            || lowercased.hasPrefix("[::1]")
        if local, !address.contains(where: \Character.isWhitespace) {
            guard let url = URL(string: "http://\(address)") else {
                throw BrowserWorkspaceError.invalidAddress(rawAddress)
            }
            return url
        }

        if let components = URLComponents(string: address),
           let scheme = components.scheme?.lowercased(),
           !scheme.isEmpty {
            guard ["http", "https", "about"].contains(scheme) else {
                throw BrowserWorkspaceError.unsupportedScheme(scheme)
            }
            guard let url = components.url else {
                throw BrowserWorkspaceError.invalidAddress(rawAddress)
            }
            return url
        }

        if address.contains(where: \Character.isWhitespace) {
            var search = URLComponents(string: "https://www.google.com/search")
            search?.queryItems = [URLQueryItem(name: "q", value: address)]
            guard let url = search?.url else {
                throw BrowserWorkspaceError.invalidAddress(rawAddress)
            }
            return url
        }

        let candidate = "https://\(address)"
        guard let url = URL(string: candidate) else {
            throw BrowserWorkspaceError.invalidAddress(rawAddress)
        }
        return url
    }

    private static func websiteDataStoreIdentifier(projectRoot: String) -> UUID {
        let digest = SHA256.hash(data: Data("cherry-browser:\(projectRoot)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func foundationValue(_ value: BrowserJSONValue) -> Any {
        switch value {
        case .null:
            NSNull()
        case .bool(let value):
            value
        case .int(let value):
            value
        case .double(let value):
            value
        case .string(let value):
            value
        case .array(let values):
            values.map(foundationValue)
        case .object(let values):
            values.mapValues(foundationValue)
        }
    }

    private static func jsonValue(_ rawValue: Any?) throws -> BrowserJSONValue {
        guard let rawValue else { return .null }
        if rawValue is NSNull { return .null }
        if let value = rawValue as? String { return .string(value) }
        if let value = rawValue as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            let doubleValue = value.doubleValue
            if doubleValue.isFinite,
               doubleValue.rounded(.towardZero) == doubleValue,
               doubleValue >= Double(Int.min),
               doubleValue <= Double(Int.max) {
                return .int(value.intValue)
            }
            guard doubleValue.isFinite else {
                throw BrowserWorkspaceError.unsupportedJavaScriptResult
            }
            return .double(doubleValue)
        }
        if let values = rawValue as? [Any] {
            return .array(try values.map(jsonValue))
        }
        if let values = rawValue as? [String: Any] {
            return .object(try values.mapValues(jsonValue))
        }
        throw BrowserWorkspaceError.unsupportedJavaScriptResult
    }

    private static let snapshotScript = #"""
    (() => {
      const selector = [
        'a[href]', 'button', 'input:not([type="hidden"])', 'textarea', 'select',
        'summary', '[role]', '[contenteditable="true"]', '[tabindex]:not([tabindex="-1"])'
      ].join(',');
      const visible = (element) => {
        const style = window.getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
      };
      const textForIDRefs = (value) => (value || '').split(/\s+/).map((id) => {
        const node = document.getElementById(id);
        return node ? (node.innerText || node.textContent || '') : '';
      }).join(' ').trim();
      const roleFor = (element) => {
        if (element.getAttribute('role')) return element.getAttribute('role');
        const tag = element.tagName.toLowerCase();
        if (tag === 'a') return 'link';
        if (tag === 'button') return 'button';
        if (tag === 'textarea') return 'textbox';
        if (tag === 'select') return 'combobox';
        if (tag === 'summary') return 'button';
        if (tag === 'input') {
          const type = (element.type || 'text').toLowerCase();
          if (type === 'checkbox') return 'checkbox';
          if (type === 'radio') return 'radio';
          if (['button', 'submit', 'reset'].includes(type)) return 'button';
          return 'textbox';
        }
        if (element.isContentEditable) return 'textbox';
        return tag;
      };
      const elements = Array.from(document.querySelectorAll(selector))
        .filter(visible)
        .slice(0, 500)
        .map((element, index) => {
          const ref = `element-${index + 1}`;
          element.setAttribute('data-cherry-browser-ref', ref);
          const labelled = textForIDRefs(element.getAttribute('aria-labelledby'));
          const name = (
            element.getAttribute('aria-label') || labelled || element.getAttribute('alt') ||
            element.getAttribute('title') || element.getAttribute('placeholder') ||
            element.innerText || element.value || ''
          ).replace(/\s+/g, ' ').trim().slice(0, 500);
          const value = ('value' in element && typeof element.value === 'string')
            ? element.value.slice(0, 1000)
            : null;
          const disabled = ('disabled' in element) ? Boolean(element.disabled) : null;
          const selected = ('checked' in element) ? Boolean(element.checked)
            : (element.getAttribute('aria-selected') === 'true' ? true : null);
          return { ref, role: roleFor(element), name, value, disabled, selected };
        });
      const bodyText = (document.body?.innerText || '').replace(/\n{3,}/g, '\n\n').trim().slice(0, 12000);
      return { elements, bodyText };
    })()
    """#

    private static let clickScript = #"""
    const element = document.querySelector(`[data-cherry-browser-ref="${CSS.escape(reference)}"]`);
    if (!element) return { ok: false, reason: 'not_found' };
    if (element.disabled || element.getAttribute('aria-disabled') === 'true') {
      return { ok: false, reason: 'disabled', message: 'The requested browser element is disabled.' };
    }
    element.scrollIntoView({ block: 'center', inline: 'center' });
    element.focus({ preventScroll: true });
    element.click();
    return { ok: true };
    """#

    private static let typeScript = #"""
    const element = document.querySelector(`[data-cherry-browser-ref="${CSS.escape(reference)}"]`);
    if (!element) return { ok: false, reason: 'not_found' };
    if (element.disabled || element.readOnly || element.getAttribute('aria-disabled') === 'true') {
      return { ok: false, reason: 'disabled', message: 'The requested browser element cannot be edited.' };
    }
    element.scrollIntoView({ block: 'center', inline: 'center' });
    element.focus({ preventScroll: true });
    if (element.isContentEditable) {
      element.textContent = clear ? text : (element.textContent || '') + text;
    } else if ('value' in element) {
      const nextValue = clear ? text : String(element.value || '') + text;
      const prototype = element instanceof HTMLTextAreaElement
        ? HTMLTextAreaElement.prototype
        : HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
      if (setter) setter.call(element, nextValue); else element.value = nextValue;
    } else {
      return { ok: false, reason: 'not_editable', message: 'The requested browser element is not editable.' };
    }
    element.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
    element.dispatchEvent(new Event('change', { bubbles: true }));
    return { ok: true };
    """#

    private static let pressScript = #"""
    const target = document.activeElement || document.body;
    if (!target) return false;
    const options = { key, shiftKey: shift, ctrlKey: control, altKey: alt, metaKey: meta, bubbles: true, cancelable: true };
    const allowed = target.dispatchEvent(new KeyboardEvent('keydown', options));
    if (allowed && key === 'Enter') {
      if (target instanceof HTMLTextAreaElement && !meta && !control) {
        const start = target.selectionStart ?? target.value.length;
        const end = target.selectionEnd ?? start;
        target.setRangeText('\n', start, end, 'end');
        target.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertLineBreak', data: null }));
      } else if (target instanceof HTMLButtonElement) {
        target.click();
      } else if (target.form) {
        target.form.requestSubmit();
      }
    } else if (allowed && key === 'Tab') {
      const candidates = Array.from(document.querySelectorAll('a[href], button, input, textarea, select, [tabindex]:not([tabindex="-1"])'))
        .filter((element) => !element.disabled && element.getClientRects().length > 0);
      const index = candidates.indexOf(target);
      const offset = shift ? -1 : 1;
      const next = candidates[(index + offset + candidates.length) % candidates.length];
      next?.focus();
    }
    target.dispatchEvent(new KeyboardEvent('keyup', options));
    return true;
    """#
}

@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let webView: WKWebView

    @Published private(set) var title = "New Tab"
    @Published private(set) var url: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var estimatedProgress = 0.0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var documentGeneration = 0

    private(set) var navigationRequestVersion = 0
    private(set) var completedNavigationRequestVersion = 0

    var openNewTab: ((URL) -> Void)?

    private var observations: [NSKeyValueObservation] = []
    private var navigationVersions: [ObjectIdentifier: Int] = [:]

    init(dataStore: WKWebsiteDataStore) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1_280, height: 800), configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        installObservations()
    }

    var displayAddress: String {
        guard let url else { return "" }
        return url.absoluteString == "about:blank" ? "" : url.absoluteString
    }

    func setError(_ message: String?) {
        errorMessage = message
    }

    func loadBlankPage() {
        setError(nil)
        loadHTMLString(
            """
            <!doctype html>
            <meta name="color-scheme" content="light dark">
            <style>html, body { margin: 0; min-height: 100%; background: Canvas; color: CanvasText; }</style>
            """,
            baseURL: URL(string: "about:blank")
        )
    }

    func load(_ request: URLRequest) {
        let version = beginNavigationRequest()
        record(webView.load(request), forNavigationVersion: version)
    }

    func loadHTMLString(_ html: String, baseURL: URL? = nil) {
        let version = beginNavigationRequest()
        record(webView.loadHTMLString(html, baseURL: baseURL), forNavigationVersion: version)
    }

    @discardableResult
    func beginNavigationRequest() -> Int {
        navigationRequestVersion &+= 1
        return navigationRequestVersion
    }

    func record(_ navigation: WKNavigation?, forNavigationVersion version: Int) {
        guard let navigation else {
            completedNavigationRequestVersion = max(completedNavigationRequestVersion, version)
            return
        }
        navigationVersions[ObjectIdentifier(navigation)] = version
    }

    func finishNavigationRequest() {
        completedNavigationRequestVersion = navigationRequestVersion
        navigationVersions.removeAll()
    }

    private func ensureNavigationVersion(for navigation: WKNavigation?) {
        guard let navigation else { return }
        let identifier = ObjectIdentifier(navigation)
        guard navigationVersions[identifier] == nil else { return }
        navigationVersions[identifier] = beginNavigationRequest()
    }

    private func finish(_ navigation: WKNavigation?) {
        guard let navigation else { return }
        let identifier = ObjectIdentifier(navigation)
        guard let version = navigationVersions.removeValue(forKey: identifier) else { return }
        completedNavigationRequestVersion = max(completedNavigationRequestVersion, version)
    }

    func prepareForClose() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        observations.removeAll()
        openNewTab = nil
    }

    private func installObservations() {
        observations = [
            webView.observe(\.title, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? nil
                Task { @MainActor [weak self] in
                    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self?.title = trimmed.isEmpty ? "New Tab" : trimmed
                }
            },
            webView.observe(\.url, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? nil
                Task { @MainActor [weak self] in self?.url = value }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? false
                Task { @MainActor [weak self] in self?.isLoading = value }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? 0
                Task { @MainActor [weak self] in self?.estimatedProgress = value }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? false
                Task { @MainActor [weak self] in self?.canGoBack = value }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? false
                Task { @MainActor [weak self] in self?.canGoForward = value }
            },
        ]
    }
}

extension BrowserTab: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload {
            setError("Downloads are disabled in Cherry's project browser.")
            return .cancel
        }

        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            openNewTab?(url)
            return .cancel
        }

        if let scheme = navigationAction.request.url?.scheme?.lowercased(),
           !["http", "https", "about"].contains(scheme) {
            setError("The \(scheme) URL scheme is blocked in Cherry's project browser.")
            return .cancel
        }
        return .allow
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        if let response = navigationResponse.response as? HTTPURLResponse,
           response.value(forHTTPHeaderField: "Content-Disposition")?
            .localizedCaseInsensitiveContains("attachment") == true {
            setError("Downloads are disabled in Cherry's project browser.")
            return .cancel
        }
        guard navigationResponse.canShowMIMEType else {
            setError("Downloads are disabled in Cherry's project browser.")
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        ensureNavigationVersion(for: navigation)
        setError(nil)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        documentGeneration &+= 1
        setError(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(navigation)
        setError(nil)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        setNavigationError(error, navigation: navigation)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        setNavigationError(error, navigation: navigation)
    }

    private func setNavigationError(_ error: any Error, navigation: WKNavigation?) {
        let nsError = error as NSError
        finish(navigation)
        guard nsError.code != NSURLErrorCancelled else { return }
        setError(error.localizedDescription)
    }
}

extension BrowserTab: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        setError("File uploads are disabled in Cherry's project browser.")
        return nil
    }

    func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        .prompt
    }
}
