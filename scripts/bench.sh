#!/bin/sh
# 決まった手順で負荷をかけ、メモリ・CPU・起床回数を測る。変更の前後で走らせて見比べる。
#
# 手順は「起動して何もしない」「ページを開き終えて何もしない」「同じタブでページを5回移る」
# 「タブを閉じて何もしない」「タブを BENCH_TABS 枚（既定 10）足して何もしない」「それを閉じて何もしない」の六つ。
# 後ろの二つで、タブ1枚あたりに増えるメモリと、閉じたあとに戻りきらない分（漏れの目安）を出す。
# 足すタブはどれも、別のサイトへ一度移る。WebKit は別のサイトへ移るとプロセスを乗り換え、戻るときのために
# 前のページをプロセスごと残すので、普段の使い方に近い重さになる（同じサイトの中だけだと少なく出る）。
# 別のサイトは、手元で立てた HTTP サーバーを localhost と 127.0.0.1 の二つの名前で引いて作る。
# 何もしない段階は BENCH_SETTLE 秒（既定 15）待ってから BENCH_SECONDS 秒（既定 10）の平均を取る。ページを移る段階は、移っている間の CPU が操作の重さの目安になる。
# 読み込みの直後は WebKit がしばらく動いていて起床回数が跳ねるので、落ち着くのを待つ。
# 何もしていないはずの時間に CPU や起床回数が増えていたら、常駐する処理が紛れ込んでいる。
#
# 使い方: scripts/bench.sh [--no-build] [--runs N] [URL…]
#   一度の計測でも数割ぶれるので、差が小さいときは --runs 3 などで起動からやり直して何度か測る。
#   要約には真ん中の値と、括弧の中に最小〜最大が出る。
#   URL を省くと Tests/Fixtures のページを使う（ネットワークに出ない）。URL を渡したときは、
#   タブを足す段階で一つ目を開いてから二つ目へ移る。
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
NAVIGATE_SECONDS="${BENCH_NAVIGATE:-6}"
MANY_TABS="${BENCH_TABS:-10}"
CTL="$ROOT/build/browserctl"
# 前面で測る。裏のアプリは macOS に間引かれることがあり、前の結果と比べられなくなるため。
export BROWSER_LAUNCH=front

BUILD=1
RUNS=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=0; shift ;;
        --runs) RUNS="$2"; shift 2 ;;
        *) break ;;
    esac
done
DEFAULT_PAGES=0
if [ "$#" -eq 0 ]; then
    DEFAULT_PAGES=1
    set -- "file://$ROOT/Tests/Fixtures/smoke.html" \
           "file://$ROOT/Tests/Fixtures/second.html" \
           "file://$ROOT/Tests/Fixtures/ads.html"
fi

FIRST="$1"
SECOND="${2:-$1}"
# タブを足す段階で、開くページと、そこから移るページ。
MANY_FROM="$FIRST"
MANY_TO="$SECOND"
SERVER_PID=""
if [ "$DEFAULT_PAGES" = 1 ]; then
    port="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
    python3 -I -m http.server "$port" --bind 127.0.0.1 --directory "$ROOT/Tests/Fixtures" >/dev/null 2>&1 &
    SERVER_PID=$!
    MANY_FROM="http://localhost:$port/smoke.html"
    MANY_TO="http://127.0.0.1:$port/second.html"
fi

if [ "$BUILD" = 1 ]; then
    scripts/bundle.sh | tail -1
fi

