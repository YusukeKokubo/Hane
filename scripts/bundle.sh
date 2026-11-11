#!/bin/sh
# リリースビルドして build/Browser.app にまとめ、Ad-hoc署名する。
# 操作用コマンドは build/browserctl に置く。
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

APP="build/Browser.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/Browser" "$APP/Contents/MacOS/Browser"
cp "$BIN_DIR/browserctl" build/browserctl
cp Support/Info.plist "$APP/Contents/Info.plist"
# 広告ブロックのフィルタリスト。アプリが起動時に訳してコンパイルする（中身が変わったときだけ）。
mkdir -p "$APP/Contents/Resources/Filters"
cp Support/Filters/*.txt "$APP/Contents/Resources/Filters/"

codesign --force --sign - "$APP"
echo "作成: $APP, build/browserctl"

if [ "$INSTALL" = 1 ]; then
    # シンボリックリンクだと Raycast の索引に載らないことがあるので、実体を複製する。
    DEST="$HOME/Applications/Browser.app"
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
