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
scripts/bench.sh [--no-build] [--runs N] [URL…]  # 決まった手順で負荷をかけてメモリ・CPU・起床回数を測り、前回と並べる
scripts/profile.sh record <秒>  # 動いている実体に Time Profiler を付けて記録し、文字で要約する
scripts/update-filters.sh   # 広告ブロックのフィルタリストを取ってきて Support/Filters を置き換える
```

## 動かして確かめる

画面キャプチャ（`screencapture`）はこの環境では権限がなく撮れない。UIの確認は `browserctl` で行う。見た目は `browserctl window-screenshot <保存先>` で窓の中身を撮って Read で見る（アプリが自分の層を描くので権限が要らず、窓が裏にいても撮れる）。

```sh
export BROWSER_PROFILE=dev          # 必ず付ける。付けないと持ち主の普段使いのブラウザを操作してしまう
build/browserctl open "file://$PWD/Tests/Fixtures/smoke.html"
build/browserctl ui                 # アドレスバー、ボタンの有効・無効、タブの並び
build/browserctl snapshot           # ページ内の操作できる要素（番号つき）
build/browserctl logs               # console出力、例外、読み込み失敗
build/browserctl stats              # アプリと補助プロセスのメモリ・CPU
build/browserctl quit               # 終わったら止める（pkill は普段使いの実体も殺すので使わない）
```

`BROWSER_PROFILE=dev` の実体は、操作用ソケットが別で、Cookieなどを保存しない使い捨てになる（登録したプロファイルの名前を付けると、持ち主のそのプロファイルを操作してしまう。`verify.sh` と `bench.sh` は `BROWSER_EPHEMERAL=1` で使い捨てに固定している）。起動していなければ `browserctl` が隣の `build/Browser.app` の実行ファイルを直に、別のセッションで起こすので、前に出て持ち主の作業を遮ることはない（`open -g` で裏に起こすと SwiftUI が窓を作らない）。前に出したいときは `BROWSER_LAUNCH=front`。直に起こすときは、アプリを端末ではなく自分自身の責任プロセスにしている。端末から起こした実体どうしで WebKit の補助プロセスの持ち主が同じになると、`stats` が別の実体のプロセスまで数えてしまうため（`verify.sh` もこのため `browserctl` に起こさせる）。`bench.sh` は前の結果と比べられるよう前面で測る。`ui` の二行目に pid と起動した時刻、実行ファイルを作った時刻が出て、起動のあとに作り直していれば古い版が動いていると書く。命令の一覧は `build/browserctl help`。ページだけを撮るなら `browserctl screenshot <保存先>`。`window-screenshot` を `cacheDisplay` で作ると、バーの背景が明るい外観の白で塗られて実物と違ってしまうので、層を直に描いている。撮った画像を `sips -c` で切り抜くと真ん中が切り出されるので、縮めて見るなら `sips -Z 1200`。

アドレスバーへの入力は `browserctl type <文字列>` で打てる（`--replace` で今の中身を置き換える）。キーの事象を作ると持ち主の入力方式が日本語のとき仮名に化けるので、入力欄の編集部品へ文字を直接差し込んでいる。履歴から補った続きは `ui` の `completion=` に出る。

メニューやバーへのキー操作は `browserctl key cmd+1` のように送れる。アプリが裏にいるとシステムはキーを届けず、前に出すと持ち主の作業を遮るので、`ControlService` が局所モニタ、窓の部品のキー、メニュー、ウインドウの順を自分で辿って手渡しする。宛先はシート、ポップオーバー、窓の順に出ているものを選ぶ。前面にいるときも同じ道を通す（待ち行列に積むと、アラートの Return と Esc が効かなかった）。

窓まわりの部品（タブ、ブックマーク、ボタン、ポップオーバーやアラートの中身）は、`ui-snapshot` で一覧を取り、`ui-click`、`ui-hover`、`ui-menu`（右クリックのメニューと選択欄）で触る。部品は番号か名前で指す。名前なら窓から拾い直すので、並びが変わったあとに古い番号で別の部品を押す取り違えが起きない。同じ名前が重なると候補を出して断るので、`tab:Second` や `button:新規タブ` のように種類を付ける。部品はアプリ自身のアクセシビリティの木から拾い、操作は部品の真ん中へマウスの事象を作って窓へ渡す（`WindowElements`）。タブ、ブックマーク、フォルダは画面の側でアクセシビリティの識別子（`tab`、`bookmark`、`folder`）を付けたまとまりにしてあり、項目ごと一行で出る。幅で見た目が変わる部品は `window-size`、外観は `appearance dark|light|system` で切り替えて `window-screenshot` で撮る。

```sh
build/browserctl ui-snapshot              # [2] bookmark "二番" @167,3 42x26、[3] tab "Second" … など
build/browserctl ui-menu bookmark:二番     # 右クリックのメニューの項目
build/browserctl ui-menu 二番 名前とフォルダを編集…   # 選ぶとポップオーバーが出て、ui-snapshot に中身が続く
```

持ち主が普段使いで試すのは `~/Applications/Browser.app` で、`build/` を作り直しただけでは変わらない。試してもらう前に `scripts/bundle.sh --install` し、動いている実体を ⌘Q で終えて起動し直してもらう（タブは前回の閲覧状態から戻る。ただし入れ替え前の版で終えたときは、その版が状態を書き出していないので戻らない）。入った版は `cmp ~/Applications/Browser.app/Contents/MacOS/Browser build/Browser.app/Contents/MacOS/Browser` で確かめる。

## 測る

`scripts/bench.sh` は `bench` プロファイルの別実体で、起動直後・ページを開き終えた後・タブを閉じた後・タブを10枚足した後・それをまた閉じた後の五つを、それぞれ15秒待ってから10秒ずつ測る。後ろの二つから、タブ1枚あたりに増えるメモリと、閉じても戻らない分（閉じたタブが残っていないかの目安）を要約の下に出す。足すタブはどれも別のサイトへ一度移る（手元で立てた HTTP サーバーを `localhost` と `127.0.0.1` の二つの名前で引く）。WebKit は別のサイトへ移るとプロセスを乗り換えて前のページを残すので、同じサイトの中だけで測ると少なく出る。その間に、同じタブでページを5回移る間の CPU も測る（`3-navigate` の `app cpu %` が操作の重さの目安。何もしない段階と違って待たずに測る）。読み込みの直後はWebKitが15秒ほど動いていて起床回数が跳ねるので、待たずに測ると変更の良し悪しが埋もれる。結果は `build/bench/<日時>/` に残り、前回の要約と並べて出る。一度の計測でも数割ぶれるので、差が小さいときは `--runs 3` で起動からやり直して何度か測る（真ん中の値と、括弧の中に最小〜最大が出る）。

起床回数（wakeups/s）は、タイマーや割り込みでスレッドが起こされた回数。何もしていないはずの時間にこれが増えていれば、常駐する処理が紛れ込んでいる。`browserctl stats --seconds N --json` で期間を延ばしたり、機械で読める形にしたりできる。ページのプロセス（WebContent）の行には、描いているタブの番号が付く（`PageProcess` が `WebPage` の中の Web ビューから非公開のプロセス番号を読んでいる。WebKit が変わって引けなくなると `pageProcessIsFound` のテストが落ちる）。番号のないページのプロセスは、どのタブにも結びついていないもの。最後の行に測った実行ファイルが出るので、入れてある版を測っていないか確かめる。`browserctl` は `dev` などのプロファイルを自動で起こすとき、隣にある `build/Browser.app` を選ぶ（バンドルIDで頼むと `~/Applications` の版が立ち上がるため）。

中身まで見たいときは macOS の道具をそのまま使う。Ad-hoc 署名で Hardened Runtime を付けていないので、`sample`、`vmmap --summary`、`footprint`、`leaks`、`heap` も `xctrace record --template 'Time Profiler' --attach <pid>` も権限なしで刺さる（`bundle.sh` に `--options runtime` を足すとこれらが使えなくなる）。アプリはページの読み込み、タブの選択、閲覧状態と閲覧履歴の書き出し、フィルタリストの準備に区間の印（`Signposts`）を付けていて、Instruments の Points of Interest に出る。書き出すときは `xctrace export --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost" and @category="PointsOfInterest"]'`。

