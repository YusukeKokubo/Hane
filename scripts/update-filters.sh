#!/bin/sh
# 広告ブロックのフィルタリストを取ってきて Support/Filters に置き換える。
# 取り込むには、このあと scripts/bundle.sh で作り直す。アプリは中身が変わったことに気づいて
# 次の起動時に一度だけコンパイルし直す（数秒）。
# 終わりに、訳したリストを WebKit がコンパイルできるかをテストで確かめる。
# 使い方: scripts/update-filters.sh
set -eu

cd "$(dirname "$0")/.."
DIR=Support/Filters
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() {
    name="$1"; url="$2"
    curl -sSfL --max-time 60 -o "$TMP/$name" "$url"
    # 途中で切れたものやエラーページを置かないよう、中身がフィルタリストらしいか確かめる。
    if ! head -5 "$TMP/$name" | grep -q '^\(\[Adblock\|! \)'; then
        echo "フィルタリストに見えない: $url" >&2
        exit 1
    fi
    mv "$TMP/$name" "$DIR/$name"
    echo "更新: $DIR/$name（$(grep -m1 '^! Version:' "$DIR/$name" || echo '版不明')）"
}

fetch easylist.txt https://easylist.to/easylist/easylist.txt
# 日本のサイト向け（AdGuard Japanese filter の Safari 向けの版）。
fetch adguard-japanese.txt https://filters.adtidy.org/extension/safari/filters/7.txt

# 新しいリストに、訳し方が想定していない書き方が混じっていないか。WebKit はひとつでも受け付けない
# ルールがあるとリスト全体を落とすので、入れ替えたら必ず確かめる（普段の swift test では飛ばしている）。
echo "== 訳したリストを WebKit がコンパイルできるか確かめる"
LOG="$TMP/test.log"
if ! HANE_HEAVY_TESTS=1 swift test --filter FilterListTests >"$LOG" 2>&1 || ! grep -q '✔ Test run with' "$LOG"; then
    grep -E '✘|error:|rules:|Test run with' "$LOG" || tail -20 "$LOG"
    echo "新しいリストをコンパイルできない。Support/Filters は置き換え済みなので、訳し方を直すか git で戻すこと" >&2
    exit 1
fi
grep -E 'rules:|Test run with' "$LOG"
