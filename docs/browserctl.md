# browserctl で動かして確かめる

命令の一覧と書き方は `build/browserctl help`（`ControlHelp` が正本）。ここには、仕組みと、なぜそうなっているかを残す。

## 起こし方と実体

`BROWSER_INSTANCE=dev` の実体は、操作用ソケットが別で（`~/Library/Application Support/Browser/instances/dev/control.sock`）、Cookieなどを保存しない使い捨てになる。前の書き方の `BROWSER_PROFILE` や `BROWSER_EPHEMERAL` が付いていると、`browserctl` もアプリも止まる（黙って普段使いの実体を相手にしないため）。起動していなければ `browserctl` が隣の `build/Browser.app` の実行ファイルを直に、別のセッションで起こすので、前に出て持ち主の作業を遮ることはない（`open -g` で裏に起こすと SwiftUI が窓を作らない）。前に出したいときは `BROWSER_LAUNCH=front`。直に起こすときは、アプリを端末ではなく自分自身の責任プロセスにしている。端末から起こした実体どうしで WebKit の補助プロセスの持ち主が同じになると、`stats` が別の実体のプロセスまで数えてしまうため（`verify.sh` もこのため `browserctl` に起こさせる）。`bench.sh` は前の結果と比べられるよう前面で測る。`ui` の二行目に pid と起動した時刻、実行ファイルを作った時刻が出て、起動のあとに作り直していれば古い版が動いていると書く。ページだけを撮るなら `browserctl screenshot <保存先>`。`window-screenshot` を `cacheDisplay` で作ると、バーの背景が明るい外観の白で塗られて実物と違ってしまうので、層を直に描いている。撮った画像を `sips -c` で切り抜くと真ん中が切り出されるので、縮めて見るなら `sips -Z 1200`。

## 入力とキー

アドレスバーへの入力は `browserctl type <文字列>` で打てる（`--replace` で今の中身を置き換える）。キーの事象を作ると持ち主の入力方式が日本語のとき仮名に化けるので、入力欄の編集部品へ文字を直接差し込んでいる。履歴から補った続きは `ui` の `completion=` に出る。

メニューやバーへのキー操作は `browserctl key cmd+1` のように送れる。アプリが裏にいるとシステムはキーを届けず、前に出すと持ち主の作業を遮るので、`ControlService` が局所モニタ、窓の部品のキー、メニュー、ウインドウの順を自分で辿って手渡しする。宛先は、本体の窓より手前に設定の窓が出ていればそれ、なければシート、ポップオーバー、窓の順に出ているものを選ぶ。前面にいるときも同じ道を通す（待ち行列に積むと、アラートの Return と Esc が効かなかった）。

## 窓まわりの部品

窓まわりの部品（タブ、ブックマーク、ボタン、ポップオーバーやアラートの中身）は、`ui-snapshot` で一覧を取り、`ui-click`、`ui-hover`、`ui-menu`（右クリックのメニューと選択欄）で触る。部品は番号か名前で指す。名前なら窓から拾い直すので、並びが変わったあとに古い番号で別の部品を押す取り違えが起きない。同じ名前が重なると候補を出して断るので、`tab:Second` や `button:新規タブ` のように種類を付ける。部品はアプリ自身のアクセシビリティの木から拾い、操作は部品の真ん中へマウスの事象を作って窓へ渡す（`WindowElements`）。タブ、ブックマーク、フォルダは画面の側でアクセシビリティの識別子（`tab`、`bookmark`、`folder`）を付けたまとまりにしてあり、項目ごと一行で出る。幅で見た目が変わる部品は `window-size`、外観は `appearance dark|light|system` で切り替えて `window-screenshot` で撮る。設定の窓（`key cmd+,` で開く）やポップアップの小窓のように別に開く窓も、本体の窓より手前にあれば `ui-snapshot` に続けて出て触れる。ただし設定の窓の Form の中身は、層を直に描いても `cacheDisplay` でも写らなかった（白いまま）ので、見た目は部品の一覧で確かめる。

```sh
build/browserctl ui-snapshot              # [2] bookmark "二番" @167,3 42x26、[3] tab "Second" … など
build/browserctl ui-menu bookmark:二番     # 右クリックのメニューの項目
build/browserctl ui-menu 二番 名前とフォルダを編集…   # 選ぶとポップオーバーが出て、ui-snapshot に中身が続く
```

## 普段使いの版で試してもらう

持ち主が普段使いで試すのは `~/Applications/Browser.app` で、`build/` を作り直しただけでは変わらない。試してもらう前に `scripts/bundle.sh --install` し、動いている実体を ⌘Q で終えて起動し直してもらう（タブは前回の閲覧状態から戻る。ただし入れ替え前の版で終えたときは、その版が状態を書き出していないので戻らない）。入った版は `cmp ~/Applications/Browser.app/Contents/MacOS/Browser build/Browser.app/Contents/MacOS/Browser` で確かめる。

## 窓の副作用を見る

修正が窓まわりに副作用を出していないかは `browserctl ui` の `window frame:` で見る（大きさ、画面の左上からの位置、覚えている名前）。
