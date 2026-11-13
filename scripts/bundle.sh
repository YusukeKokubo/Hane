#!/bin/sh
# リリースビルドして build/Hane.app にまとめ、Ad-hoc署名する。
# 操作用コマンドは build/hanectl に置く。
# 使い方: scripts/bundle.sh [--install] [--run]
#   --install  ~/Applications に置く（Raycast や Spotlight から起動できるようにするため）
#   --run      できたアプリを起動する（--install と一緒なら置いた方を起動する）
set -eu

cd "$(dirname "$0")/.."

INSTALL=0
RUN=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --run) RUN=1 ;;
        *) echo "知らない引数: $arg" >&2; exit 2 ;;
    esac
done

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/Hane.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/Hane" "$APP/Contents/MacOS/Hane"
cp "$BIN_DIR/hanectl" build/hanectl
cp Support/Info.plist "$APP/Contents/Info.plist"
# 広告ブロックのフィルタリスト。アプリが起動時に訳してコンパイルする（中身が変わったときだけ）。
mkdir -p "$APP/Contents/Resources/Filters"
cp Support/Filters/*.txt "$APP/Contents/Resources/Filters/"
# アプリアイコン。Icon Composer 形式を焼いて、Liquid Glass 用の Assets.car と古い表示向けの AppIcon.icns を作る。
# actool は手元の作業場所でなく前回の場所を基準に相対パスを解くことがあるので、絶対パスで渡す。
actool "$PWD/Support/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" \
    --app-icon AppIcon --enable-on-demand-resources NO --development-region ja \
    --target-device mac --platform macosx --minimum-deployment-target 26.0 \
    --output-partial-info-plist "$PWD/build/AppIcon-partial.plist" >/dev/null
rm -f build/AppIcon-partial.plist
# actool は失敗しても終了コードが 0 なので、できたものを見て確かめる。
if [ ! -f "$APP/Contents/Resources/Assets.car" ]; then
    echo "アプリアイコンを作れなかった（actool を直に走らせて出力を見る）" >&2
    exit 1
fi

codesign --force --sign - "$APP"
echo "作成: $APP, build/hanectl"

if [ "$INSTALL" = 1 ]; then
    # シンボリックリンクだと Raycast の索引に載らないことがあるので、実体を複製する。
    DEST="$HOME/Applications/Hane.app"
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    # 索引の更新を待つとしばらく検索に出ないので、Launch Services と Spotlight にすぐ登録させる。
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
    mdimport "$DEST"
    echo "配置: $DEST"
    APP="$DEST"
fi

if [ "$RUN" = 1 ]; then
    open "$APP"
fi
