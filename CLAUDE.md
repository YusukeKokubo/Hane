# Browser

個人用の軽量Webブラウザ。macOS 26.7以降専用で、SwiftUIと WebKit for SwiftUI（`WebView` と `WebPage`）だけで組んである。持ち主は一人で、配布はしない。

## 守ること

- 外部ライブラリは使わない。Apple標準のフレームワークだけで完結させる。
- `WKWebView` を `NSViewRepresentable` で包まない。ページは必ず `WebPage`、表示は `WebView` を使う。新APIで足りない機能にAppKitを使うときは、範囲を最小にして理由をコメントに書く。
- 古いmacOS向けの分岐（`#available`）は書かない。
- メモリとCPUの軽さが最優先。常駐するタイマーや、表示していないタブのための処理を足さない。変更の前後で `scripts/bench.sh` を走らせて見比べる（測り方は「測る」の節）。
- Swift 6の厳格な並行性チェックで、警告ゼロを保つ。

## コマンド

```sh
swift build                 # デバッグビルド
swift test                  # 単体テスト
scripts/bundle.sh [--install] [--run]  # リリースビルド → build/Browser.app と build/browserctl（Ad-hoc署名）。--install で ~/Applications に置く（Raycast から起動できる）
scripts/verify.sh           # テスト → ビルド → 開発用の別実体で通し確認。変更したら必ずこれを通す
scripts/bench.sh [--no-build] [URL…]  # 決まった手順で負荷をかけてメモリ・CPU・起床回数を測り、前回と並べる
scripts/update-filters.sh   # 広告ブロックのフィルタリストを取ってきて Support/Filters を置き換える
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

アドレスバーへの入力は `browserctl type <文字列>` で打てる。キーの事象を作ると持ち主の入力方式が日本語のとき仮名に化けるので、入力欄の編集部品へ文字を直接差し込んでいる。履歴から補った続きは `ui` の `completion=` に出る。

メニューやバーへのキー操作は `browserctl key ctrl+1` のように送れる。アプリが裏にいるとシステムはキーを届けず、前に出すと持ち主の作業を遮るので、そのときは `ControlService` が局所モニタ、メニュー、ウインドウ（出ていればポップオーバー）の順を自分で辿って手渡しする。前面にいるときは本物のキーと同じく待ち行列に積む。

持ち主が普段使いで試すのは `~/Applications/Browser.app` で、`build/` を作り直しただけでは変わらない。試してもらう前に `scripts/bundle.sh --install` し、動いている実体を ⌘Q で終えて起動し直してもらう（タブは前回の閲覧状態から戻る。ただし入れ替え前の版で終えたときは、その版が状態を書き出していないので戻らない）。入った版は `cmp ~/Applications/Browser.app/Contents/MacOS/Browser build/Browser.app/Contents/MacOS/Browser` で確かめる。

## 測る

`scripts/bench.sh` は `bench` プロファイルの別実体で、起動直後・ページを開き終えた後・タブを閉じた後の三つを、それぞれ15秒待ってから10秒ずつ測る。読み込みの直後はWebKitが15秒ほど動いていて起床回数が跳ねるので、待たずに測ると変更の良し悪しが埋もれる。結果は `build/bench/<日時>/` に残り、前回の要約と並べて出る。一度の計測でも数割ぶれるので、差が小さいときは二、三度走らせる。

起床回数（wakeups/s）は、タイマーや割り込みでスレッドが起こされた回数。何もしていないはずの時間にこれが増えていれば、常駐する処理が紛れ込んでいる。`browserctl stats --seconds N --json` で期間を延ばしたり、機械で読める形にしたりできる。最後の行に測った実行ファイルが出るので、入れてある版を測っていないか確かめる。`browserctl` は `dev` などのプロファイルを自動で起こすとき、隣にある `build/Browser.app` を選ぶ（バンドルIDで頼むと `~/Applications` の版が立ち上がるため）。

中身まで見たいときは macOS の道具をそのまま使う。Ad-hoc 署名で Hardened Runtime を付けていないので、`sample`、`vmmap --summary`、`footprint`、`leaks`、`heap` も `xctrace record --template 'Time Profiler' --attach <pid>` も権限なしで刺さる（`bundle.sh` に `--options runtime` を足すとこれらが使えなくなる）。アプリはページの読み込み、タブの選択、閲覧状態と閲覧履歴の書き出し、フィルタリストの準備に区間の印（`Signposts`）を付けていて、Instruments の Points of Interest に出る。書き出すときは `xctrace export --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost" and @category="PointsOfInterest"]'`。

## 構成

