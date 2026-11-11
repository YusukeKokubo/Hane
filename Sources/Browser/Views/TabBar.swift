import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// ツールバー直下の一列。左にブックマーク、仕切りを挟んで右に普通のタブが並ぶ。
struct TabBar: View {
    let store: TabStore
    let onClose: (Tab.ID) -> Void

    var body: some View {
        HStack(spacing: 4) {
            BookmarkStrip(store: store)
                .fixedSize()
            // 入りきらないときは、まずタブを縮め、それでも足りなければ横に流す。
            ViewThatFits(in: .horizontal) {
                tabRow
                ScrollView(.horizontal) { tabRow }
                    .scrollIndicators(.never)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        // 信号機ボタンと縦の中心がそろう高さ（32）にする。
        .padding(.vertical, 3)
    }

    private var tabRow: some View {
        HStack(spacing: 4) {
            ForEach(store.tabs) { tab in
                TabItem(
                    tab: tab,
                    isSelected: tab.id == store.selectedID,
                    onSelect: { store.selectedID = tab.id },
                    onClose: { onClose(tab.id) }
                )
            }
            Button("新規タブ", systemImage: "plus") { store.newTab() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(.horizontal, 6)
        }
    }
}

private struct TabItem: View {
    let tab: Tab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
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
        // 理想の幅を最小にしておくと、収まるかどうかを縮めた幅で判定してくれる。
        .frame(minWidth: 48, idealWidth: 48, maxWidth: 220, minHeight: 26)
        .barItemBackground(isSelected ? .selected : .idle, isHovered: isHovered)
        .overlay(alignment: .bottom) {
            // 裏のタブでも読み込み中かどうかが分かるようにする。
            if tab.page.isLoading {
                LoadingLine(progress: tab.page.estimatedProgress)
            }
        }
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .help(tab.page.url?.absoluteString ?? tab.title)
        .draggable(BarDragItem.tab(tab.id))
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
