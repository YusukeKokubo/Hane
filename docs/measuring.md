# 測る

いつ測るかは CLAUDE.md の「守ること」。ここには測り方と読み方を残す。

## bench.sh

`scripts/bench.sh` は `bench` という使い捨ての実体で、起動直後・ページを開き終えた後・タブを閉じた後・タブを10枚足した後・それをまた閉じた後の五つを、それぞれ15秒待ってから10秒ずつ測る。後ろの二つから、タブ1枚あたりに増えるメモリと、閉じても戻らない分（閉じたタブが残っていないかの目安）を要約の下に出す。足すタブはどれも別のサイトへ一度移る（手元で立てた HTTP サーバーを `localhost` と `127.0.0.1` の二つの名前で引く）。WebKit は別のサイトへ移るとプロセスを乗り換えて前のページを残すので、同じサイトの中だけで測ると少なく出る。その間に、同じタブでページを5回移る間の CPU も測る（`3-navigate` の `app cpu %` が操作の重さの目安。何もしない段階と違って待たずに測る）。読み込みの直後はWebKitが15秒ほど動いていて起床回数が跳ねるので、待たずに測ると変更の良し悪しが埋もれる。結果は `build/bench/<日時>/` に残り、前回の要約と並べて出る。一度の計測でも数割ぶれるので、差が小さいときは `--runs 3` で起動からやり直して何度か測る（真ん中の値と、括弧の中に最小〜最大が出る）。

## 起床回数とプロセスの見方

起床回数（wakeups/s）は、タイマーや割り込みでスレッドが起こされた回数。何もしていないはずの時間にこれが増えていれば、常駐する処理が紛れ込んでいる。`browserctl stats --seconds N --json` で期間を延ばしたり、機械で読める形にしたりできる。ページのプロセス（WebContent）の行には、描いているタブの番号が付く（`PageProcess` が `WebPage` の中の Web ビューから非公開のプロセス番号を読んでいる。WebKit が変わって引けなくなると `pageProcessIsFound` のテストが落ちる）。番号のないページのプロセスは、どのタブにも結びついていないもの。最後の行に測った実行ファイルが出るので、入れてある版を測っていないか確かめる。`browserctl` は `dev` などの使い捨ての実体を自動で起こすとき、隣にある `build/Browser.app` を選ぶ（バンドルIDで頼むと `~/Applications` の版が立ち上がるため）。

## 中身まで見る

中身まで見たいときは macOS の道具をそのまま使う。Ad-hoc 署名で Hardened Runtime を付けていないので、`sample`、`vmmap --summary`、`footprint`、`leaks`、`heap` も `xctrace record --template 'Time Profiler' --attach <pid>` も権限なしで刺さる（`bundle.sh` に `--options runtime` を足すとこれらが使えなくなる）。アプリはページの読み込み、タブの選択、閲覧状態と閲覧履歴の書き出し、フィルタリストの準備に区間の印（`Signposts`）を付けていて、Instruments の Points of Interest に出る。書き出すときは `xctrace export --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost" and @category="PointsOfInterest"]'`。

## profile.sh

`scripts/profile.sh record <秒> [--tab N | --process gpu|networking]` はこの記録から、秒ごとのサンプル数、区間の印、重い関数（アプリ自身のコード、その関数自身、呼んだ先も含む全体）を文字にまとめる。既定ではアプリ本体を記録する。ページのスクリプトや描画が重いときはアプリ本体には出ないので、`--tab N` でそのタブのページのプロセスを記録する（WebKit のプロセスにも権限なしで刺さる）。操作しながら測るときは裏で走らせ、2秒ほど待ってから `browserctl` で操作する。秒ごとの表で山を見つけたら、`scripts/profile.sh summary <trace> <開始秒> <終了秒>` でその時間帯だけを見る。`xctrace` の書き出しは同じ値の2回目から参照で省くので、grep で数えると少なく見える。

## SwiftUI の中で重いとき

SwiftUI の中で重いときは、Time Profiler の関数名がレイアウトの内部ばかりになり、どの画面の部品かは分からない。そのときは部品を一つずつ `Color.clear` などに差し替えて、同じ操作の間のメインスレッドのサンプル数を比べると早い。Instruments の SwiftUI テンプレートは、attach でも起動からでも（get-task-allow を付けても）更新の表が空だったので頼れない。
