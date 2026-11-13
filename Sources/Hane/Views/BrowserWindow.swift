import ControlWire
import SwiftUI
import WebKit

/// ウインドウの中身。上からタブバー、ナビゲーション、ページ。
///
/// タブバーは開いているページの一覧、その下の段は選んだページへの操作なので、
/// 一覧を上に置いて「選んだものの中身」が下へ続くように並べる。
struct BrowserWindow: View {
    @Bindable var model: BrowserModel

    /// この窓。どのプロファイルを出すかは、窓が出たときに BrowserModel が決める。
    @State private var slot = BrowserWindowSlot()
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State private var newProfileName = ""

    /// 左上の信号機ボタンを避けるための余白。
    fileprivate static let windowControlsWidth: CGFloat = 78
    /// タブが増えてもウインドウを掴んで動かせるよう、タブバーの右端に必ず残す余白。
    private static let dragAreaWidth: CGFloat = 40

    var body: some View {
        Group {
            if let store = model.store(in: slot) {
                // プロファイルを切り替えるとタブ管理ごと入れ替わるので、中身も作り直し、アドレスバーの書きかけなどを持ち越さない。
                content(store)
                    .id(ObjectIdentifier(store))
            } else {
                ProfilePicker(model: model, slot: slot)
            }
        }
        .navigationTitle(title)
        .background { WindowSlotBinder(model: model, slot: slot) }
        .onAppear {
            // 起動して戻す窓が残っていれば、続けて開く。開いた窓が出たときにまた次を開く。
            if model.attach(slot) {
                openWindow(id: HaneApp.moreWindowsID)
            }
        }
        .alert("新しいプロファイル", isPresented: Binding(
            get: { model.creatingIn === slot },
            set: { if !$0, model.creatingIn === slot { model.creatingIn = nil } }
        )) {
            TextField("名前（例: 仕事）", text: $newProfileName)
            Button("作成して開く") {
                model.createAndOpen(newProfileName, in: slot)
                newProfileName = ""
            }
            Button("キャンセル", role: .cancel) { newProfileName = "" }
        } message: {
            Text(slot.profile == nil
                ? "Cookie、ブックマーク、閲覧履歴、開いているタブをほかのプロファイルと分けて持ちます。このウインドウで開きます。"
                : "Cookie、ブックマーク、閲覧履歴、開いているタブをほかのプロファイルと分けて持ちます。今開いているタブは閉じ、このウインドウで開きます。")
        }
        .alert("プロファイル", isPresented: Binding(
            get: { model.failure != nil && model.isActive(slot) },
            set: { if !$0 { model.failure = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(model.failure ?? "")
        }
    }

    private var title: String {
        guard let store = model.store(in: slot) else { return "新しいウインドウ" + (BrowserInstance.name.map { " — \($0)" } ?? "") }
        return (store.selected?.title ?? "Browser") + (windowLabel.map { " — \($0)" } ?? "")
    }

    /// どの実体の、どのプロファイルの窓か。普段使いの実体の標準のプロファイルでは出さない。
    private var windowLabel: String? {
        let profile = slot.profile.flatMap { $0 == BrowserProfile.defaultName ? nil : $0 }
        let parts = [BrowserInstance.name, profile].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    private func content(_ store: TabStore) -> some View {
        VStack(spacing: 0) {
            // タイトルバーを兼ねる。
            HStack(spacing: 0) {
                if let windowLabel {
                    ProfileLabel(name: windowLabel)
                }
                TabBar(store: store) { id in
                    if !store.close(id) {
                        dismissWindow()
                    }
                }
            }
            .padding(.leading, Self.windowControlsWidth)
            .padding(.trailing, Self.dragAreaWidth)
            // 項目のない所だけが窓を掴む場所になる。項目は手前にあるので、ドラッグは項目が受ける。
            .background { WindowDragArea() }
            if let tab = store.selected {
                NavigationRow(tab: tab, store: store)
            }
            Divider()
            if let tab = store.selected {
                ZStack(alignment: .top) {
                    LivePages(store: store, selectedID: tab.id)
                    PageArea(tab: tab)
                        .id(tab.id)
                }
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .ignoresSafeArea(edges: .top)
        .background { StillWindow() }
    }
}

/// ⌘N で開いた窓に、出すプロファイルを選ばせる。ほかの窓に出ているものを選ぶと、その窓を前に出してこの窓は閉じる。
private struct ProfilePicker: View {
    let model: BrowserModel
    let slot: BrowserWindowSlot

    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            // タイトルバーの位置。窓を掴む所を残す。
            Color.clear
                .frame(height: 34)
                .background { WindowDragArea() }
            VStack(spacing: 10) {
                Text("このウインドウで開くプロファイル")
                    .font(.headline)
                    .padding(.bottom, 6)
                ForEach(model.names, id: \.self) { name in
                    let shown = model.isShown(name)
                    Button {
                        model.open(name, in: slot)
                        if shown { dismissWindow() }
                    } label: {
                        Label(BrowserModel.title(for: name) + (shown ? "（開いているウインドウへ）" : ""),
                              systemImage: "person.crop.circle")
                            .frame(maxWidth: 260, alignment: .leading)
                    }
                    .controlSize(.large)
                }
                Divider()
                    .frame(width: 260)
                Button("新しいプロファイル…") { model.beginCreating(in: slot) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 34)
        }
        .frame(minWidth: 480, minHeight: 320)
        .ignoresSafeArea(edges: .top)
        .background { StillWindow() }
    }
}

/// 窓とその AppKit の窓を BrowserModel に結ぶ。前に出たこと、閉じたことを知らせる。
private struct WindowSlotBinder: NSViewRepresentable {
    let model: BrowserModel
    let slot: BrowserWindowSlot

    func makeNSView(context: Context) -> Marker { Marker(model: model, slot: slot) }
    func updateNSView(_ nsView: Marker, context: Context) {}

    final class Marker: NSView {
        private let model: BrowserModel
        private let slot: BrowserWindowSlot
        private var isBound = false

        init(model: BrowserModel, slot: BrowserWindowSlot) {
            self.model = model
            self.slot = slot
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !isBound else { return }
            isBound = true
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(becameKey), name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(willClose), name: NSWindow.willCloseNotification, object: window)
            // 窓の大きさは SwiftUI が置いたあとに決まるので、覚えていた位置へ動かすのは一巡り待ってから。
            Task { @MainActor [slot] in
                slot.window = window
            }
            if window.isKeyWindow {
                model.activate(slot)
            }
        }

        @objc private func becameKey() {
            model.activate(slot)
        }

        @objc private func willClose() {
            NotificationCenter.default.removeObserver(self)
            // 閉じた窓は AppKit がしばらく掴んでいることがあり、覚える名前を握ったままだと次に開く窓が使えない。
            window?.setFrameAutosaveName("")
            model.detach(slot)
        }
    }
}

/// どの実体・プロファイルの窓かを、タブバーの左端に出す。普段使いの標準のプロファイルでは出さない。
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
            PasswordFillButton(fill: store.passwordFill, tab: tab)
            if tab.isLoading {
                Button("読み込みを中止", systemImage: "xmark") { tab.stop() }
            } else {
                Button("再読み込み", systemImage: "arrow.clockwise") { tab.reload() }
                    .disabled(!tab.hasContent)
            }
            DownloadsButton(downloads: store.downloads)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 34)
    }
}

/// 生きているページの Web ビューを、選んでいないものも窓に置いたまま隠しておく。
///
/// 窓から外すと WebKit は描いた絵を手放し、窓へ戻したとき描き直すまでの間ページがちらつくため。
/// 隠した Web ビューは WebKit から見えていない扱いになり、裏のタブとして絞られる。
private struct LivePages: View {
    let store: TabStore
    let selectedID: Tab.ID

