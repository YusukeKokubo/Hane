import AppKit
import SwiftUI

/// ナビゲーションの段の右端に置く、ダウンロードの一覧を開くボタン。この実体で一度もダウンロードしていなければ出さない。
///
/// 一覧は動いている間だけのもので、保存はしない。ファイルそのものは保存先（普段使いではダウンロードフォルダ）に残る。
struct DownloadsButton: View {
    let downloads: Downloads

    @State private var isShowing = false

    var body: some View {
        if !downloads.items.isEmpty {
            Button("ダウンロード", systemImage: downloads.isActive ? "arrow.down.circle.dotted" : "arrow.down.circle") {
                isShowing = true
            }
            .foregroundStyle(downloads.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .popover(isPresented: $isShowing, arrowEdge: .bottom) {
                DownloadList(downloads: downloads)
            }
            // 始まったことに気づけるよう、新しいダウンロードが来たら一覧を出す。
            .onChange(of: downloads.items.count) { old, new in
                if new > old { isShowing = true }
            }
        }
    }
}

private struct DownloadList: View {
    let downloads: Downloads

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(downloads.items.reversed()) { item in
                DownloadRow(item: item)
            }
            if downloads.items.contains(where: { $0.state != .running }) {
                Divider()
                Button("終わったものを一覧から消す") { downloads.clearFinished() }
                    .buttonStyle(.link)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

private struct DownloadRow: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                status
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if item.state == .running {
                Button("中止", systemImage: "xmark.circle.fill") { item.cancel() }
            } else if item.state == .finished, let destination = item.destination {
                Button("Finder で表示", systemImage: "magnifyingglass.circle.fill") {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    @ViewBuilder private var status: some View {
        switch item.state {
        case .running:
            if let fraction = item.fraction {
                ProgressView(value: fraction)
            } else {
                Text("ダウンロード中…")
            }
        case .finished:
            Text(item.source?.host() ?? "完了")
        case .failed(let message):
            Text("失敗: \(message)")
        case .cancelled:
            Text("中止しました")
        }
    }
}