`scripts/profile.sh record <秒> [--tab N | --process gpu|networking]` はこの記録から、秒ごとのサンプル数、区間の印、重い関数（アプリ自身のコード、その関数自身、呼んだ先も含む全体）を文字にまとめる。既定ではアプリ本体を記録する。ページのスクリプトや描画が重いときはアプリ本体には出ないので、`--tab N` でそのタブのページのプロセスを記録する（WebKit のプロセスにも権限なしで刺さる）。操作しながら測るときは裏で走らせ、2秒ほど待ってから `browserctl` で操作する。秒ごとの表で山を見つけたら、`scripts/profile.sh summary <trace> <開始秒> <終了秒>` でその時間帯だけを見る。`xctrace` の書き出しは同じ値の2回目から参照で省くので、grep で数えると少なく見える。

SwiftUI の中で重いときは、Time Profiler の関数名がレイアウトの内部ばかりになり、どの画面の部品かは分からない。そのときは部品を一つずつ `Color.clear` などに差し替えて、同じ操作の間のメインスレッドのサンプル数を比べると早い。Instruments の SwiftUI テンプレートは、attach でも起動からでも（get-task-allow を付けても）更新の表が空だったので頼れない。

修正が窓まわりに副作用を出していないかは `browserctl ui` の `window frame:` で見る（大きさ、画面の左上からの位置、覚えている名前）。

