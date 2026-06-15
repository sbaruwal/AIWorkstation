import SwiftUI
import WebKit

/// Owns one embedded `WKWebView` for a browser node and tracks its navigation state.
/// Kept alive across SwiftUI re-renders (like `TerminalController`) so panning/zooming
/// the canvas never reloads the page.
@MainActor
final class BrowserController: NSObject, ObservableObject, WKNavigationDelegate {
    let id: UUID
    let webView: WKWebView

    /// Hide this browser's web surface while a Focus Mode cockpit is up. A `WKWebView`
    /// composites in its own WebContent-process layer/IOSurface that sits *above* the
    /// SwiftUI hosting layer, so `.zIndex` can't push the focus overlay over it — it
    /// punches through. Setting `isHidden` drops that layer (and its surface) from the
    /// compositing pass, so there's nothing left to punch through. NOT an unmount: the
    /// NSView stays in the hierarchy and the page keeps running, so toggling back off
    /// re-presents the live page with no reload.
    @Published var isSuppressed = false {
        didSet {
            guard isSuppressed != oldValue else { return }
            webView.isHidden = isSuppressed
        }
    }

    @Published private(set) var pageTitle: String = ""
    @Published var addressText: String = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false

    init(id: UUID, url: URL) {
        self.id = id
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                            configuration: WKWebViewConfiguration())
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        addressText = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    private func sync() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        pageTitle = webView.title ?? ""
        if let u = webView.url { addressText = u.absoluteString }
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stopLoading() { webView.stopLoading() }

    /// Navigate to whatever is in the address field (resolved like a command target).
    func loadAddress() { webView.load(URLRequest(url: BrowserURL.resolve(addressText))) }

    /// Navigate to a specific URL (used by command-bar "<name> go to …").
    func load(_ url: URL) {
        addressText = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func stop() {
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    /// Short title for the header — the page title, else the host.
    var displayTitle: String {
        if !pageTitle.isEmpty { return pageTitle }
        return webView.url?.host ?? "Browser"
    }

    // MARK: WKNavigationDelegate (WebKit calls these on the main thread; hop explicitly)

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in self.isLoading = true }
    }
    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Task { @MainActor in self.sync() }
    }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.sync() }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.sync() }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.sync() }
    }
}

/// In-memory registry of live browser controllers, keyed by panel id — mirrors
/// `TerminalRegistry`. The web view (and thus page state) survives re-renders.
@MainActor
final class BrowserRegistry {
    private var controllers: [UUID: BrowserController] = [:]

    func controller(for panel: PanelModel) -> BrowserController {
        if let existing = controllers[panel.id] { return existing }
        let url = BrowserURL.resolve(panel.browserURL ?? "https://www.google.com")
        let controller = BrowserController(id: panel.id, url: url)
        controllers[panel.id] = controller
        return controller
    }

    /// Existing controller without creating one — lets Focus Mode suppress live
    /// browsers without lazily minting WKWebViews for browser panels on other canvases.
    func existingController(for id: UUID) -> BrowserController? { controllers[id] }

    func remove(_ id: UUID) {
        controllers[id]?.stop()
        controllers[id] = nil
    }
}

/// Mounts the controller's live `WKWebView` inside SwiftUI (kept alive by the
/// controller; detached from any prior host before remount).
struct WebHostView: NSViewRepresentable {
    @ObservedObject var controller: BrowserController

    func makeNSView(context: Context) -> WKWebView {
        let view = controller.webView
        view.removeFromSuperview()
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
