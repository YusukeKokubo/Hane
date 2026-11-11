#!/bin/sh
# 動いている実体に Time Profiler を付けて記録し、いつ忙しかったか、何が重かったか、
# そのとき何をしていたか（区間の印）を文字でまとめる。Instruments の画面を開かずに読むため。
#
# 使い方:
#   scripts/profile.sh record <秒>
#       BROWSER_PROFILE（既定 dev）の実体のアプリ本体を記録し、build/profile/<日時>.trace に置いて要約を出す。
#       記録の間に browserctl で操作するなら、これを裏で走らせて、2秒ほど待ってから操作する。
#   scripts/profile.sh summary <trace> [開始秒 終了秒] [--top N]
#       記録済みのものを要約する。秒ごとの表で山を見つけたら、その時間帯を指定して中身を見る。
#
# 数字はサンプルの数で、1サンプルがおよそ1ミリ秒のCPU。ページのプロセス（WebContent）は含まない。
set -eu

cd "$(dirname "$0")/.."
case "${BROWSER_PROFILE:-}" in
    ""|default) export BROWSER_PROFILE=dev ;;
    *) export BROWSER_PROFILE ;;
esac

usage() {
    sed -n '5,10p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

summarize() {
    trace="$1"
    shift
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    xctrace export --input "$trace" \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > "$work/samples.xml"
    xctrace export --input "$trace" \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost" and @category="PointsOfInterest"]' \
        > "$work/signposts.xml"
    python3 -I - "$work/samples.xml" "$work/signposts.xml" "$@" <<'PY'
import collections, sys
import xml.etree.ElementTree as ET

samples_path, signposts_path, *rest = sys.argv[1:]
top = 25
if "--top" in rest:
    index = rest.index("--top")
    top = int(rest[index + 1])
    del rest[index:index + 2]
window = (float(rest[0]), float(rest[1])) if len(rest) >= 2 else None


def rows(path):
    """書き出しは同じ値の2回目から ref で省くので、id を覚えて引き直す。"""
    known = {}

    def resolve(element):
        ref = element.get("ref")
        if ref is not None:
            return known[ref]
        if element.get("id") is not None:
            known[element.get("id")] = element
        for child in element:
            resolve(child)
        return element

    for row in ET.parse(path).getroot().iter("row"):
        yield {child.tag: resolve(child) for child in row}, resolve


samples = []
for row, resolve in rows(samples_path):
    backtrace = row.get("tagged-backtrace", row.get("backtrace"))
    frames = []
    if backtrace is not None:
        for frame in backtrace.iter("frame"):
            frame = resolve(frame)
            binary = frame.find("binary")
            binary = resolve(binary) if binary is not None else None
            frames.append((frame.get("name") or frame.get("addr") or "?",
                           binary.get("name") if binary is not None else "?"))
    samples.append((int(row["sample-time"].text) / 1e9, row["thread"].get("fmt", "?"), frames))

marks = []
open_marks = {}
# 同じ印が別の表にも載ることがあるので、時刻と種類で重ねて数えないようにする。
seen = set()
for row, _ in rows(signposts_path):
    if row.get("subsystem") is None or row["subsystem"].text != "local.personal.browser":
        continue
    identity = (row["event-time"].text, row["event-type"].text, row["signpost-name"].text)
    if identity in seen:
        continue
    seen.add(identity)
    at = int(row["event-time"].text) / 1e9
    kind = row["event-type"].text
    name = row["signpost-name"].text
    key = (name, row["os-signpost-identifier"].text)
    if kind == "Begin":
        open_marks[key] = at
    elif kind == "End" and key in open_marks:
        begun = open_marks.pop(key)
        marks.append((begun, name, f"{(at - begun) * 1000:.0f}ms"))
    elif kind == "Event":
        marks.append((at, name, ""))
for (name, _), begun in open_marks.items():
    marks.append((begun, name, "終わらないまま記録が終わった"))
marks.sort()

if not samples:
    print("サンプルがない（記録の間、アプリ本体はほとんど動いていなかった）")
end = max([s[0] for s in samples] + [m[0] for m in marks] + [0])

print("== 秒ごとのサンプル数")
per_second = collections.Counter(int(s[0]) for s in samples)
peak = max(per_second.values(), default=1)
for second in range(int(end) + 1):
    count = per_second.get(second, 0)
    print(f"{second:4d}s {count:5d} " + "#" * round(count / peak * 40))

print("\n== 区間の印")
for at, name, note in marks:
    print(f"{at:8.3f}s  {name}  {note}".rstrip())
if not marks:
    print("（なし）")

chosen = [s for s in samples if window is None or window[0] <= s[0] < window[1]]
span = f"{window[0]}s〜{window[1]}s" if window else "全体"
print(f"\n== 重い関数（{span}、{len(chosen)} サンプル）")
threads = collections.Counter(thread for _, thread, _ in chosen)
print("スレッド: " + ", ".join(f"{name.split(' (Browser')[0]} {count}" for name, count in threads.most_common(5)))

def is_plumbing(name):
    """入口や、コンパイラが挟む仲立ちの関数。どの記録でも上に来るだけで手がかりにならない。"""
    return (name in ("main", "static BrowserApp.$main()")
            or name.startswith(("partial apply", "thunk", "specialized thunk", "reabstraction thunk", "<deduplicated")))


own = collections.Counter()
inclusive = collections.Counter()
leaves = collections.Counter()
for _, _, frames in chosen:
    if frames:
        leaves[frames[0][0]] += 1
    for name, binary in set(frames):
        inclusive[name] += 1
        if binary == "Browser" and not is_plumbing(name):
            own[name] += 1


def show(title, counter):
    print(f"\n-- {title}")
    for name, count in counter.most_common(top):
        print(f"{count:6d}  {name[:160]}")
    if not counter:
        print("（なし）")


show("アプリ自身のコード（呼んだ先も含む）", own)
show("その関数自身で使った時間", leaves)
show("呼んだ先も含む時間（すべて）", inclusive)
PY
}

case "${1:-}" in
    record)
        [ "$#" -ge 2 ] || usage
        seconds="$2"
        pid="$(build/browserctl stats --json | python3 -I -c '
import json, sys
print(next(p["pid"] for p in json.load(sys.stdin)["report"]["processes"] if p["name"] == "Browser (app)"))')"
        mkdir -p build/profile
        trace="build/profile/$(date +%Y%m%d-%H%M%S).trace"
        echo "== 記録（プロファイル: ${BROWSER_PROFILE}、pid ${pid}、${seconds} 秒）"
        xctrace record --template 'Time Profiler' --attach "$pid" --time-limit "${seconds}s" \
            --output "$trace" >/dev/null 2>&1
        echo "記録: $trace"
        summarize "$trace"
        ;;
    summary)
        [ "$#" -ge 2 ] || usage
        shift
        summarize "$@"
        ;;
    *)
        usage
        ;;
esac
