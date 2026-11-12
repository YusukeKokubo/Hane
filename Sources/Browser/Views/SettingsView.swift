import SwiftUI

/// 設定画面（⌘,）。
struct SettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("ポップアップウインドウをブロック", isOn: $settings.blocksPopups)
            } footer: {
                Text("ブロックしていても、クリックなどの操作で開こうとしたものは新しいタブで開きます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