## 構成

- `Sources/Browser` 直下 — `BrowserApp`（入口）、`BrowserCommands`（メニューとキーボードショートカット）。
- `Sources/Browser/Model` — 状態。`TabStore`（タブの一覧と選択。普通のタブと、ブックマークからその場で開いたページを分けて持つ）、`Tab`（`WebPage` を1つ所有）、`BookmarkStore`（ブックマークとフォルダの並びと保存。フォルダは一段だけ）、`SessionStore`（閲覧状態の保存。再起動したときにタブを戻す）、`HistoryStore`（閲覧履歴と、アドレスバーで補う候補選び）、`PageFactory`（`WebPage` の設定をすべてここで行う）、`ProfileSwitcher`（プロファイルの一覧と、別のプロファイルの実体へ移る処理）、`SharedProcessPool`（全タブで一つのプロセスプールを使わせる）、`Signposts`（Instruments に出す区間の印）、`NavigationDecider`、`AddressResolver`、`PageLog`、`BrowserSettings`（検索先やUser-Agentなどの固定値。変えたい値はここに集める）。
- `Sources/Browser/Views` — 画面。`BrowserWindow`（上からタブバー、ナビゲーションの段、ページ）、`AddressBar`、`TabBar`（左にブックマーク、右に普通のタブを一列に並べる）、`BookmarkBar`（ブックマークとフォルダの項目、追加・編集のポップオーバー）。
- `Sources/Browser/Model` の広告ブロック — `ContentBlocker`（ルールリストのコンパイルと全ページへの配布）、`FilterList`（Adblock Plus 形式をWebKitのルールに訳す）、`ContentRule`（WebKitのルールのJSON）、`HiddenElementStore`（⌥右クリックで隠した要素の保存）、`ElementPicker`（⌥右クリックで要素を選ぶページ内スクリプト）。フィルタリストの本体は `Support/Filters`。
- `Sources/Browser/Control` — 外部操作。`ControlServer`（ソケット）、`ControlService`（命令の解釈）、`PageScripts`（ページ内で走らせるJavaScript）、`WindowElements`（窓まわりの部品の一覧とマウス操作）、`ProcessStats`、`PageProcess`（タブとページのプロセスの対応）。
- `Sources/ControlWire` — アプリと `browserctl` が共有する通信の取り決めと、命令の説明文（`ControlHelp`。これが仕様の正本）、プロファイルの決まり（`Profile`。名前、置き場、登録した一覧）。
- `Sources/browserctl` — コマンド本体。引数をそのまま送るだけで、命令の意味は知らない。

