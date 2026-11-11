# Browser

個人用の軽量Webブラウザ。macOS 26.7以降専用で、SwiftUIと WebKit for SwiftUI（`WebView` と `WebPage`）だけで組んである。持ち主は一人で、配布はしない。

## 守ること

- 外部ライブラリは使わない。Apple標準のフレームワークだけで完結させる。
- `WKWebView` を `NSViewRepresentable` で包まない。ページは必ず `WebPage`、表示は `WebView` を使う。新APIで足りない機能にAppKitを使うときは、範囲を最小にして理由をコメントに書く。
- 古いmacOS向けの分岐（`#available`）は書かない。
- メモリとCPUの軽さが最優先。常駐するタイマーや、表示していないタブのための処理を足さない。変更の前後で `browserctl stats` を見比べる。
- Swift 6の厳格な並行性チェックで、警告ゼロを保つ。

## コマンド

```sh
swift build                 # デバッグビルド
swift test                  # 単体テスト
scripts/bundle.sh [--install] [--run]  # リリースビルド → build/Browser.app と build/browserctl（Ad-hoc署名）。--install で ~/Applications に置く（Raycast から起動できる）
scripts/verify.sh           # テスト → ビルド → 開発用の別実体で通し確認。変更したら必ずこれを通す
```

## 動かして確かめる

画面キャプチャ（`screencapture`）はこの環境では権限がなく撮れない。UIの確認は `browserctl` で行う。

```sh
export BROWSER_PROFILE=dev          # 必ず付ける。付けないと持ち主の普段使いのブラウザを操作してしまう
build/browserctl open "file://$PWD/Tests/Fixtures/smoke.html"
build/browserctl ui                 # アドレスバー、ボタンの有効・無効、タブの並び
build/browserctl snapshot           # ページ内の操作できる要素（番号つき）
build/browserctl logs               # console出力、例外、読み込み失敗
build/browserctl stats              # アプリと補助プロセスのメモリ・CPU
build/browserctl quit               # 終わったら止める（pkill は普段使いの実体も殺すので使わない）
```

`BROWSER_PROFILE=dev` の実体は、操作用ソケットが別で、Cookieなどを保存しない使い捨てになる。命令の一覧は `build/browserctl help`。ページの見た目は `browserctl screenshot <保存先>` で撮って Read で見られる（ページの中だけで、ウインドウの枠は写らない）。

メニューやバーへのキー操作は `browserctl key ctrl+1` のように送れるが、アプリが前面にいないと届かない。`scripts/verify.sh` の起動では前面に出ないので、確かめるときは `open -n build/Browser.app --env BROWSER_PROFILE=dev` で起動する（`-n` で普段使いの実体とは別に立ち上がる）。持ち主が他のアプリを触ると前面が移るので、試す間は手を離してもらう。

持ち主が普段使いで試すのは `~/Applications/Browser.app` で、`build/` を作り直しただけでは変わらない。試してもらう前に `scripts/bundle.sh --install` し、動いている実体を ⌘Q で終えて起動し直してもらう（普通のタブは戻らず、ブックマークは残る）。入った版は `cmp ~/Applications/Browser.app/Contents/MacOS/Browser build/Browser.app/Contents/MacOS/Browser` で確かめる。

## 構成

