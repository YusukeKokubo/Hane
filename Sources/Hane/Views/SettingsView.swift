import AppKit
import SwiftUI

/// 設定画面（⌘,）。
struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @State private var newSite = ""
    @State private var isDefaultBrowser = DefaultBrowser.isDefault
    @State private var defaultBrowserFailure: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("既定のブラウザ") {
                    if isDefaultBrowser {
                        Text("Hane を使っています")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("既定にする") { becomeDefaultBrowser() }
                            .disabled(!DefaultBrowser.canBecomeDefault)
                    }
                }
            } footer: {
                Text(defaultBrowserNote)
                    .font(.caption)
                    .foregroundStyle(defaultBrowserFailure == nil ? Color.secondary : Color.red)
            }

            Section {
                Toggle("ポップアップウインドウをブロック", isOn: $settings.blocksPopups)
            } footer: {
                Text("ブロックしていても、クリックなどの操作で開こうとしたものは開きます。大きさを指定したもの（ログインの小窓など）は別の窓で、ほかは新しいタブで開きます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("文字のキーでページを操作する", isOn: $settings.usesKeyNavigation)
            } footer: {
                Text("j・k でスクロール、d・u で半画面、gg・G で端まで。f で押せる所に印を出して選び、F なら新しいタブで開く。H・L で戻る・進む、J・K でタブを移る、x でタブを閉じる、o でアドレスバー、yy でアドレスをコピー。入力欄の中では効かず、Esc で入力欄から抜ける。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.usesKeyNavigation {
                Section {
                    ForEach(settings.keyNavigationExcludedSites, id: \.self) { site in
                        HStack {
                            Text(site)
                            Spacer()
                            Button {
                                settings.removeKeyNavigationExclusion(site)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("一覧から外す")
                        }
                    }
                    TextField("サイトを足す", text: $newSite, prompt: Text("mail.google.com や URL"))
                        .onSubmit {
                            if settings.excludeFromKeyNavigation(newSite) { newSite = "" }
                        }
                } header: {
                    Text("キー操作を使わないサイト")
                } footer: {
                    Text("ページ自身が文字のキーで操作するサイト向け。サブドメインも含めて外れる。開いているページにもすぐ効く。メニューの「移動」からも今のサイトを外せる。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        // システム設定で変えて戻ってきたときに合わせる。見張りは置かず、前に出たときだけ読む。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isDefaultBrowser = DefaultBrowser.isDefault
        }
    }

    private var defaultBrowserNote: String {
        if let defaultBrowserFailure { return "既定にできませんでした: \(defaultBrowserFailure)" }
        if !DefaultBrowser.canBecomeDefault { return "開発用の実体からは変えられません。~/Applications に置いた Hane から変えてください。" }
        return "ほかのアプリで開いたリンクを、最後に使ったプロファイルのウインドウで開きます。"
    }

    private func becomeDefaultBrowser() {
        defaultBrowserFailure = nil
        Task {
            do {
                try await DefaultBrowser.becomeDefault()
            } catch CocoaError.userCancelled {
                // 確かめる窓で今のままを選んだ。失敗ではない。
            } catch {
                defaultBrowserFailure = error.localizedDescription
            }
            isDefaultBrowser = DefaultBrowser.isDefault
        }
    }
}
