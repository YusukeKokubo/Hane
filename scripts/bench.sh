#!/bin/sh
# 決まった手順で負荷をかけ、メモリ・CPU・起床回数を測る。変更の前後で走らせて見比べる。
#
# 手順は「起動して何もしない」「ページを開き終えて何もしない」「タブを閉じて何もしない」の三つで、
# それぞれ BENCH_SETTLE 秒（既定 15）待ってから BENCH_SECONDS 秒（既定 10）の平均を取る。
# 読み込みの直後は WebKit がしばらく動いていて起床回数が跳ねるので、落ち着くのを待つ。
# 何もしていないはずの時間に CPU や起床回数が増えていたら、常駐する処理が紛れ込んでいる。
#
# 使い方: scripts/bench.sh [--no-build] [--runs N] [URL…]
#   一度の計測でも数割ぶれるので、差が小さいときは --runs 3 などで起動からやり直して何度か測る。
#   要約には真ん中の値と、括弧の中に最小〜最大が出る。
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
RUNS=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=0; shift ;;
        --runs) RUNS="$2"; shift 2 ;;
        *) break ;;
    esac
done
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
trap '"$CTL" quit >/dev/null 2>&1 || true' EXIT

# measure <回> <段階の名前>
measure() {
    "$CTL" stats --seconds "$SECONDS_PER_PHASE" --json > "$OUT/run$1/$2.json"
}

echo "== 計測（プロファイル: ${BROWSER_PROFILE}、${RUNS} 回、${SETTLE} 秒待って ${SECONDS_PER_PHASE} 秒ずつ）"
run=1
while [ "$run" -le "$RUNS" ]; do
    mkdir -p "$OUT/run$run"
    "$CTL" quit >/dev/null 2>&1 && sleep 1 || true
    # 最初の命令で build/ のアプリが立ち上がる。フィルタリストの準備（初回はコンパイル）も待つ。
    "$CTL" adblock >/dev/null
    sleep "$SETTLE"
    measure "$run" 1-launched

    first=1
    for url in "$@"; do
        if [ "$first" = 1 ]; then
            "$CTL" open "$url" >/dev/null
            first=0
        else
            "$CTL" new "$url" >/dev/null
        fi
    done
    sleep "$SETTLE"
    measure "$run" 2-loaded

    # 最初のタブだけ残して閉じる。閉じたタブのページとプロセスが手放されるかを見る。
    while [ "$("$CTL" tabs | wc -l)" -gt 1 ]; do
        "$CTL" close >/dev/null
    done
    sleep "$SETTLE"
    measure "$run" 3-closed
    echo "  $run 回目 済"
    run=$((run + 1))
done

# 段階ごとに、回をまたいだ真ん中の値を一行にまとめる。
python3 -I - "$OUT" > "$OUT/summary.txt" <<'PY'
import glob, json, os, statistics, sys

out = sys.argv[1]
runs = sorted(glob.glob(os.path.join(out, "run*")))
phases = sorted(os.path.basename(p)[:-5] for p in glob.glob(os.path.join(runs[0], "*.json")))


def cell(values, digits=1):
    middle = statistics.median(values)
    if len(values) == 1:
        return f"{middle:.{digits}f}"
    return f"{middle:.{digits}f} ({min(values):.{digits}f}-{max(values):.{digits}f})"


print(f"{'phase':<12} {'processes':>9} {'memory MB':>20} {'app MB':>20} {'cpu %':>16} {'wakeups/s':>20}")
for phase in phases:
    reports = [json.load(open(os.path.join(run, phase + ".json")))["report"] for run in runs]
    app = [next(p for p in r["processes"] if p["name"] == "Browser (app)") for r in reports]
    print(f"{phase:<12} {cell([len(r['processes']) for r in reports], 0):>9}"
          f" {cell([r['total']['memoryBytes'] / 1048576 for r in reports]):>20}"
          f" {cell([a['memoryBytes'] / 1048576 for a in app]):>20}"
          f" {cell([r['total']['cpuPercent'] for r in reports], 2):>16}"
          f" {cell([r['total']['wakeupsPerSecond'] for r in reports]):>20}")
print(f"回数: {len(runs)}、実行ファイル: {reports[0]['executable']}")
PY

cat "$OUT/summary.txt"
if [ -n "$PREVIOUS" ] && [ -f "$PREVIOUS/summary.txt" ]; then
    echo "== 前回（${PREVIOUS}）"
    cat "$PREVIOUS/summary.txt"
fi
echo "回ごとの内訳: $OUT/run*/*.json"
