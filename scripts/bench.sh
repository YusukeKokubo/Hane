#!/bin/sh
# 決まった手順で負荷をかけ、メモリ・CPU・起床回数を測る。変更の前後で走らせて見比べる。
#
# 手順は「起動して何もしない」「ページを開き終えて何もしない」「タブを閉じて何もしない」の三つで、
# それぞれ BENCH_SETTLE 秒（既定 15）待ってから BENCH_SECONDS 秒（既定 10）の平均を取る。
# 読み込みの直後は WebKit がしばらく動いていて起床回数が跳ねるので、落ち着くのを待つ。
# 何もしていないはずの時間に CPU や起床回数が増えていたら、常駐する処理が紛れ込んでいる。
#
# 使い方: scripts/bench.sh [--no-build] [URL…]
#   URL を省くと Tests/Fixtures のページを使う（ネットワークに出ない）。
#   実体は BROWSER_PROFILE（既定 bench）で分けるので、普段使いにも verify.sh の dev にも触れない。
#   結果は build/bench/<日時>/ に段階ごとの JSON と要約を残し、前回の要約と並べて出す。
set -eu

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
case "${BROWSER_PROFILE:-}" in
    ""|default) export BROWSER_PROFILE=bench ;;
    *) export BROWSER_PROFILE ;;
esac
SECONDS_PER_PHASE="${BENCH_SECONDS:-10}"
SETTLE="${BENCH_SETTLE:-15}"
CTL="$ROOT/build/browserctl"

BUILD=1
if [ "${1:-}" = "--no-build" ]; then
    BUILD=0
    shift
fi
if [ "$#" -eq 0 ]; then
    set -- "file://$ROOT/Tests/Fixtures/smoke.html" \
           "file://$ROOT/Tests/Fixtures/second.html" \
           "file://$ROOT/Tests/Fixtures/ads.html"
fi

if [ "$BUILD" = 1 ]; then
    scripts/bundle.sh | tail -1
fi

PREVIOUS="$(ls -d build/bench/*/ 2>/dev/null | tail -1 || true)"
OUT="build/bench/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

"$CTL" quit >/dev/null 2>&1 && sleep 1 || true
trap '"$CTL" quit >/dev/null 2>&1 || true' EXIT
# 最初の命令で build/ のアプリが立ち上がる。フィルタリストの準備（初回はコンパイル）も待つ。
"$CTL" adblock >/dev/null

# measure <段階の名前>
measure() {
    "$CTL" stats --seconds "$SECONDS_PER_PHASE" --json > "$OUT/$1.json"
}

echo "== 計測（プロファイル: ${BROWSER_PROFILE}、${SETTLE} 秒待って ${SECONDS_PER_PHASE} 秒ずつ）"
sleep "$SETTLE"
measure 1-launched

"$CTL" open "$1" >/dev/null
shift
for url in "$@"; do
    "$CTL" new "$url" >/dev/null
done
sleep "$SETTLE"
measure 2-loaded

# 最初のタブだけ残して閉じる。閉じたタブのページとプロセスが手放されるかを見る。
while [ "$("$CTL" tabs | wc -l)" -gt 1 ]; do
    "$CTL" close >/dev/null
done
sleep "$SETTLE"
measure 3-closed

# 段階ごとの合計を一行ずつにまとめる。
value() { plutil -extract "$2" raw -o - "$1"; }
{
    printf '%-12s %9s %11s %7s %10s\n' phase processes "memory MB" "cpu %" wakeups/s
    for file in "$OUT"/*.json; do
        printf '%-12s %9s %11.1f %7.1f %10.1f\n' \
            "$(basename "$file" .json)" \
            "$(value "$file" report.processes)" \
            "$(echo "$(value "$file" report.total.memoryBytes) / 1048576" | bc -l)" \
            "$(value "$file" report.total.cpuPercent)" \
            "$(value "$file" report.total.wakeupsPerSecond)"
    done
    echo "実行ファイル: $(value "$OUT/1-launched.json" report.executable)"
} > "$OUT/summary.txt"

cat "$OUT/summary.txt"
if [ -n "$PREVIOUS" ] && [ -f "$PREVIOUS/summary.txt" ]; then
    echo "== 前回（${PREVIOUS}）"
    cat "$PREVIOUS/summary.txt"
fi
echo "段階ごとの内訳: $OUT/*.json"
