#!/bin/sh
# 変更を確かめる一発スクリプト。ビルド、単体テスト、実機での通し確認を順に行う。
#
# 通し確認は開発用プロファイル（BROWSER_PROFILE=dev）の別実体で行うので、
# 普段使いのブラウザのタブやCookieには触れない。ネットワークにも出ない。
# 使い方: scripts/verify.sh
set -eu

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
export BROWSER_PROFILE=dev
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
expect "読み込み失敗の報告" '読み込みに失敗' open "$FIXTURES/missing.html"
expect "失敗が記録に残る" '[navigation]' logs
expect "資源の計測" 'Browser (app)' stats

echo "== 資源"
"$CTL" stats

if [ "$failures" -gt 0 ]; then
    echo "通し確認で $failures 件失敗"
    exit 1
fi
echo "すべて成功"