    var body: some View {
        ZStack {
            ForEach(store.allTabs.filter { $0.page != nil }) { tab in
                if let page = tab.page {
                    PageView(page: page, isHidden: tab.id != selectedID, focusRequest: store.pageFocusRequest)
                        .id(ObjectIdentifier(page))
                }
            }
        }
    }
}

/// 選択中のタブの、ページに重ねるもの。ページを持たないタブでは背景で覆う。
private struct PageArea: View {
    let tab: Tab

    var body: some View {
        ZStack(alignment: .top) {
            if tab.page == nil {
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
            if tab.isLoading {
                LoadingBar(progress: tab.estimatedProgress)
            }
        }
    }
}

/// ページの Web ビューを画面に置く。
///
/// SwiftUI の `WebView` は `WebPage` しか受け取らない。`WebPage` は足りない所を WebKit の中を差し替えて埋める必要があり、
/// 履歴を書き出す口もないのでやめた（`Page`）。そのため Web ビューはここで AppKit の部品として置く。
/// Web ビューは `Page` が持っているので、画面から外れても捨てずに、また選ばれたら同じものを置く。
private struct PageView: NSViewRepresentable {
    let page: Page
    let isHidden: Bool
    /// `TabStore.pageFocusRequest`。前に受けたものから変わっていて、見えていれば、キーボードのフォーカスを受ける。
    let focusRequest: Int

    final class Coordinator {
        var handledFocusRequest = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        page.webView.isHidden = isHidden
        return page.webView
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        view.isHidden = isHidden
        guard !isHidden, focusRequest != context.coordinator.handledFocusRequest else { return }
        context.coordinator.handledFocusRequest = focusRequest
        // 起こしたばかりのページはまだ窓に載っていないので、載ってから渡す。
        Task { @MainActor in
            view.window?.makeFirstResponder(view)
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
