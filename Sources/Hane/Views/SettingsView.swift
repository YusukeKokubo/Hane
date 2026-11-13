import SwiftUI

/// 設定画面（⌘,）。
struct SettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("ポップアップウインドウをブロック", isOn: $settings.blocksPopups)
            } footer: {
                Text("ブロックしていても、クリックなどの操作で開こうとしたものは開きます。大きさを指定したもの（ログインの小窓など）は別の窓で、ほかは新しいタブで開きます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