PREVIOUS="$(ls -d build/bench/*/ 2>/dev/null | tail -1 || true)"
OUT="build/bench/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
trap '"$CTL" quit >/dev/null 2>&1 || true; [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true' EXIT

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

    # 選んでいるタブで、最初の二つのページを交互に5回開く。測る期間は移り終えるまでより長くとり、
    # 足りなければ知らせる（遅いページでは移り終える前に測り終えてしまうため）。
    "$CTL" stats --seconds "$NAVIGATE_SECONDS" --json > "$OUT/run$run/3-navigate.json" &
    stats_pid=$!
    started=$(date +%s)
    for target in "$FIRST" "$SECOND" "$FIRST" "$SECOND" "$FIRST"; do
        "$CTL" open "$target" >/dev/null
    done
    if [ $(( $(date +%s) - started )) -ge "$NAVIGATE_SECONDS" ]; then
        echo "  注意: ページを移り終えるのに ${NAVIGATE_SECONDS} 秒以上かかった。BENCH_NAVIGATE を延ばすこと" >&2
    fi
    wait "$stats_pid"
    sleep "$SETTLE"

    # 最初のタブだけ残して閉じる。閉じたタブのページとプロセスが手放されるかを見る。
    while [ "$("$CTL" tabs | wc -l)" -gt 1 ]; do
        "$CTL" close >/dev/null
    done
    sleep "$SETTLE"
    measure "$run" 4-closed

    # タブを足して、1枚あたりの重さを見る。どのタブも別のサイトへ一度移る。
    added=0
    while [ "$added" -lt "$MANY_TABS" ]; do
        "$CTL" new "$MANY_FROM" >/dev/null
        "$CTL" open "$MANY_TO" >/dev/null
        added=$((added + 1))
    done
    sleep "$SETTLE"
    measure "$run" 5-many-tabs

    # また最初のタブだけにする。4-closed より増えたまま戻らない分が、閉じたタブの残りかす。
    while [ "$("$CTL" tabs | wc -l)" -gt 1 ]; do
        "$CTL" close >/dev/null
    done
    sleep "$SETTLE"
    measure "$run" 6-closed-again
    echo "  $run 回目 済"
    run=$((run + 1))
done

# 段階ごとに、回をまたいだ真ん中の値を一行にまとめる。
python3 -I - "$OUT" "$MANY_TABS" > "$OUT/summary.txt" <<'PY'
import glob, json, os, statistics, sys

out = sys.argv[1]
many_tabs = int(sys.argv[2])
runs = sorted(glob.glob(os.path.join(out, "run*")))
phases = sorted(os.path.basename(p)[:-5] for p in glob.glob(os.path.join(runs[0], "*.json")))


def cell(values, digits=1):
    middle = statistics.median(values)
    if len(values) == 1:
        return f"{middle:.{digits}f}"
    return f"{middle:.{digits}f} ({min(values):.{digits}f}-{max(values):.{digits}f})"


print(f"{'phase':<15} {'processes':>9} {'memory MB':>20} {'app MB':>20} {'cpu %':>16} {'app cpu %':>16} {'wakeups/s':>20}")
for phase in phases:
    reports = [json.load(open(os.path.join(run, phase + ".json")))["report"] for run in runs]
    app = [next(p for p in r["processes"] if p["name"] == "Browser (app)") for r in reports]
    print(f"{phase:<15} {cell([len(r['processes']) for r in reports], 0):>9}"
          f" {cell([r['total']['memoryBytes'] / 1048576 for r in reports]):>20}"
          f" {cell([a['memoryBytes'] / 1048576 for a in app]):>20}"
          f" {cell([r['total']['cpuPercent'] for r in reports], 2):>16}"
          f" {cell([a['cpuPercent'] for a in app], 2):>16}"
          f" {cell([r['total']['wakeupsPerSecond'] for r in reports]):>20}")


def memory(run, phase):
    return json.load(open(os.path.join(run, phase + ".json")))["report"]["total"]["memoryBytes"] / 1048576


if {"4-closed", "5-many-tabs", "6-closed-again"} <= set(phases) and many_tabs > 0:
    per_tab = [(memory(run, "5-many-tabs") - memory(run, "4-closed")) / many_tabs for run in runs]
    left = [memory(run, "6-closed-again") - memory(run, "4-closed") for run in runs]
    print(f"タブ1枚あたり: {cell(per_tab)} MB（5-many-tabs と 4-closed の差を {many_tabs} 枚で割る）")
    print(f"閉じても戻らない分: {cell(left)} MB（6-closed-again − 4-closed。増え続けるなら閉じたタブが残っている）")
print(f"回数: {len(runs)}、実行ファイル: {reports[0]['executable']}")
PY

cat "$OUT/summary.txt"
if [ -n "$PREVIOUS" ] && [ -f "$PREVIOUS/summary.txt" ]; then
    echo "== 前回（${PREVIOUS}）"
    cat "$PREVIOUS/summary.txt"
fi
echo "回ごとの内訳: $OUT/run*/*.json"
