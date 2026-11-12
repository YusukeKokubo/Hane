import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// ツールバー直下の一列。左にブックマーク、仕切りを挟んで右に普通のタブが並ぶ。
struct TabBar: View {
    let store: TabStore
    let onClose: (Tab.ID) -> Void

    /// タブの並びに使える幅。窓の大きさが変わったときだけ更新される。
    @State private var rowWidth: CGFloat = .infinity

    private static let spacing: CGFloat = 4
    /// 新規タブのボタンの幅。少し多めに見積もり、ぎりぎりで溢れないようにする。
    private static let newTabButtonWidth: CGFloat = 32

    var body: some View {
        HStack(spacing: Self.spacing) {
            BookmarkStrip(store: store)
                .fixedSize()
            // 入りきらないときは、まずタブを縮め、それでも足りなければ横に流す。
            // ViewThatFits で両方を候補に出すと、並びを二組作って変化のたびに両方を測り直すので、
            // ページを移るたびにメインスレッドが0.1秒ほど取られていた。縮めきった幅を足し算で出して自分で選ぶ。
            Group {
                if needsScrolling {
                    // 流しているときは、選んだタブが見えるところまで送り、新規タブのボタンは流れの外に置く。
                    // でないと右端で開いた新しいタブもボタンも、見えないところに隠れてしまう。
                    HStack(spacing: Self.spacing) {
                        ScrollViewReader { proxy in
                            ScrollView(.horizontal) { tabs }
                                .scrollIndicators(.never)
                                .onChange(of: store.selectedID, initial: true) {
                                    if let id = store.selectedID { proxy.scrollTo(id) }
                                }
                        }
                        newTabButton
                    }
                } else {
                    HStack(spacing: Self.spacing) {
                        tabs
                        newTabButton
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        }
        .padding(.horizontal, 6)
        // 信号機ボタンと縦の中心がそろう高さ（32）にする。
        .padding(.vertical, 3)
    }

    /// すべてのタブを最小の幅まで縮めても入りきらないか。
    private var needsScrolling: Bool {
        let tabs = CGFloat(store.tabs.count)
        return tabs * (TabItem.minimumWidth + Self.spacing) + Self.newTabButtonWidth > rowWidth
    }

    private var tabs: some View {
        HStack(spacing: Self.spacing) {
            ForEach(store.tabs) { tab in
                TabItem(
                    tab: tab,
                    isSelected: tab.id == store.selectedID,
                    onSelect: { store.selectedID = tab.id },
                    onClose: { onClose(tab.id) }
                )
            }
        }
    }

    private var newTabButton: some View {
        Button("新規タブ", systemImage: "plus") { store.newTab() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
    }
}

private struct TabItem: View {
    /// 縮めきってもアイコンと閉じるボタンは隠れない幅。題名はそこで見えなくなる。
    static let minimumWidth: CGFloat = 60

    let tab: Tab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            // 新しいタブには行き先がないので出さない。
            if tab.url != nil {
                Favicon(image: tab.favicon)
            }
            Text(tab.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("タブを閉じる", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .opacity(isSelected || isHovered ? 1 : 0)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        // 横に流すときは理想の幅で並ぶので、最小と同じにして縮めた幅で並べる。
        .frame(minWidth: Self.minimumWidth, idealWidth: Self.minimumWidth, maxWidth: 220, minHeight: 26)
        .barItemBackground(isSelected ? .selected : .idle, isHovered: isHovered)
        .overlay(alignment: .bottom) {
            // 裏のタブでも読み込み中かどうかが分かるようにする。
            if tab.isLoading {
                LoadingLine(progress: tab.estimatedProgress)
            }
        }
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .help(tab.url?.absoluteString ?? tab.title)
        .draggable(BarDragItem.tab(tab.id))
        // タブとブックマークとフォルダを、VoiceOver や browserctl の ui-snapshot から見分けられるようにする。
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tab.title)
        .accessibilityIdentifier("tab")
    }
}

/// バーの項目の下端に出す、読み込みの進み具合。
struct LoadingLine: View {
    let progress: Double

    var body: some View {
        Rectangle()
            .fill(.tint)
            .frame(height: 2)
            .scaleEffect(x: max(0.05, min(progress, 1)), anchor: .leading)
            .padding(.horizontal, 6)
    }
}

// MARK: 見た目の共通部品

/// タブとブックマークの頭に出すサイトのアイコン。まだ取っていないサイトでは地球儀で場所を取っておき、題名の位置をそろえる。
struct Favicon: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "globe")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .scaledToFit()
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

enum BarItemState {
    /// ページを持たないブックマーク。
    case idle
    /// ページを開いているが、選ばれていない。
    case live
    case selected
}

extension View {
    /// タブとブックマークで同じ背景を使い、どちらも同じ「ページ」に見えるようにする。
    func barItemBackground(_ state: BarItemState, isHovered: Bool) -> some View {
        let opacity: Double = switch state {
        case .selected: 0.12
        case .live: isHovered ? 0.09 : 0.06
        case .idle: isHovered ? 0.05 : 0
        }
        return background(Color.primary.opacity(opacity), in: .rect(cornerRadius: 6))
    }

    /// バーの項目を落とし先にする。重なっている間だけ目印を出す。
    func barDropTarget(_ marker: BarDropMarker, perform: @escaping (BarDragItem) -> Void) -> some View {
        modifier(BarDropTarget(marker: marker, perform: perform))
    }
}

enum BarDropMarker {
    /// 項目の手前に縦線を出す（その前に入る）。
    case leading
    /// 項目の上に横線を出す（縦に並ぶ一覧で、その上に入る）。
    case top
    /// 項目全体を囲む（その中に入る）。
    case highlight
}

private struct BarDropTarget: ViewModifier {
    let marker: BarDropMarker
    let perform: (BarDragItem) -> Void

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: alignment) {
                if isTargeted { markerView }
            }
            .dropDestination(for: BarDragItem.self) { items, _ in
                isTargeted = false
                items.forEach(perform)
            }
            .onDropSessionUpdated { session in
                switch session.phase {
                case .entering, .active: isTargeted = true
                default: isTargeted = false
                }
            }
    }

    private var alignment: Alignment {
        switch marker {
        case .leading: .leading
        case .top: .top
        case .highlight: .center
        }
    }

    @ViewBuilder private var markerView: some View {
        switch marker {
        case .leading:
            Capsule().fill(.tint).frame(width: 2).padding(.vertical, 1).offset(x: -3)
        case .top:
            Capsule().fill(.tint).frame(height: 2).offset(y: -2)
        case .highlight:
            RoundedRectangle(cornerRadius: 6).strokeBorder(.tint, lineWidth: 2)
        }
    }
}

// MARK: ドラッグで運ぶもの

/// バーの中で運ぶ項目。アプリの外へ出ても意味を持たないよう、専用の型で運ぶ。
enum BarDragItem: Codable, Sendable, Transferable {
    case tab(UUID)
    case bookmark(UUID)

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .browserBarItem)
    }
}

extension UTType {
    /// Info.plist の UTExportedTypeDeclarations で宣言している。
    static let browserBarItem = UTType(exportedAs: "local.personal.browser.bar-item")
}
