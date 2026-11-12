# Browser

個人用の軽量Webブラウザ。macOS 26.7以降専用で、画面は SwiftUI、ページは `WKWebView` で組んである。持ち主は一人で、配布はしない。

## 守ること

- 外部ライブラリは使わない。Apple標準のフレームワークだけで完結させる。
- ページは `Page`（`WKWebView` を一つ持つ）を通して扱い、`WKWebView` を直に触るのは `Page`、`PageView`、小窓（`PopupWindow`）、`PageProcess` に限る。WebKit for SwiftUI の `WebPage` は使わない（足りない所を埋めるのに WebKit の中を差し替える裏技が要り、履歴を書き出す口もないため。経緯は `docs/pitfalls.md` の「タブとページ」）。普段の動作を WebKit の非公開の中身や実行時の差し替えに頼らせない（開発用の計測で非公開の値を読むのは `PageProcess` だけ）。
- 古いmacOS向けの分岐（`#available`）は書かない。
- メモリとCPUの軽さが最優先。常駐するタイマーや、表示していないタブのための処理を足さない。タブ、`Page`、常駐する処理、頻繁に走る処理に触れたときは、変更の前後で `scripts/bench.sh` を走らせて見比べる（測り方は `docs/measuring.md`）。文言や見た目だけの変更では測らなくてよい。
- Swift 6の厳格な並行性チェックで、警告ゼロを保つ。

## コマンド

```sh
swift build                 # デバッグビルド
swift test                  # 単体テスト
scripts/bundle.sh [--install] [--run]  # リリースビルド → build/Browser.app と build/browserctl（Ad-hoc署名）。--install で ~/Applications に置く（Raycast から起動できる）
scripts/verify.sh           # テスト → ビルド → 開発用の別実体で通し確認（1分ほど）。一続きの作業の終わりに一度通す
scripts/bench.sh [--no-build] [--runs N] [URL…]  # 決まった手順で負荷をかけてメモリ・CPU・起床回数を測り、前回と並べる
scripts/profile.sh record <秒>  # 動いている実体に Time Profiler を付けて記録し、文字で要約する
scripts/update-filters.sh   # 広告ブロックのフィルタリストを取ってきて Support/Filters を置き換える
```

## 進め方

確かめは変更の大きさに合わせて軽く済ませる。作っている間は `swift build` と、関係するテストだけ（`swift test --filter <名前>`）を回し、画面に関わる変更なら `browserctl` で一つ二つ触って見る。`verify.sh` は一続きの作業の終わりに一度だけ通す。段階ごとにコミットするときも途中では回さず、関係するテストが通っていればコミットしてよい（最後の verify で落ちたら、直す変更を足す）。`verify.sh` は単体テストも全部走らせるので、直前に `swift test` を全部回さない。

- 止まった、時間切れになった、は不具合の症状として扱う。`timeout` を付けて避けて先へ進まず、まずそこを見る（`browserctl` は120秒答えがなければ落ちる。`lsof -U | grep control.sock` でソケットの持ち主を、`sample <pid> 1` で止まっている所を見る）。
- 速さや重さについては、測ってから案を出す。
- `git stash` などで別の版を試したら、確かめる前に作り直し、`ui` の二行目の作った時刻を見る。`verify.sh` も `build/` を作り直すので、その後の手作業はその版で動く。
- 本題と関係のない不具合や気になる挙動を見つけたら、深追いせずに持ち主へ報告し、追うかどうかを決めてもらう。調べものが本題から外れたり長引きそうになったときも、一度報告して続けるか聞く。

## 動かして確かめる

画面キャプチャ（`screencapture`）はこの環境では権限がなく撮れない。UIの確認は `browserctl` で行い、見た目は `browserctl window-screenshot <保存先>` で窓の中身を撮って Read で見る（窓が裏にいても撮れる）。命令の一覧は `build/browserctl help`。

```sh
export BROWSER_INSTANCE=dev         # 必ず付ける。付けないと持ち主の普段使いのブラウザを操作してしまう
build/browserctl open "file://$PWD/Tests/Fixtures/smoke.html"
build/browserctl ui                 # アドレスバー、ボタン、タブの並び、窓の枠。二行目に pid と作った時刻
build/browserctl snapshot           # ページ内の操作できる要素（番号つき）
build/browserctl ui-snapshot        # 窓まわりの部品。ui-click / ui-menu で名前を指して触る
build/browserctl key cmd+1          # メニューやバーへのキー。アプリが裏にいても届く
build/browserctl logs               # console出力、例外、読み込み失敗
build/browserctl quit               # 終わったら止める（pkill は普段使いの実体も殺すので使わない）
```

`dev` の実体は使い捨てで、起動していなければ `browserctl` が隣の `build/Browser.app` を裏に起こす。プロファイルは実体の中で `profile-open` で切り替える（実体を分けるのは開発用の隔離だけ）。持ち主に普段使いで試してもらう前は `scripts/bundle.sh --install` し、⌘Q で終えて起動し直してもらう。

## 詳しい文書

触る場所に応じて読む。