- `Sources/Browser` 直下 — `BrowserApp`（入口）、`BrowserCommands`（メニューとキーボードショートカット）。
- `Sources/Browser/Model` — 状態。`TabStore`（タブの一覧と選択。普通のタブと、ブックマークからその場で開いたページを分けて持つ）、`Tab`（`WebPage` を1つ所有）、`BookmarkStore`（ブックマークとフォルダの並びと保存。フォルダは一段だけ）、`PageFactory`（`WebPage` の設定をすべてここで行う）、`NavigationDecider`、`AddressResolver`、`PageLog`、`BrowserSettings`（検索先やUser-Agentなどの固定値。変えたい値はここに集める）。
- `Sources/Browser/Views` — 画面。`BrowserWindow`（上からタブバー、ナビゲーションの段、ページ）、`AddressBar`、`TabBar`（左にブックマーク、右に普通のタブを一列に並べる）、`BookmarkBar`（ブックマークとフォルダの項目、追加・編集のポップオーバー）。
- `Sources/Browser/Control` — 外部操作。`ControlServer`（ソケット）、`ControlService`（命令の解釈）、`PageScripts`（ページ内で走らせるJavaScript）、`ProcessStats`。
- `Sources/ControlWire` — アプリと `browserctl` が共有する通信の取り決めと、命令の説明文（`ControlHelp`。これが仕様の正本）。
- `Sources/browserctl` — コマンド本体。引数をそのまま送るだけで、命令の意味は知らない。

新しい操作命令を足すときは `ControlService` に `case` を足し、`ControlHelp` の文面と `ControlServiceTests`、必要なら `scripts/verify.sh` を一緒に直す。`browserctl` 側の変更は要らない。

## はまりどころ

- **APIは定義ファイルで確かめる。** `WebPage` は新しく、記憶と食い違うことがある。`$(xcrun --show-sdk-path)/System/Library/Frameworks/WebKit.framework/Modules/WebKit.swiftmodule/arm64e-apple-macos.swiftinterface` と、同じ場所の `_WebKit_SwiftUI.framework` を grep する。たとえば戻る・進むの専用メソッドはなく、`page.load(backForwardList.backList.last!)` のように履歴の項目を読み込む。
- **入力欄を標準ツールバーに置かない。** `.toolbar` の中の `TextField` には `FocusState` が効かず、Cmd+L が動かなくなる。そのためタイトルバーを隠し、タブバーとナビゲーションの段をウインドウの中身として並べている。タブバーがタイトルバーを兼ねるので、左端の信号機ボタンの余白と、右端のウインドウを掴むための余白を削らない。
- **起動直後のフォーカスは一度では入らない。** ウインドウが前面に出る前の要求は黙って捨てられるので、`AddressBar` は入るまで短くやり直している。
- **Cmd+W をタブに割り当てる仕組み。** メニューの「タブを閉じる」を標準の「閉じる」より前（`.newItem` の位置）に置くことで先に拾わせている。順番を変えるとウインドウごと閉じるようになる。
- **中身が変わるメニュー項目のショートカットは当てにしない。** SwiftUI はメニューの中身を開く直前まで作り直さないので、起動後に増えた項目のキーはメニューを一度開くまで効かない。フォルダの ⌃1〜9 は、このため `FolderShortcut`（AppKitの局所モニタ）で拾っている。⌘1〜9 のように起動時から決まっている項目は問題ない。
- **`WebPage` の解放。** `Tab` はナビゲーションを見張るタスクを持つ。`TabStore.close` が `tearDown()` で止めないと `WebPage` が残る。`closedTabReleasesItsPage` のテストが見張っている。
- **ブックマークはArcのピン留めと同じ考え方。** 押すと新しいタブを作らずその場でページを開き、閉じてもブックマークは残る。開いていないブックマークは `WebPage` を持たない。ブックマークは普段使いのプロファイルだけ `~/Library/Application Support/Browser/bookmarks.json` に保存し、`dev` では保存しない。テストで `TabStore` を作ると保存しないブックマークになる。
- **バーのドラッグは専用の型で運ぶ。** `BarDragItem` の型 `local.personal.browser.bar-item` は `Support/Info.plist` で宣言している。文字列で運ぶと、ページの入力欄に落としたとき文字として入ってしまう。
- **テストはネットワークに出さない。** HTMLは一時ファイルに書いて `file://` で開く。`data:` や検索語はアドレスの解釈に巻き込まれやすい。
- **`file://` のページでは例外の中身が「Script error.」に潰れる。** WebKitの仕様で、http(s) のページでは普通に取れる。

## 書き方

コメントと利用者向けの文言は日本語。コメントは「なぜそうしたか」だけを書く。コミットメッセージも日本語。
