import SwiftUI

/// ツールバー直下に並ぶタブの列。
struct TabBar: View {
    let store: TabStore
    let onClose: (Tab.ID) -> Void

    var body: some View {
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
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
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
        .frame(minWidth: 48, maxWidth: 220, minHeight: 26)
        .background(background, in: .rect(cornerRadius: 6))
        .overlay(alignment: .bottom) {
            // 裏のタブでも読み込み中かどうかが分かるようにする。
            if tab.page.isLoading {
                Rectangle()
                    .fill(.tint)
                    .frame(height: 2)
                    .scaleEffect(x: max(0.05, min(tab.page.estimatedProgress, 1)), anchor: .leading)
                    .padding(.horizontal, 6)
            }
        }
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .help(tab.page.url?.absoluteString ?? tab.title)
    }

    private var background: Color {
        if isSelected { return Color.primary.opacity(0.12) }
        return isHovered ? Color.primary.opacity(0.06) : .clear
    }
}