- `docs/pitfalls.md` — はまりどころ。画面とキー操作、タブとページ（ページの解放と眠らせ方、閲覧状態、プロセスプール、`window.open`）、プロファイル、広告ブロック、browserctl と窓まわりの操作、テストの節がある。その場所を触る前に該当する節を読む。
- `docs/browserctl.md` — `browserctl` の仕組み（起こし方、キーと入力の届け方、窓まわりの部品の拾い方、普段使いの版の入れ替え）。命令を足すときや、確かめ方が思いどおりに動かないときに読む。
- `docs/measuring.md` — `bench.sh` の手順と読み方、起床回数、`sample` や Instruments、`profile.sh`。測るときに読む。

## 構成

- `Sources/Browser` 直下 — `BrowserApp`（入口）、`BrowserCommands`（メニューとキーボードショートカット）。
- `Sources/Browser/Model` — 状態。`TabStore`（タブの一覧と選択。普通のタブと、ブックマークからその場で開いたページを分けて持つ）、`Tab`（中身は、まっさら・控えだけ・生きているページの三つの形のどれか。ページ `Page` は要るあいだだけ持つ）、`Page`（`WKWebView` を一つ持ち、値を Observable にして見せる）、`BookmarkStore`（ブックマークとフォルダの並びと保存。フォルダは一段だけ）、`SessionStore`（閲覧状態の保存。再起動したときにタブを戻す。変化を拾って書き出す `SessionRecorder` もここ）、`HistoryStore`（閲覧履歴と、アドレスバーで補う候補選び）、`PageFactory`（ページの設定をすべてここで行う。プロファイルごとに一つ）、`BrowserModel`（プロファイルの一覧と、今開いているプロファイルの `TabStore`。窓・メニュー・外部操作はここを通して今の `TabStore` を見る）、`SharedConfiguration`（設定の元。写して使うと全ページでプロセスプールと環境設定が一つになる）、`SettingsStore`（設定の窓で変える値の保存と WebKit への反映）、`PopupWindows`（`window.open` を新しいタブか小窓で開く）、`Downloads`（ダウンロードの一覧と保存先。アプリ全体で一つ）、`Signposts`（Instruments に出す区間の印）、`AddressResolver`、`PageLog`、`BrowserSettings`（検索先やUser-Agentなどの固定値。変えたい値はここに集める）。
- `Sources/Browser/Views` — 画面。`BrowserWindow`（上からタブバー、ナビゲーションの段、ページ。ページの Web ビューは中の `PageView` が置く）、`AddressBar`、`TabBar`（左にブックマーク、右に普通のタブを一列に並べる）、`BookmarkBar`（ブックマークとフォルダの項目、追加・編集のポップオーバー）、`SettingsView`（設定の窓。⌘,）、`PopupWindow`（大きさを指定して開かれた小窓。中身はタブと同じ `Page` で、AppKit の窓に置く）、`PageDialogs`（ページの `alert` などとファイルの選択を窓のシートで出す）、`DownloadsButton`（ダウンロードの一覧）。
- `Sources/Browser/Model` の広告ブロック — `ContentBlocker`（ルールリストのコンパイルと全ページへの配布）、`FilterList`（Adblock Plus 形式をWebKitのルールに訳す）、`ContentRule`（WebKitのルールのJSON）、`HiddenElementStore`（⌥右クリックで隠した要素の保存）、`ElementPicker`（⌥右クリックで要素を選ぶページ内スクリプト）。フィルタリストの本体は `Support/Filters`。
- `Sources/Browser/Control` — 外部操作。`ControlServer`（ソケット）、`ControlService`（命令の解釈）、`PageScripts`（ページ内で走らせるJavaScript）、`WindowElements`（窓まわりの部品の一覧とマウス操作）、`ProcessStats`、`PageProcess`（タブとページのプロセスの対応）。
- `Sources/ControlWire` — アプリと `browserctl` が共有する通信の取り決めと、命令の説明文（`ControlHelp`。これが仕様の正本）、実体とプロファイルの決まり（`Profile`。`BROWSER_INSTANCE` の実体、プロファイルの名前と置き場、登録した一覧）。
- `Sources/browserctl` — コマンド本体。引数をそのまま送るだけで、命令の意味は知らない。

新しい操作命令を足すときは `ControlService` に `case` を足し、`ControlHelp` の文面と `ControlServiceTests`、必要なら `scripts/verify.sh` を一緒に直す。`browserctl` 側の変更は要らない。

## いつも気をつけること

- **APIは定義ファイルで確かめる。** WebKit は版ごとに API が増えていて、記憶と食い違うことがある。`$(xcrun --show-sdk-path)/System/Library/Frameworks/WebKit.framework/Headers` を grep する。振る舞い（プールが分かれるか、など）は思い込まず、テストで確かめる。
- **テストはネットワークに出さない。** HTMLは一時ファイルに書いて `file://` で開く。

## 書き方

コメントと利用者向けの文言は日本語。コメントは「なぜそうしたか」だけを書く。コミットメッセージも日本語。
