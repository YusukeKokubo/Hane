#!/bin/sh
# 変更を確かめる一発スクリプト。ビルド、単体テスト、実機での通し確認を順に行う。
#
# 通し確認は開発用プロファイル（BROWSER_PROFILE=dev）の別実体で行うので、
# 普段使いのブラウザのタブやCookieには触れない。ネットワークにも出ない。
# 使い方: scripts/verify.sh
#   別の作業と並べて走らせるときは BROWSER_PROFILE=<名前> で実体を分けられる（default は使えない）。
set -eu

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
case "${BROWSER_PROFILE:-}" in
    ""|default) export BROWSER_PROFILE=dev ;;
    *) export BROWSER_PROFILE ;;
esac
CTL="$ROOT/build/browserctl"
FIXTURES="file://$ROOT/Tests/Fixtures"

echo "== テスト"
swift test 2>&1 | grep -E '✘|error:|Test run with' || true
swift test >/dev/null 2>&1 || { echo "単体テストが失敗"; exit 1; }

echo "== ビルド"
scripts/bundle.sh | tail -1

echo "== 通し確認（プロファイル: ${BROWSER_PROFILE}）"
"$CTL" quit >/dev/null 2>&1 && sleep 1 || true
"$ROOT/build/Browser.app/Contents/MacOS/Browser" >/dev/null 2>&1 &
trap '"$CTL" quit >/dev/null 2>&1 || true' EXIT
sleep 2

failures=0
# expect <説明> <含まれるはずの文字列> <命令…>
expect() {
    label="$1"; wanted="$2"; shift 2
    output="$("$CTL" "$@" 2>&1)" || true
    if printf '%s' "$output" | grep -qF -- "$wanted"; then
        echo "  ok   $label"
    else
        echo "  FAIL $label"
        echo "       命令: browserctl $*"
        echo "       期待: $wanted"
        printf '%s\n' "$output" | sed 's/^/       > /'
        failures=$((failures + 1))
    fi
}