新しい操作命令を足すときは `ControlService` に `case` を足し、`ControlHelp` の文面と `ControlServiceTests`、必要なら `scripts/verify.sh` を一緒に直す。`browserctl` 側の変更は要らない。

## はまりどころ

- **APIは定義ファイルで確かめる。** `WebPage` は新しく、記憶と食い違うことがある。`$(xcrun --show-sdk-path)/System/Library/Frameworks/WebKit.framework/Modules/WebKit.swiftmodule/arm64e-apple-macos.swiftinterface` と、同じ場所の `_WebKit_SwiftUI.framework` を grep する。たとえば戻る・進むの専用メソッドはなく、`page.load(backForwardList.backList.last!)` のように履歴の項目を読み込む。
- **`ViewThatFits` を使わない。** 候補を全部作って、中身が変わるたびに全部測り直す。タブバーで使っていたときは、ページを移るたびにメインスレッドが0.1秒ほど取られていた（取り除いて三分の一）。タブを縮めるか横に流すかは、縮めきった幅を足し算で出して選んでいる。
- **入力欄を標準ツールバーに置かない。** `.toolbar` の中の `TextField` には `FocusState` が効かず、Cmd+L が動かなくなる。そのためタイトルバーを隠し、タブバーとナビゲーションの段をウインドウの中身として並べている。タブバーがタイトルバーを兼ねるので、左端の信号機ボタンの余白と、右端のウインドウを掴むための余白を削らない。
- **起動直後のフォーカスは一度では入らない。** ウインドウが前面に出る前の要求は黙って捨てられるので、`AddressBar` は入るまで短くやり直している。
- **Cmd+W をタブに割り当てる仕組み。** メニューの「タブを閉じる」を標準の「閉じる」より前（`.newItem` の位置）に置くことで先に拾わせている。順番を変えるとウインドウごと閉じるようになる。
- **中身が変わるメニュー項目のショートカットは当てにしない。** SwiftUI はメニューの中身を開く直前まで作り直さないので、起動後に増えた項目のキーはメニューを一度開くまで効かない。プロファイルの ⌃1〜9 は、このため `LocalShortcuts`（AppKitの局所モニタ）で拾っている。⌘1〜9 のように起動時から決まっている項目は問題ない。局所モニタで拾ったキーはページへ届かないので、ページがよく使う組み合わせは取らない（⌥⌘数字は Google ドキュメントや Notion の見出しに使われていて、一度取ってしまった）。
- **⌘1〜8 はバーの左から数える。** ブックマークとフォルダとタブを、見えている一列のまま数える（フォルダなら一覧を開け閉めする）。番号が見た目の並びとずれないようにするため。⌘9 は最後の普通のタブ。前後のタブは ⇧⌘[ / ⇧⌘] と ⌃Tab / ⌃⇧Tab で、メニューの項目にはキーが一つしか付かないので ⌃Tab は `LocalShortcuts` が拾う。
- **`WebPage` の解放。** `Tab` はナビゲーションを見張るタスクを持つ。`TabStore.close` が `tearDown()` で止めないと `WebPage` が残る。`closedTabReleasesItsPage` のテストが見張っている。
- **ブックマークはArcのピン留めと同じ考え方。** 押すと新しいタブを作らずその場でページを開き、閉じてもブックマークは残る。開いていないブックマークは `WebPage` を持たない。ブックマークは保存するプロファイルだけ `bookmarks.json` に保存し（置き場は「プロファイル」の項）、`dev` では保存しない。テストで `TabStore` を作ると保存しないブックマークになる。
- **閲覧状態は変化を拾って書き出す。** `TabStore` が `withObservationTracking` で開いているページの並び・アドレス・題名・選択を見張り、変わったら書き出す（同じ中身なら書かない）。タイマーは使わない。終了直前にも `BrowserApp` から一度書く。保存するプロファイルだけ `session.json` に保存し、`dev` とテストでは保存しない。戻る・進むの履歴は `WebPage` に書き出す手段がないので持ち越さない。
- **macOS の再開は切ってある（`restorationBehavior(.disabled)`）。** 任せるとウインドウの状態が変わるたびに窓全体の画像を取って保存し、アプリ本体が25MBほど膨らんだまま戻らない（その瞬間は倍）。タブは閲覧状態で戻すので要らない。その代わり窓の位置と大きさは戻らなくなるので、`WindowFrameMemory` が AppKit の自動保存で覚える。名前はプロファイルごとに分け、開発用の実体が普段使いの窓を動かさないようにしている。
- **プロファイルは実体（プロセス）ごとに分ける。** 一つの実体は `BROWSER_PROFILE` の一つのプロファイルだけを受け持ち、メニューの「プロファイル」で選ぶと、そのプロファイルの実体を起こすか、起動済みのものを前に出す。一つの窓の中で入れ替えると、切り替えるたびに全部のタブを読み込み直すことになり、並べても使えないため。保存するのは `default` と、一覧（`~/Library/Application Support/Browser/profiles.json`）に登録した名前だけ。持ち物は `default` が `~/Library/Application Support/Browser/` 直下（分ける前からの場所）、それ以外は `profiles/<名前>/` に置き、サイトデータは一覧に残した識別子で `WKWebsiteDataStore(forIdentifier:)` に分ける。名前はそのままパスと環境変数に入るので、操作用ソケットのパスが104バイトに収まる長さまで（日本語でおよそ8文字）。
- **同じアプリをもう一つ立ち上げるのは Launch Services を通す。** `NSWorkspace` の `createsNewApplicationInstance` で起こすと Dock に並ぶ。前に出るのは相手の側なので、こちらから `yieldActivation` で譲ってから操作用ソケットで `activate` を頼む（macOS 14 からは、譲られていないアプリが前に出ようとしても断られることがある）。同じプロファイルの実体がもう答えていれば、後から起きた方は起動をやめる（ソケットを奪い合い、閲覧状態を互いに上書きするため）。Raycast や Dock から起こしたとき、別のプロファイルの実体が動いていると、Launch Services はそちらを前に出すだけで `default` を起こさないはず（まだ確かめていない）。そのときはメニューから「標準」を選ぶ。
- **使い捨ての実体から別のプロファイルへ移ると、起こす実体も使い捨てにして裏に起こす。** 使い捨ての実体には登録した一覧を見せず、作った名前はその実体の中だけに持つ。起こすときは `BROWSER_EPHEMERAL=1` を引き継ぎ、同じ名前の登録したプロファイルがあっても持ち主のデータに触らない。前に出さないので、`verify.sh` で `profile-open` を確かめても持ち主の作業を遮らない。
- **プロセスプールは全タブで一つにしている（`SharedProcessPool`）。** `WebPage` はページごとに別のプールを作り、公開の設定にはプールを渡す口がない。プールが別々だと、別のサイトへ移ったとき「戻る」用に残すページ（プールごとに2つ）と先に立ち上げる予備のプロセス（プールごとに1つ）がタブの数だけ溜まり、タブ10枚で別のサイトへ一度ずつ移るとページのプロセスが34個になった（共有すると16個）。`WKWebViewConfiguration` 自身の `init` を差し替えて共有のプールを入れている。効かなくなると `pagesShareOneProcessPool` のテストが落ちる。
- **戻したタブは選ばれるまで読み込まない。** 一斉に読み込むとタブの数だけ WebContent プロセスが立ち上がるため。`TabStore.selectedID` の `didSet` で読み込みを始める。行き先は `page.url` ではなく `Tab.url` で読む（読み込み前や、読み込みに失敗して `page.url` が空のタブでも返す）。
- **閲覧履歴は少し遅れてまとめて書く。** 数千件を訪問のたびに書き直さないよう、変化から数秒待って書き出し、終了直前にも書く（待つのは変化のあった後の一度きりで、常駐するタイマーではない）。保存先は保存するプロファイルだけ `history.json`。上限は5000件で、超えたら最後に訪れたのが古いものから捨てる。
- **アドレスバーで補うのは、打って訪れたページとサイトの入口だけ。** リンクで通っただけの深いページまで補うと、打つたびに思わぬ所へ飛ばされるため。「打って訪れた」は `Tab.open(typed:)` を通った読み込みで、検索結果のページは数えない。補った続きは `TextSelection` で選択した状態で入れ、打ち足すと置き換わる。打った部分を消している間は補わない（補うと消した文字が戻ってくる）。
- **バーのドラッグは専用の型で運ぶ。** `BarDragItem` の型 `local.personal.browser.bar-item` は `Support/Info.plist` で宣言している。文字列で運ぶと、ページの入力欄に落としたとき文字として入ってしまう。
- **広告ブロックは WebKit のコンテンツブロッカーで行う。** 判定はページのプロセスの中で WebKit がするので、アプリ側で常に動く処理はない。同梱のリスト（EasyList と AdGuard Japanese）を起動時に訳してコンパイルするのは中身か `FilterList.version` が変わったときだけで（数秒）、ふだんは `WKContentRuleListStore` から引くだけ。訳し方を変えたら `FilterList.version` を上げる。普段使いは WebKit の既定の置き場、それ以外のプロファイルは `~/Library/Caches/Browser/profiles/<名前>`（登録したプロファイルは名前でなくサイトデータの識別子）に置くので、`verify.sh` の初回はコンパイルを待つ。
- **WebKit のルールは1リスト15万件まで、ひとつでも受け付けないルールがあるとリスト全体が落ちる。** 訳せない書き方は捨てる方へ倒し、`bundledListsCompile` のテストで同梱のリストが実際にコンパイルできるかを見張っている。例外（`ignore-previous-rules`）は同じリストで前にあるルールしか取り消せないので、例外は最後に並べる。
- **右クリックのメニューには項目を足せない。** WebKit for SwiftUI の `webViewContextMenu` は標準の項目（コピー、調べる、Webインスペクタなど）をすべて置き換えてしまう。そのため要素を隠す操作は、ページ内のスクリプトで ⌥ 付きの右クリックだけを拾っている。子フレームの中なら `postMessage` で親へ知らせてフレームごと選ばせる。`browserctl` からは、合成した `contextmenu` 事象（`altKey: true`）と `press` で同じ流れを試せる。
- **SwiftUI はアクセシビリティの木を問われるまで作らない。** `open` で起動すると常駐する何かが問い合わせて木ができるが、直に起動すると（`verify.sh`）中から辿っても空のまま。`WindowElements` は外の道具と同じ API で自分に一度問い合わせて作らせている。作らせても、何もしていない間の起床回数とメモリは変わらなかった。
- **窓まわりの操作で、アプリを止めてしまうもの。** 選択欄を押す、右クリックのメニューを出すと、閉じるまでメインスレッドが止まって応答を返せない。そのため `ui-menu` はメニューを出さずに中身を引いて項目の動作を直に呼び、`ui-click` は選択欄を断る。ボタンは押されると離す事象を自分で待つので、離す事象を先に待ち行列へ積んでから押す。選択欄は選択欄の動作を送っても SwiftUI の値が変わらず、項目の動作を呼ぶ必要がある。
- **窓まわりで、作った事象では確かめられないもの。** ドラッグは始まらない（運ぶ中身を載せた情報を落とし先へ直に渡す方法も試したが、SwiftUI は受け付けず、その後の描画でアプリが落ちた）。並べ替えは `TabStore.drop` の単体テストで見る。`onHover` はアプリが前面のときしか効かないので、裏にいるときの `ui-hover` は乗せたときの表示を出せない（`verify.sh` はそのとき skip と出す）。
- **シートが出ていると終了が黙って取りやめになる。** `quit` は先にシートを閉じてから終える。終わったつもりで古い版が動き続け、作り直した版を試したつもりになることがあった。また、起動していないときの `quit` は何もしない（前は起こしてから止めていて、作り直している最中の古い版が動き出すことがあった）。
- **テストはネットワークに出さない。** HTMLは一時ファイルに書いて `file://` で開く。`data:` や検索語はアドレスの解釈に巻き込まれやすい。
- **`file://` のページでは例外の中身が「Script error.」に潰れる。** WebKitの仕様で、http(s) のページでは普通に取れる。

## 書き方

コメントと利用者向けの文言は日本語。コメントは「なぜそうしたか」だけを書く。コミットメッセージも日本語。