- `Sources/Browser` 直下 — `BrowserApp`（入口）、`BrowserCommands`（メニューとキーボードショートカット）。
- `Sources/Browser/Model` — 状態。`TabStore`（タブの一覧と選択。普通のタブと、ブックマークからその場で開いたページを分けて持つ）、`Tab`（`WebPage` を1つ所有）、`BookmarkStore`（ブックマークとフォルダの並びと保存。フォルダは一段だけ）、`SessionStore`（閲覧状態の保存。再起動したときにタブを戻す）、`HistoryStore`（閲覧履歴と、アドレスバーで補う候補選び）、`PageFactory`（`WebPage` の設定をすべてここで行う）、`Signposts`（Instruments に出す区間の印）、`NavigationDecider`、`AddressResolver`、`PageLog`、`BrowserSettings`（検索先やUser-Agentなどの固定値。変えたい値はここに集める）。
- `Sources/Browser/Views` — 画面。`BrowserWindow`（上からタブバー、ナビゲーションの段、ページ）、`AddressBar`、`TabBar`（左にブックマーク、右に普通のタブを一列に並べる）、`BookmarkBar`（ブックマークとフォルダの項目、追加・編集のポップオーバー）。
- `Sources/Browser/Model` の広告ブロック — `ContentBlocker`（ルールリストのコンパイルと全ページへの配布）、`FilterList`（Adblock Plus 形式をWebKitのルールに訳す）、`ContentRule`（WebKitのルールのJSON）、`HiddenElementStore`（⌥右クリックで隠した要素の保存）、`ElementPicker`（⌥右クリックで要素を選ぶページ内スクリプト）。フィルタリストの本体は `Support/Filters`。
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
- **閲覧状態は変化を拾って書き出す。** `TabStore` が `withObservationTracking` で開いているページの並び・アドレス・題名・選択を見張り、変わったら書き出す（同じ中身なら書かない）。タイマーは使わない。終了直前にも `BrowserApp` から一度書く。普段使いのプロファイルだけ `~/Library/Application Support/Browser/session.json` に保存し、`dev` とテストでは保存しない。戻る・進むの履歴は `WebPage` に書き出す手段がないので持ち越さない。
- **戻したタブは選ばれるまで読み込まない。** 一斉に読み込むとタブの数だけ WebContent プロセスが立ち上がるため。`TabStore.selectedID` の `didSet` で読み込みを始める。行き先は `page.url` ではなく `Tab.url` で読む（読み込み前や、読み込みに失敗して `page.url` が空のタブでも返す）。
- **閲覧履歴は少し遅れてまとめて書く。** 数千件を訪問のたびに書き直さないよう、変化から数秒待って書き出し、終了直前にも書く（待つのは変化のあった後の一度きりで、常駐するタイマーではない）。保存先は普段使いのプロファイルだけ `~/Library/Application Support/Browser/history.json`。上限は5000件で、超えたら最後に訪れたのが古いものから捨てる。
- **アドレスバーで補うのは、打って訪れたページとサイトの入口だけ。** リンクで通っただけの深いページまで補うと、打つたびに思わぬ所へ飛ばされるため。「打って訪れた」は `Tab.open(typed:)` を通った読み込みで、検索結果のページは数えない。補った続きは `TextSelection` で選択した状態で入れ、打ち足すと置き換わる。打った部分を消している間は補わない（補うと消した文字が戻ってくる）。
- **バーのドラッグは専用の型で運ぶ。** `BarDragItem` の型 `local.personal.browser.bar-item` は `Support/Info.plist` で宣言している。文字列で運ぶと、ページの入力欄に落としたとき文字として入ってしまう。
- **広告ブロックは WebKit のコンテンツブロッカーで行う。** 判定はページのプロセスの中で WebKit がするので、アプリ側で常に動く処理はない。同梱のリスト（EasyList と AdGuard Japanese）を起動時に訳してコンパイルするのは中身か `FilterList.version` が変わったときだけで（数秒）、ふだんは `WKContentRuleListStore` から引くだけ。訳し方を変えたら `FilterList.version` を上げる。普段使いは WebKit の既定の置き場、それ以外のプロファイルは `~/Library/Caches/Browser/profiles/<名前>` に置くので、`verify.sh` の初回はコンパイルを待つ。
- **WebKit のルールは1リスト15万件まで、ひとつでも受け付けないルールがあるとリスト全体が落ちる。** 訳せない書き方は捨てる方へ倒し、`bundledListsCompile` のテストで同梱のリストが実際にコンパイルできるかを見張っている。例外（`ignore-previous-rules`）は同じリストで前にあるルールしか取り消せないので、例外は最後に並べる。
- **右クリックのメニューには項目を足せない。** WebKit for SwiftUI の `webViewContextMenu` は標準の項目（コピー、調べる、Webインスペクタなど）をすべて置き換えてしまう。そのため要素を隠す操作は、ページ内のスクリプトで ⌥ 付きの右クリックだけを拾っている。子フレームの中なら `postMessage` で親へ知らせてフレームごと選ばせる。`browserctl` からは、合成した `contextmenu` 事象（`altKey: true`）と `press` で同じ流れを試せる。
- **テストはネットワークに出さない。** HTMLは一時ファイルに書いて `file://` で開く。`data:` や検索語はアドレスの解釈に巻き込まれやすい。
- **`file://` のページでは例外の中身が「Script error.」に潰れる。** WebKitの仕様で、http(s) のページでは普通に取れる。

## 書き方

コメントと利用者向けの文言は日本語。コメントは「なぜそうしたか」だけを書く。コミットメッセージも日本語。