expect "起動直後はアドレスバーにフォーカス" '(focused)' ui
expect "ページを開く" 'Smoke' open "$FIXTURES/smoke.html"
expect "アドレスバーにURLが出る" 'smoke.html"' ui
expect "要素の一覧" '[1] textbox "Name"' snapshot
expect "入力" 'Smoke' fill 1 Mikawa
expect "Enterで送信" 'Hello Mikawa' press Enter 1
expect "コンソール出力の記録" '[log] submitted Hello Mikawa' logs
expect "リンクをクリック" 'Second' click 3
expect "戻るが有効になる" 'back=enabled forward=disabled' ui
expect "戻る" 'Hello Mikawa' back
expect "進むが有効になる" 'back=disabled forward=enabled' ui
expect "進む" 'Second' forward
expect "本文の取得" 'You made it.' text
expect "JavaScriptの実行" '"Second"' eval document.title
"$CTL" back >/dev/null
"$CTL" snapshot >/dev/null
"$CTL" click 4 >/dev/null
sleep 1
expect "新しいウインドウ宛てのリンクは新規タブで開く" '* tab 2: Second' tabs
expect "タブを閉じる" 'closed tab 2' close 2
"$CTL" open "$FIXTURES/smoke.html" >/dev/null
expect "今のタブをブックマークにする" '2 Smoke' bookmark-add --folder 試験
expect "フォルダの中のページを選んでいる表示" '[*試験 › Smoke ▾]' ui
expect "URLでブックマークを足す" '3 Second' bookmark-add "$FIXTURES/second.html" --name Second
expect "ブックマークをその場で開く" '[bookmark: Second]' bookmark-open 3
expect "ページを開いたブックマークの表示" '[*Second (open)]' ui
"$CTL" bookmark-remove 3 >/dev/null
expect "消したブックマークのページはタブに残る" 'ブックマークのページ 1' stats
expect "残ったページは普通のタブ" 'Second — file' tabs
"$CTL" bookmark-add "$FIXTURES/second.html" --name 二番 --folder 試験 >/dev/null
expect "⌃1でフォルダの一覧を開く" 'folder list: 試験 [>1 Smoke] [2 二番]' key ctrl+1
expect "↓で次の行を選ぶ" 'folder list: 試験 [1 Smoke] [>2 二番]' key down
expect "Returnで選んだ行を開く" '[*試験 › 二番 ▾]' key return
expect "⌘1で最初の普通のタブ" 'window title: Second' key cmd+1
"$CTL" new >/dev/null
"$CTL" type "$FIXTURES/second.html" >/dev/null
expect "アドレスバーに打って開く" 'window title: Second' key return
"$CTL" new >/dev/null
expect "打って訪れたページを履歴から補う" 'completion="cond.html"' type "$FIXTURES/se"
expect "消すキーで補った部分だけ消える" "address bar: \"$FIXTURES/se\" (focused)" key delete
expect "打ち足すと補い直す" 'completion="ond.html"' type c
expect "Escで補った部分だけ取り消す" "address bar: \"$FIXTURES/sec\" (focused)" key escape
"$CTL" type o >/dev/null
expect "補ったまま確定して移る" 'window title: Second' key return
expect "打って訪れた回数を数える" 'typed 2 visits' history
# 資源の数字を前と比べられるよう、ここで開いたタブを閉じて元の並びに戻す。
"$CTL" close >/dev/null
"$CTL" close >/dev/null
"$CTL" key cmd+1 >/dev/null
# 広告ブロック。初回はフィルタリストのコンパイルを待つので時間がかかる。
expect "フィルタリストの準備" 'filters: ready' adblock
expect "広告のページを開く" 'Ads' open "$FIXTURES/ads.html"
expect "フィルタリストの要素を隠すルール" '"none"' eval 'getComputedStyle(document.querySelector(".ad-slot")).display'
expect "フィルタリストで広告のスクリプトを止める" 'ad script blocked' logs
"$CTL" eval 'document.getElementById("promo-text").dispatchEvent(new MouseEvent("contextmenu", {bubbles: true, cancelable: true, altKey: true}))' >/dev/null
"$CTL" press ArrowUp >/dev/null
"$CTL" press Enter >/dev/null
expect "⌥右クリックで選んで親へ広げて隠す" '  div.promo' adblock
"$CTL" reload >/dev/null
expect "隠した要素は読み込み直しても隠れる" '"none"' eval 'getComputedStyle(document.querySelector(".promo")).display'
expect "隠した要素を戻す" 'restored 1' unhide
expect "戻した要素は見える" '"block"' eval 'getComputedStyle(document.querySelector(".promo")).display'
# 子フレームの中の ⌥右クリックは、親へ知らせてフレームごと選ばせる。その知らせを子へ送って確かめる。
"$CTL" eval 'document.getElementById("frame").contentWindow.postMessage({browserElementPicker: "pick"}, "*")' >/dev/null
sleep 0.5
"$CTL" press Enter >/dev/null
expect "子フレームはフレームごと隠す" '  #frame' adblock
"$CTL" unhide >/dev/null
expect "セレクタを指して隠す" 'hid 1 element' hide '#article p'
"$CTL" unhide >/dev/null
expect "読み込み失敗の報告" '読み込みに失敗' open "$FIXTURES/missing.html"
expect "失敗が記録に残る" '[navigation]' logs
expect "資源の計測" 'Browser (app)' stats
# 窓の枠はプロファイルごとの名前で覚える。普段使いの窓の位置を動かさないため。
expect "窓の枠を覚える" "remembered as \"main-${BROWSER_PROFILE}\"" ui

echo "== 資源"
"$CTL" stats

if [ "$failures" -gt 0 ]; then
    echo "通し確認で $failures 件失敗"
    exit 1
fi
echo "すべて成功"
