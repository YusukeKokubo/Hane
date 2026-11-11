import ControlWire
import SwiftUI
import WebKit

/// ウインドウの中身。上からタブバー、ナビゲーション、ページ。
///
/// タブバーは開いているページの一覧、その下の段は選んだページへの操作なので、
/// 一覧を上に置いて「選んだものの中身」が下へ続くように並べる。
struct BrowserWindow: View {
    let store: TabStore
    @Bindable var profiles: ProfileSwitcher

    @Environment(\.dismissWindow) private var dismissWindow
    @State private var newProfileName = ""

    /// 左上の信号機ボタンを避けるための余白。
    private static let windowControlsWidth: CGFloat = 78
    /// タブが増えてもウインドウを掴んで動かせるよう、タブバーの右端に必ず残す余白。
    private static let dragAreaWidth: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            // タイトルバーを兼ねる。
            HStack(spacing: 0) {
                if !BrowserProfile.isDefault {
                    ProfileLabel(name: BrowserProfile.name)
                }
                TabBar(store: store) { id in
                    if !store.close(id) {
                        dismissWindow(id: BrowserApp.windowID)
                    }
                }
            }
            .padding(.leading, Self.windowControlsWidth)
            .padding(.trailing, Self.dragAreaWidth)
            if let tab = store.selected {
                NavigationRow(tab: tab, store: store)
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
        .navigationTitle((store.selected?.title ?? "Browser") + (BrowserProfile.isDefault ? "" : " — \(BrowserProfile.name)"))
        .alert("新しいプロファイル", isPresented: $profiles.isCreating) {
            TextField("名前（例: 仕事）", text: $newProfileName)
            Button("作成して開く") {
                profiles.createAndOpen(newProfileName)
                newProfileName = ""
            }
            Button("キャンセル", role: .cancel) { newProfileName = "" }
        } message: {
            Text("Cookie、ブックマーク、閲覧履歴、開いているタブをほかのプロファイルと分けて持ちます。別の窓で開きます。")
        }
        .alert("プロファイル", isPresented: Binding(get: { profiles.failure != nil }, set: { if !$0 { profiles.failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(profiles.failure ?? "")
        }
    }
}

/// どのプロファイルの窓かを、タブバーの左端に出す。普段使いでは出さない。
private struct ProfileLabel: View {
    let name: String

    var body: some View {
        Label(name, systemImage: "person.crop.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, 6)
            .accessibilityIdentifier("profile")
    }
}

/// 戻る・進む、アドレスバー、再読み込みを並べた段。タブバーの下に置く。
///
/// 標準のツールバーに入力欄を置くと `FocusState` でフォーカスを移せないため、
/// ウインドウの中身として自前で並べている。
private struct NavigationRow: View {
    let tab: Tab
    let store: TabStore

    var body: some View {
        HStack(spacing: 8) {
            Button("戻る", systemImage: "chevron.left") { tab.goBack() }
                .disabled(!tab.canGoBack)
            Button("進む", systemImage: "chevron.right") { tab.goForward() }
                .disabled(!tab.canGoForward)
            AddressBar(tab: tab, store: store)
            BookmarkStarButton(tab: tab, store: store)
            if tab.page.isLoading {
                Button("読み込みを中止", systemImage: "xmark") { tab.stop() }
            } else {
                Button("再読み込み", systemImage: "arrow.clockwise") { tab.reload() }
                    .disabled(!tab.hasContent)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 34)
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
