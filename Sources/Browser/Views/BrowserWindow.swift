import SwiftUI
import WebKit

/// ウインドウの中身。上からツールバー、タブバー、ページ。
struct BrowserWindow: View {
    let store: TabStore

    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            if let tab = store.selected {
                NavigationRow(tab: tab, focusRequest: store.addressFocusRequest)
            }
            TabBar(store: store) { id in
                if !store.close(id) {
                    dismissWindow(id: BrowserApp.windowID)
                }
            }
            Divider()
            if let tab = store.selected {
                PageArea(tab: tab)
                    .id(tab.id)
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .ignoresSafeArea(edges: .top)
        .navigationTitle(store.selected?.title ?? "Browser")
    }
}

/// 戻る・進む、アドレスバー、再読み込みを並べた最上段。タイトルバーを兼ねる。
///
/// 標準のツールバーに入力欄を置くと `FocusState` でフォーカスを移せないため、
/// ウインドウの中身として自前で並べている。
private struct NavigationRow: View {
    let tab: Tab
    let focusRequest: Int

    /// 左上の信号機ボタンを避けるための余白。
    private static let windowControlsWidth: CGFloat = 78

    var body: some View {
        HStack(spacing: 8) {
            Button("戻る", systemImage: "chevron.left") { tab.goBack() }
                .disabled(!tab.canGoBack)
            Button("進む", systemImage: "chevron.right") { tab.goForward() }
                .disabled(!tab.canGoForward)
            AddressBar(tab: tab, focusRequest: focusRequest)
            if tab.page.isLoading {
                Button("読み込みを中止", systemImage: "xmark") { tab.stop() }
            } else {
                Button("再読み込み", systemImage: "arrow.clockwise") { tab.reload() }
                    .disabled(!tab.hasContent)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.leading, Self.windowControlsWidth)
        .padding(.trailing, 10)
        .frame(height: 32)
    }
}

/// 選択中のタブのページ。選ばれていないタブの Web ビューは作らない。
private struct PageArea: View {
    let tab: Tab

    var body: some View {
        ZStack(alignment: .top) {
            if tab.hasContent {
                WebView(tab.page)
                    .webViewBackForwardNavigationGestures(.enabled)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
            if let failure = tab.failure {
                ContentUnavailableView(
                    "ページを開けません",
                    systemImage: "exclamationmark.triangle",
                    description: Text(failure)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
            if tab.page.isLoading {
                LoadingBar(progress: tab.page.estimatedProgress)
            }
        }
    }
}

/// ページ上端に出す細い進捗バー。
private struct LoadingBar: View {
    let progress: Double

    var body: some View {
        Rectangle()
            .fill(.tint)
            .frame(height: 2)
            .scaleEffect(x: max(0.05, min(progress, 1)), anchor: .leading)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
    }
}
