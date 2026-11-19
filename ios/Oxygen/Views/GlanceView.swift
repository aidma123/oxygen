import SwiftUI
import WebKit

/// Glance: preview a link in a sheet without opening a tab. The page is
/// discarded when the sheet closes unless you promote it to a tab.
@MainActor
final class GlanceModel: ObservableObject {
    let webView: WKWebView
    @Published var title = ""
    private var observation: NSKeyValueObservation?

    init(url: URL, store: BrowserStore) {
        webView = store.makeWebView()
        webView.load(URLRequest(url: url))
        observation = webView.observe(\.title, options: [.new]) { [weak self] view, _ in
            Task { @MainActor in self?.title = view.title ?? "" }
        }
    }
}

struct GlanceView: View {
    @StateObject private var model: GlanceModel
    @Environment(\.dismiss) private var dismiss
    private let store: BrowserStore

    init(item: GlanceItem, store: BrowserStore) {
        self.store = store
        _model = StateObject(wrappedValue: GlanceModel(url: item.url, store: store))
    }

    var body: some View {
        NavigationStack {
            WebViewContainer(webView: model.webView)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(model.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            if let url = model.webView.url {
                                store.openTab(url, foreground: true)
                            }
                            dismiss()
                        } label: {
                            Label("Open as Tab", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                    }
                }
        }
    }
}
