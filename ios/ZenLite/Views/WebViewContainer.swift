import SwiftUI
import WebKit

/// Hosts an existing WKWebView. Switching tabs re-parents the web view instead
/// of recreating it, so pages keep their state while loaded.
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemBackground
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        attach(to: container)
    }

    private func attach(to container: UIView) {
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }
}

struct FaviconView: View {
    let tab: TabRecord
    var size: CGFloat = 18

    private var iconURL: URL? {
        guard let scheme = tab.url.scheme, let host = tab.url.host, scheme.hasPrefix("http") else { return nil }
        return URL(string: "\(scheme)://\(host)/favicon.ico")
    }

    var body: some View {
        AsyncImage(url: iconURL) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high)
            } else {
                letter
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }

    private var letter: some View {
        RoundedRectangle(cornerRadius: size * 0.22)
            .fill(Color.accentColor)
            .overlay(
                Text(String(tab.displayTitle.prefix(1)).uppercased())
                    .font(.system(size: size * 0.6, weight: .bold))
                    .foregroundColor(.white)
            )
    }
}
