import SwiftUI

/// Same layout as the Windows window: the shared sidebar on the left, the
/// page as a rounded card with an 8 pt margin on the frame, and the same
/// sidebar modes (expanded, collapsed to icons, hidden, and floating "peek").
struct BrowserView: View {
    @EnvironmentObject private var store: BrowserStore

    enum Metrics {
        static let sidebar: CGFloat = 248
        static let rail: CGFloat = 52
        static let margin: CGFloat = 8
        static let radius: CGFloat = 8
    }

    /// Same easing and duration as the Windows sidebar animation.
    static let motion = Animation.timingCurve(0.22, 0.8, 0.24, 1, duration: 0.2)

    private var restingWidth: CGFloat {
        if store.compact { return 0 }
        if store.settings.collapsed || store.narrow { return Metrics.rail }
        return Metrics.sidebar
    }

    private var frame: Color {
        store.frameColor.map { Color(uiColor: $0) } ?? Color(red: 0.9, green: 0.93, blue: 0.97)
    }

    var body: some View {
        GeometryReader { geo in
            let chromeWidth = store.peek ? Metrics.sidebar : restingWidth
            ZStack(alignment: .topLeading) {
                PagesView()
                    .padding(.leading, store.compact ? Metrics.margin : restingWidth)
                    .padding(.trailing, Metrics.margin)
                    .padding(.vertical, Metrics.margin)

                if store.peek && restingWidth < Metrics.sidebar {
                    // Tapping the page closes the floating sidebar (the touch
                    // version of moving the mouse away on Windows).
                    Color.black.opacity(0.06)
                        .contentShape(Rectangle())
                        .onTapGesture { store.setPeek(false) }
                        .transition(.opacity)
                }

                WebViewContainer(webView: store.chrome.webView, background: .clear)
                    .frame(width: max(chromeWidth, 1))
                    .opacity(chromeWidth < 1 ? 0 : 1)
                    .background(frame.opacity(store.peek ? 1 : 0))
                    .shadow(color: .black.opacity(store.peek && restingWidth < Metrics.sidebar ? 0.16 : 0), radius: 18, x: 4)

                if store.compact && !store.peek {
                    // Swiping in from the left edge shows the hidden sidebar
                    // (the touch version of touching the left edge on Windows).
                    Color.clear
                        .frame(width: 16)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 8).onEnded { value in
                            if value.translation.width > 24 { store.setPeek(true) }
                        })
                }
            }
            .onAppear { store.narrow = geo.size.width < 600 }
            .onChange(of: geo.size.width) { store.narrow = $0 < 600 }
        }
        .background(frame.ignoresSafeArea())
        .animation(Self.motion, value: store.mode)
        .fullScreenCover(isPresented: $store.showTabs) {
            TabOverviewView().environmentObject(store)
        }
        .tint(store.accentColor)
        .preferredColorScheme(store.settings.colorScheme)
    }
}

/// The page area: one web view, or two side by side in split view. Each page
/// is its own rounded card, 8 pt apart, like on Windows.
struct PagesView: View {
    @EnvironmentObject private var store: BrowserStore

    var body: some View {
        GeometryReader { geo in
            let ids = store.visibleIDs()
            let wide = geo.size.width > geo.size.height
            let gap = BrowserView.Metrics.margin
            let layout = wide ? AnyLayout(HStackLayout(spacing: gap)) : AnyLayout(VStackLayout(spacing: gap))
            ZStack {
                if !ids.isEmpty {
                    layout {
                        ForEach(ids, id: \.self) { id in
                            Group {
                                if let view = store.loadedWebView(id) {
                                    WebViewContainer(webView: view)
                                } else {
                                    Color(.systemBackground)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: BrowserView.Metrics.radius, style: .continuous))
                        }
                    }
                }
                if let item = store.glance {
                    // Glance: a floating panel over the page, same size as on Windows.
                    GlanceView(item: item, store: store)
                        .id(item.id)
                        .frame(width: geo.size.width * 0.88, height: geo.size.height * 0.9)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.22), radius: 24, y: 6)
                        .transition(.scale(scale: 0.97).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(BrowserView.motion, value: store.glance?.id)
        }
    }
}
