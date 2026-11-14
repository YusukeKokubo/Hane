import SwiftUI

/// 1Password のログインを入れるボタン。合うログインがいくつもあるときと、入れられなかったときは、ここから一覧や文言を出す。
/// 入れる場所を教わっているあいだは、押すと教わるのを終える。
struct PasswordFillButton: View {
    let fill: PasswordFill
    let tab: Tab

    var body: some View {
        Group {
            switch fill.state {
            case .working:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16)
            case .teaching:
                Button("入れる場所を教えるのを終える", systemImage: "key.fill") { fill.stopTeaching() }
                    .foregroundStyle(.tint)
                    .help("入れる場所を教えるのを終える（Esc）")
            case .idle, .choosing, .failed:
                Button("1Password で入力", systemImage: "key") { fill.start(on: tab) }
                    .disabled(!tab.hasContent)
                    .help("1Password のログインを入れる（⌘\\）。⌥⌘\\ で入れる場所を教える")
            }
        }
        .popover(isPresented: Binding(
            get: { showsPanel },
            set: { if !$0 { fill.dismiss() } }
        ), arrowEdge: .bottom) {
            PasswordFillPanel(fill: fill) { fill.start(on: tab, teaching: true) }
        }
    }

    private var showsPanel: Bool {
        switch fill.state {
        case .choosing, .failed: true
        case .idle, .working, .teaching: false
        }
    }
}

private struct PasswordFillPanel: View {
    let fill: PasswordFill
    /// 入れられなかったとき、そのまま入れる場所を教え始める。
    let teach: () -> Void
    @State private var selection: LoginItem.ID?

    var body: some View {
        switch fill.state {
        case .choosing(let items):
            // 矢印キーで選び、Return かダブルクリックで入れる。
            List(items, selection: $selection) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                    let detail = [item.username, item.accountName].filter { !$0.isEmpty }.joined(separator: " — ")
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contextMenu(forSelectionType: LoginItem.ID.self, menu: { _ in }) { ids in
                if let item = items.first(where: { ids.contains($0.id) }) {
                    fill.choose(item)
                }
            }
            .frame(width: 300, height: min(CGFloat(items.count) * 44 + 12, 320))
            .onAppear { selection = items.first?.id }
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 12) {
                Text(message)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("入れる場所を教える…") {
                        fill.dismiss()
                        teach()
                    }
                    Button("OK") { fill.dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 320)
        case .idle, .working, .teaching:
            EmptyView()
        }
    }
}
