import SwiftUI
import WebKit

@MainActor
final class CollabHostPage {
    static let shared = CollabHostPage()

    private var url: URL?
    private var view: WKWebView?

    func webView(for url: URL) -> WKWebView {
        if self.url == url, let view { return view }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
        view.isInspectable = true
        #endif
        view.underPageBackgroundColor = .clear
        view.setValue(false, forKey: "drawsBackground")
        view.load(URLRequest(url: url))
        self.url = url
        self.view = view
        return view
    }

    func prepare(for url: URL?, retaining hiddenURL: URL?) {
        if let url { _ = webView(for: url) }
        else if hiddenURL == nil || hiddenURL != self.url { clear() }
    }

    private func clear() {
        view?.stopLoading()
        view = nil
        url = nil
    }
}

struct CollabHostView: NSViewRepresentable {
    let page: CollabHostPage
    let url: URL

    func makeNSView(context: Context) -> WKWebView { page.webView(for: url) }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
