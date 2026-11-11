#!/bin/sh
# 広告ブロックのフィルタリストを取ってきて Support/Filters に置き換える。
# 取り込むには、このあと scripts/bundle.sh で作り直す。アプリは中身が変わったことに気づいて
# 次の起動時に一度だけコンパイルし直す（数秒）。
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
