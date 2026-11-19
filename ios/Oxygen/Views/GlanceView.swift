import SwiftUI
import WebKit

/// Glance: preview a link in a floating panel without opening a tab. Uses the
/// same injected toolbar (glance.js) as Windows: open as tab, and close.
@MainActor
final class GlanceModel: ObservableObject {
    private(set) var webView: WKWebView!

    init(url: URL, store: BrowserStore) {
        webView = store.makeWebView(script: Shared.glanceJS) { [weak self, weak store] message in
            guard let store else { return }
            switch message {
            case "close":
                store.glance = nil
            case "expand":
                let current = self?.webView.url ?? url
                store.glance = nil
                store.openTab(current, foreground: true)
            default:
                break
            }
        }
        webView.load(URLRequest(url: url))
    }
}

struct GlanceView: View {
    @StateObject private var model: GlanceModel

    init(item: GlanceItem, store: BrowserStore) {
        _model = StateObject(wrappedValue: GlanceModel(url: item.url, store: store))
    }

    var body: some View {
        WebViewContainer(webView: model.webView)
    }
}
